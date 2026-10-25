import Foundation

/// 自宅サーバがないときに、iPhone で名前を付けた人の声を学習する (自宅サーバの speaker_model.train と同じ計算)。
/// 1. 名前の付いた発話の声の特徴を集める (人が直した発話は重く、自動で付いた発話は軽く、明らかな外れは除く)
/// 2. 人ごとの重心と、話者の違いを強調する変換 (WCCN, 縮小推定) を求め、1 つ抜き試験で当たり方が良い方を使う
/// 3. 人ごとに「その人らしい」とみなす点数の下限を決める
/// iPhone だけの人は自宅サーバの ID を持たないので、仮の負の ID を使う (文字起こしには名前だけを付ける)。
public enum VoiceTrainer {
    public struct Sample: Sendable {
        public var embedding: [Float]
        public var person: String
        public var weight: Double
        public var confirmed: Bool

        public init(embedding: [Float], person: String, weight: Double, confirmed: Bool) {
            self.embedding = embedding
            self.person = person
            self.weight = weight
            self.confirmed = confirmed
        }
    }

    static let outlierCos = 0.45
    static let weightManual = 3.0
    static let weightAuto = 1.0
    static let minSpeakerWeight = 2.0
    static let outlierMADs = 2.5
    static let outlierMinSamples = 8
    static let minConfirmedForEval = 20
    static let backgroundSeconds = 1.5
    static let backgroundLimit = 2000

    /// iPhone で話者分離した録音から、学習に使う発話と「名前のない声」(他人の例) を集める
    public static func samples(segments: [SegmentMetadata]) -> (samples: [Sample], background: [[Float]]) {
        var samples: [Sample] = []
        var background: [[Float]] = []
        for meta in segments {
            guard let device = meta.deviceSpeakers, let pieces = meta.transcript?.pieces, !pieces.isEmpty else { continue }
            for u in device.utterances {
                guard let e = u.embedding?.values else { continue }
                // 発話と重なる文字起こしの区間の話者 (長く重なる人)
                var seconds: [String: Double] = [:]
                var manual: Set<String> = []
                var unnamed = 0.0
                for p in pieces {
                    let overlap = min(u.end, p.end) - max(u.start, p.start)
                    guard overlap > 0, overlap >= 0.5 * min(max(p.end - p.start, 1e-3), u.end - u.start) else { continue }
                    if let name = p.speaker, isNamedSpeaker(name) {
                        seconds[name, default: 0] += overlap
                        if p.speakerManual == true { manual.insert(name) }
                    } else {
                        unnamed += overlap
                    }
                }
                if let (name, s) = seconds.max(by: { $0.value < $1.value }), s >= unnamed {
                    let confirmed = manual.contains(name)
                    samples.append(Sample(embedding: e, person: name, weight: confirmed ? weightManual : weightAuto,
                                          confirmed: confirmed))
                } else if unnamed > 0, u.end - u.start >= backgroundSeconds {
                    background.append(e)
                }
            }
        }
        return (samples, Array(background.suffix(backgroundLimit)))
    }

    public static func train(segments: [SegmentMetadata], now: Date = Date()) -> VoiceLibrary? {
        let (samples, background) = samples(segments: segments)
        return train(samples: samples, background: background, now: now)
    }

