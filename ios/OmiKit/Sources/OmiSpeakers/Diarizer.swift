import Foundation
import OmiKit

/// 話者分離 (誰がいつ話したか)。自宅サーバの sherpa-onnx (pyannote の手順) と同じ計算を Swift で行う:
/// 1. 10 秒の窓を 1 秒ずつずらして、窓ごとに最大 3 人の発話を推定する
/// 2. 窓の中の人ごとに声の特徴を取り、完全連結法でまとめる (距離 = 1 − cos がしきい値未満の組)
/// 3. まとめた人ごとに、フレームごとの人数に合わせて区間を決める
public struct Diarizer: Sendable {
    public var clusteringThreshold: Double
    public var minDurationOn: Double
    public var minDurationOff: Double

    public init(clusteringThreshold: Double = 0.3, minDurationOn: Double = 0.3, minDurationOff: Double = 0.5) {
        self.clusteringThreshold = clusteringThreshold
        self.minDurationOn = minDurationOn
        self.minDurationOff = minDurationOff
    }

    typealias N = SpeakerNetworks
    static let localSpeakers = 3
    /// 7 クラス (話者の組み合わせ) → 3 人それぞれが話しているか
    static let powerset: [[Int8]] = [[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 0], [1, 0, 1], [0, 1, 1]]

    /// 窓ごとのフレーム × 3 人 (0/1)
    struct Labels {
        var frames: Int
        var columns: Int
        var values: [Int8]
        subscript(f: Int, c: Int) -> Int8 {
            get { values[f * columns + c] }
            set { values[f * columns + c] = newValue }
        }
    }

    public func diarize(_ audio: [Float], networks: SpeakerNetworks) throws -> [SpeakerTurn] {
        let n = audio.count
        guard n >= N.sampleRate / 2 else { return [] }
        let W = N.windowSize, S = N.windowShift

        var chunks: [[Float]] = []
        if n <= W {
            chunks.append(audio + [Float](repeating: 0, count: W - n))
        } else {
            let count = (n - W) / S + 1
            for i in 0..<count { chunks.append(Array(audio[(i * S)..<(i * S + W)])) }
            if (n - W) % S > 0 {
                let tail = Array(audio[(count * S)..<n])
                chunks.append(tail + [Float](repeating: 0, count: W - tail.count))
            }
        }
        try Task.checkCancellation()
        let labels = try networks.segment(chunks).map(Self.toMultiLabel)

        if labels.count == 1 {
            return computeResult(labels[0])
        }

        let speakersPerFrame = Self.speakersPerFrame(labels)
        guard speakersPerFrame.contains(where: { $0 > 0 }) else { return [] }

        // 窓の中の人ごとの、重なりのない区間 (サンプル) と声の特徴
        let (pairs, intervals) = Self.chunkSpeakerSamples(labels)
        var validPairs: [(chunk: Int, speaker: Int)] = []
        var embeddings: [[Float]] = []
        for (pair, list) in zip(pairs, intervals) {
            try Task.checkCancellation()
            var clip: [Float] = []
            for (a, b) in list {
                let end = min(b, n)
                if end > a { clip.append(contentsOf: audio[a..<end]) }
            }
            guard let e = try networks.embed(clip) else { continue }
            validPairs.append(pair)
            embeddings.append(e)
        }
        let clusters = Self.completeLinkage(embeddings.map(normalized), threshold: clusteringThreshold)
        guard let maxCluster = clusters.max() else { return [] }
        var toCluster: [Int: Int] = [:]
        for (pair, c) in zip(validPairs, clusters) { toCluster[pair.chunk * Self.localSpeakers + pair.speaker] = c }

        // 窓の人をまとめた人に付け替え、フレームごとに足し合わせる
        let columns = maxCluster + 1
        let totalFrames = (W + (labels.count - 1) * S) / N.receptiveFieldShift + 1
        var wide = [Int32](repeating: 0, count: totalFrames * columns)
        for (ci, label) in labels.enumerated() {
            let start = Int(Float(ci) * Float(S) / Float(N.receptiveFieldShift) + 0.5)
            for sp in 0..<Self.localSpeakers {
                guard let c = toCluster[ci * Self.localSpeakers + sp] else { continue }
                for f in 0..<label.frames where label[f, sp] == 1 {
                    wide[(start + f) * columns + c] += 1
                }
            }
        }
        var rows = totalFrames
        if (n - W) % S > 0 {
            rows = min(n / N.receptiveFieldShift, totalFrames - 1) + 1
        }
        // フレームごとの人数だけ、多く重なった人を選ぶ
        var count = Labels(frames: rows, columns: columns, values: [Int8](repeating: 0, count: rows * columns))
        for f in 0..<rows {
            let k = max(0, min(columns, speakersPerFrame[f]))
            guard k > 0 else { continue }
            let row = (0..<columns).map { wide[f * columns + $0] }
            let top = (0..<columns).sorted { row[$0] != row[$1] ? row[$0] > row[$1] : $0 < $1 }.prefix(k)
            for c in top { count[f, c] = 1 }
        }
        return computeResult(count)
    }

    static func toMultiLabel(_ logProbs: [Float]) -> Labels {
        let frames = N.framesPerWindow, classes = N.classes
        var out = Labels(frames: frames, columns: localSpeakers, values: [Int8](repeating: 0, count: frames * localSpeakers))
        for f in 0..<frames {
            var best = 0
            for c in 1..<classes where logProbs[f * classes + c] > logProbs[f * classes + best] { best = c }
            for s in 0..<localSpeakers { out[f, s] = powerset[best][s] }
        }
        return out
    }

    static func speakersPerFrame(_ labels: [Labels]) -> [Int] {
        let total = (N.windowSize + (labels.count - 1) * N.windowShift) / N.receptiveFieldShift + 1
        var count = [Float](repeating: 0, count: total)
        var weight = [Float](repeating: 0, count: total)
        for (i, label) in labels.enumerated() {
            let start = Int(Float(i) * Float(N.windowShift) / Float(N.receptiveFieldShift) + 0.5)
            for f in 0..<label.frames {
                var s: Float = 0
                for c in 0..<label.columns { s += Float(label[f, c]) }
                count[start + f] += s
                weight[start + f] += 1
            }
        }
        return zip(count, weight).map { Int($0 / ($1 + 1e-12) + 0.5) }
    }

    /// 窓の中の人 (10 フレーム以上、ほかの人と重ならないところ) ごとのサンプルの区間
    static func chunkSpeakerSamples(_ labels: [Labels]) -> ([(chunk: Int, speaker: Int)], [[(Int, Int)]]) {
        var pairs: [(chunk: Int, speaker: Int)] = []
        var intervals: [[(Int, Int)]] = []
        let W = Float(N.windowSize)
        for (ci, label) in labels.enumerated() {
            let frames = label.frames
            let offset = Float(ci * N.windowShift)
            func sample(_ k: Int) -> Int { Int(Float(k) / Float(frames) * W + offset) }
            for sp in 0..<localSpeakers {
                var active = [Bool](repeating: false, count: frames)
                var total = 0
                for f in 0..<frames {
                    var sum = 0
                    for c in 0..<label.columns { sum += Int(label[f, c]) }
                    if sum < 2 && label[f, sp] != 0 {
                        active[f] = true
                        total += 1
                    }
                }
                guard total >= 10 else { continue }
                var list: [(Int, Int)] = []
                var startIndex: Int?
                for k in 0..<frames {
                    if active[k] {
                        if startIndex == nil { startIndex = k }
                    } else if let s = startIndex {
                        list.append((sample(s), sample(k)))
                        startIndex = nil
                    }
                }
                if let s = startIndex { list.append((sample(s), sample(frames - 1))) }
                pairs.append((ci, sp))
                intervals.append(list)
            }
        }
        return (pairs, intervals)
    }