    public static func train(samples: [Sample], background: [[Float]], now: Date = Date()) -> VoiceLibrary? {
        guard let dim = samples.first?.embedding.count, dim > 0 else { return nil }
        // 人ごとに、確かめた発話と重心に近い自動の発話だけを使う
        var byPerson: [String: [Sample]] = [:]
        for s in samples where s.embedding.count == dim { byPerson[s.person, default: []].append(s) }
        var kept: [Sample] = []
        for (_, ss) in byPerson.sorted(by: { $0.key < $1.key }) {
            let x = ss.map { unit($0.embedding.map(Double.init)) }
            var c = [Double](repeating: 0, count: dim)
            for (s, xi) in zip(ss, x) { for j in 0..<dim { c[j] += s.weight * xi[j] } }
            c = unit(c)
            let keep = zip(ss, x).filter { s, xi in s.confirmed || dot(xi, c) >= outlierCos }.map(\.0)
            if keep.reduce(0, { $0 + $1.weight }) >= minSpeakerWeight { kept.append(contentsOf: keep) }
        }
        guard !kept.isEmpty else { return nil }

        let people = Array(Set(kept.map(\.person))).sorted()
        let index = Dictionary(uniqueKeysWithValues: people.enumerated().map { ($1, $0) })
        let k = people.count
        let x = kept.map { unit($0.embedding.map(Double.init)) }
        let y = kept.map { index[$0.person]! }
        let w = kept.map(\.weight)
        let confirmed = kept.map(\.confirmed)
        let evaluate = confirmed.filter { $0 }.count >= minConfirmedForEval ? confirmed : confirmed.map { _ in true }

        var candidates: [Whitening?] = [nil]
        if k >= 2 && kept.count >= 10 { candidates.append(wccn(x, y, w, dim: dim)) }
        var best: (accuracy: Double, evaluated: Int, whitening: Whitening?)?
        for cand in candidates {
            let z = x.map { transform($0, cand) }
            let (acc, n) = looAccuracy(z, y, w, k: k, evaluate: evaluate)
            if best == nil || acc > best!.accuracy + 1e-9 { best = (acc, n, cand) }
        }
        let whitening = best!.whitening
        let z = x.map { transform($0, whitening) }
        let cents = centroids(z, y, w, k: k).unit
        let scores = z.map { zi in cents.map { dot(zi, $0) } }
        let bScores = background.filter { $0.count == dim }.map { b in
            let zb = transform(unit(b.map(Double.init)), whitening)
            return cents.map { dot(zb, $0) }
        }
        var thresholds: [Double] = []
        var review: [Double] = []
        for c in 0..<k {
            let own = scores.indices.filter { y[$0] == c }.map { scores[$0][c] }
            let other = scores.indices.filter { y[$0] != c }.map { scores[$0][c] } + bScores.map { $0[c] }
            let accept = other.isEmpty
                ? percentile(own, 5) - 0.05
                : min((percentile(own, 10) + percentile(other, 90)) / 2, percentile(own, 25))
            var line = accept
            if own.count >= outlierMinSamples {
                let median = percentile(own, 50)
                let mad = percentile(own.map { abs($0 - median) }, 50)
                let outlier = median - outlierMADs * 1.4826 * mad
                line = min(max(accept, outlier), percentile(own, 25))
            }
            thresholds.append(accept)
            review.append(line)
        }

        // iPhone だけの人の仮の ID (負)。文字起こしには名前だけを付ける
        let ids = people.indices.map { -($0 + 1) }
        let raw = centroids(x, y, w, k: k)
        let profiles = people.indices.map { i in
            VoiceLibrary.Profile(id: ids[i], name: people[i], weight: raw.weights[i], vector: raw.unit[i].map(Float.init))
        }
        let model = VoiceLibrary.Model(
            speakerIds: ids, centroids: cents.map { $0.map(Float.init) }, thresholds: thresholds, review: review,
            mean: whitening.map { $0.mean.map(Float.init) }, projection: whitening.map { $0.projection.map(Float.init) })
        let version = "iphone-\(Int(now.timeIntervalSince1970))-\(kept.count)"
        return VoiceLibrary(version: version, source: "iphone", embeddingModel: "wespeaker-voxceleb-resnet34-LM",
                            profiles: profiles, model: model)
    }

    // MARK: - 計算

    struct Whitening {
        var mean: [Double]
        /// 次元 × 次元 (行ごと)。z = (x − mean) · projection
        var projection: [Double]
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for i in 0..<a.count { s += a[i] * b[i] }
        return s
    }

    static func unit(_ v: [Double]) -> [Double] {
        let n = dot(v, v).squareRoot()
        return v.map { $0 / max(n, 1e-9) }
    }

    static func transform(_ x: [Double], _ wh: Whitening?) -> [Double] {
        guard let wh else { return x }
        let d = x.count
        var out = [Double](repeating: 0, count: d)
        for i in 0..<d {
            let c = x[i] - wh.mean[i]
            let row = i * d
            for j in 0..<d { out[j] += c * wh.projection[row + j] }
        }
        return unit(out)
    }

    /// 人ごとの重みつきの和 (正規化したものと、そのままのものと、重みの合計)
    static func centroids(_ z: [[Double]], _ y: [Int], _ w: [Double], k: Int) -> (unit: [[Double]], sums: [[Double]], weights: [Double]) {
        let d = z.first?.count ?? 0
        var sums = [[Double]](repeating: [Double](repeating: 0, count: d), count: k)
        var weights = [Double](repeating: 0, count: k)
        for i in z.indices {
            for j in 0..<d { sums[y[i]][j] += w[i] * z[i][j] }
            weights[y[i]] += w[i]
        }
        return (sums.map(unit), sums, weights)
    }