    func computeResult(_ labels: Labels) -> [SpeakerTurn] {
        let scale = Double(N.receptiveFieldShift) / Double(N.sampleRate)
        let offset = 0.5 * Double(N.receptiveFieldSize) / Double(N.sampleRate)
        var out: [(Double, Double, Int)] = []
        for sp in 0..<labels.columns {
            var segments: [(Double, Double)] = []
            var active = labels[0, sp] > 0
            var startIndex = 0
            for f in 1..<labels.frames {
                if active {
                    if labels[f, sp] == 0 {
                        segments.append((Double(Float(startIndex) * Float(scale) + Float(offset)),
                                         Double(Float(f) * Float(scale) + Float(offset))))
                        active = false
                    }
                } else if labels[f, sp] == 1 {
                    active = true
                    startIndex = f
                }
            }
            if active {
                segments.append((Double(Float(startIndex) * Float(scale) + Float(offset)),
                                 Double(Float(labels.frames - 1) * Float(scale) + Float(offset))))
            }
            // 間が min_duration_off 以下の区間をつなぐ
            var changed = true
            while changed {
                changed = false
                var i = 0
                while i < segments.count - 1 {
                    let a = segments[i], b = segments[i + 1]
                    if a.1 < b.0 && a.1 + minDurationOff >= b.0 {
                        segments[i] = (a.0, b.1)
                        segments.remove(at: i + 1)
                        changed = true
                        break
                    }
                    i += 1
                }
            }
            for s in segments where s.1 - s.0 > minDurationOn { out.append((s.0, s.1, sp)) }
        }
        return out.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.2 < $1.2 }
            .map { SpeakerTurn(start: $0.0, end: $0.1, label: "S\($0.2)") }
    }

    /// 完全連結法の階層的クラスタリングを、距離がしきい値未満の併合まで行う。ラベルは初めて出た順に 0, 1, ...
    static func completeLinkage(_ x: [[Float]], threshold: Double) -> [Int] {
        let n = x.count
        if n == 0 { return [] }
        if n == 1 { return [0] }
        var d = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                var dot: Float = 0
                for k in 0..<x[i].count { dot += x[i][k] * x[j][k] }
                let v = max(0, 1 - Double(dot))
                d[i * n + j] = v
                d[j * n + i] = v
            }
        }
        // 最近傍の連鎖 (complete linkage は可約なので、この順でも同じ樹形になる)
        var active = [Bool](repeating: true, count: n)
        var merges: [(Int, Int, Double)] = []
        var chain: [Int] = []
        var remaining = n
        while remaining > 1 {
            if chain.isEmpty, let first = active.firstIndex(of: true) { chain.append(first) }
            while true {
                let a = chain[chain.count - 1]
                var best = -1
                var bestD = Double.infinity
                if chain.count >= 2 {
                    best = chain[chain.count - 2]
                    bestD = d[a * n + best]
                }
                for b in 0..<n where active[b] && b != a && d[a * n + b] < bestD {
                    best = b
                    bestD = d[a * n + b]
                }
                if chain.count >= 2 && best == chain[chain.count - 2] { break }
                chain.append(best)
            }
            let a = chain.removeLast(), b = chain.removeLast()
            merges.append((a, b, d[a * n + b]))
            let keep = min(a, b), drop = max(a, b)
            for k in 0..<n where active[k] && k != a && k != b {
                let v = max(d[a * n + k], d[b * n + k])
                d[keep * n + k] = v
                d[k * n + keep] = v
            }
            active[drop] = false
            remaining -= 1
        }
        var parent = Array(0..<n)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for (a, b, h) in merges where h < threshold {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        var labelOf: [Int: Int] = [:]
        return (0..<n).map { i in
            let r = find(i)
            if let l = labelOf[r] { return l }
            let l = labelOf.count
            labelOf[r] = l
            return l
        }
    }
}

func normalized(_ v: [Float]) -> [Float] {
    var s: Float = 0
    for x in v { s += x * x }
    let norm = s.squareRoot()
    return norm > 0 ? v.map { $0 / norm } : v
}