    /// 1 つずつ抜いて当てる試験の正解率
    static func looAccuracy(_ z: [[Double]], _ y: [Int], _ w: [Double], k: Int, evaluate: [Bool]) -> (Double, Int) {
        let (cents, sums, _) = centroids(z, y, w, k: k)
        var correct = 0, total = 0
        for i in z.indices where evaluate[i] {
            let own = zip(sums[y[i]], z[i]).map { $0 - w[i] * $1 }
            let norm = dot(own, own).squareRoot()
            guard norm >= 1e-9 else { continue }
            var c = cents
            c[y[i]] = own.map { $0 / norm }
            let s = c.map { dot($0, z[i]) }
            var arg = 0
            for j in 1..<s.count where s[j] > s[arg] { arg = j }
            correct += arg == y[i] ? 1 : 0
            total += 1
        }
        return (total > 0 ? Double(correct) / Double(total) : 1.0, total)
    }

    /// クラス内共分散を白色化する変換 (縮小推定 0.5)
    static func wccn(_ x: [[Double]], _ y: [Int], _ w: [Double], dim d: Int, shrink: Double = 0.5) -> Whitening {
        let total = w.reduce(0, +)
        var mu = [Double](repeating: 0, count: d)
        for i in x.indices { for j in 0..<d { mu[j] += w[i] * x[i][j] } }
        mu = mu.map { $0 / total }
        let xc = x.map { zip($0, mu).map { $0 - $1 } }
        var sw = [Double](repeating: 0, count: d * d)
        for c in Set(y) {
            let members = x.indices.filter { y[$0] == c }
            let wc = members.reduce(0) { $0 + w[$1] }
            var mk = [Double](repeating: 0, count: d)
            for i in members { for j in 0..<d { mk[j] += w[i] * xc[i][j] } }
            mk = mk.map { $0 / wc }
            for i in members {
                let diff = zip(xc[i], mk).map { $0 - $1 }
                for a in 0..<d where diff[a] != 0 {
                    let wa = w[i] * diff[a]
                    for b in 0..<d { sw[a * d + b] += wa * diff[b] }
                }
            }
        }
        var trace = 0.0
        for a in 0..<d { trace += sw[a * d + a] / total }
        for i in 0..<(d * d) { sw[i] = (1 - shrink) * sw[i] / total }
        for a in 0..<d { sw[a * d + a] += shrink * trace / Double(d) }
        let (values, vectors) = symmetricEigen(sw, n: d)
        var p = [Double](repeating: 0, count: d * d)
        for e in 0..<d {
            let s = 1 / max(values[e], 1e-8).squareRoot()
            for a in 0..<d {
                let va = vectors[a * d + e] * s
                guard va != 0 else { continue }
                for b in 0..<d { p[a * d + b] += va * vectors[b * d + e] }
            }
        }
        return Whitening(mean: mu, projection: p)
    }

    /// 対称行列の固有値分解 (巡回ヤコビ法)。vectors の列 e が固有値 values[e] の固有ベクトル (行ごとの配置)
    static func symmetricEigen(_ matrix: [Double], n: Int) -> (values: [Double], vectors: [Double]) {
        var a = matrix
        var v = [Double](repeating: 0, count: n * n)
        for i in 0..<n { v[i * n + i] = 1 }
        a.withUnsafeMutableBufferPointer { a in
            v.withUnsafeMutableBufferPointer { v in
                for _ in 0..<60 {
                    var off = 0.0, diag = 0.0
                    for i in 0..<n {
                        diag += a[i * n + i] * a[i * n + i]
                        for j in (i + 1)..<max(i + 1, n) { off += a[i * n + j] * a[i * n + j] }
                    }
                    if off <= 1e-24 * max(diag, 1e-300) { break }
                    for p in 0..<(n - 1) {
                        for q in (p + 1)..<n {
                            let apq = a[p * n + q]
                            guard abs(apq) > 1e-300 else { continue }
                            let app = a[p * n + p], aqq = a[q * n + q]
                            let theta = (aqq - app) / (2 * apq)
                            let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                            let c = 1 / (t * t + 1).squareRoot(), s = t * c
                            for k in 0..<n {
                                let akp = a[k * n + p], akq = a[k * n + q]
                                a[k * n + p] = c * akp - s * akq
                                a[k * n + q] = s * akp + c * akq
                            }
                            for k in 0..<n {
                                let apk = a[p * n + k], aqk = a[q * n + k]
                                a[p * n + k] = c * apk - s * aqk
                                a[q * n + k] = s * apk + c * aqk
                            }
                            for k in 0..<n {
                                let vkp = v[k * n + p], vkq = v[k * n + q]
                                v[k * n + p] = c * vkp - s * vkq
                                v[k * n + q] = s * vkp + c * vkq
                            }
                        }
                    }
                }
            }
        }
        return ((0..<n).map { a[$0 * n + $0] }, v)
    }

    /// numpy.percentile と同じ (線形補間)
    static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let pos = Double(s.count - 1) * q / 100
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }
}
