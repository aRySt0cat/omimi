import Foundation

/// 話者分離の 1 区間 (録音の先頭からの秒)。label は録音の中での話者 ("S0", "S1", ...)
public struct SpeakerTurn: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var label: String

    public init(start: Double, end: Double, label: String) {
        self.start = start
        self.end = end
        self.label = label
    }
}

/// 単精度の数の並び。JSON では little endian の base64 にする (自宅サーバと共通)
public struct PackedFloats: Codable, Equatable, Sendable {
    public var values: [Float]

    public init(_ values: [Float]) { self.values = values }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let data = Data(base64Encoded: s), data.count % 4 == 0 else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid float32 base64")
        }
        values = data.withUnsafeBytes { raw in
            (0..<(data.count / 4)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var data = Data(capacity: values.count * 4)
        for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        var c = encoder.singleValueContainer()
        try c.encode(data.base64EncodedString())
    }
}

/// 半精度で保存する数の並び (録音ごとの声の特徴。大きさを半分にする)
public struct HalfFloats: Codable, Equatable, Sendable {
    public var values: [Float]

    public init(_ values: [Float]) { self.values = values }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let data = Data(base64Encoded: s), data.count % 2 == 0 else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid float16 base64")
        }
        values = data.withUnsafeBytes { raw in
            (0..<(data.count / 2)).map {
                Float(Float16(bitPattern: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self))))
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var data = Data(capacity: values.count * 2)
        for v in values { withUnsafeBytes(of: Float16(v).bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        var c = encoder.singleValueContainer()
        try c.encode(data.base64EncodedString())
    }
}

/// iPhone で行った話者分離の結果と声の特徴 (録音ごとに保存し、学習した声が変わったら付け直す)
public struct DeviceSpeakers: Codable, Equatable, Sendable {
    /// 録音の中の話者 (ラベル) ごとの声の特徴 (先頭 60 秒まで)
    public struct Voice: Codable, Equatable, Sendable {
        public var label: String
        public var seconds: Double
        public var embedding: HalfFloats

        public init(label: String, seconds: Double, embedding: [Float]) {
            self.label = label
            self.seconds = seconds
            self.embedding = HalfFloats(embedding)
        }
    }

    /// 同じ人が続けて話した発話 (1 秒以上なら声の特徴あり)
    public struct Utterance: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var label: String?
        public var embedding: HalfFloats?

        public init(start: Double, end: Double, label: String?, embedding: [Float]?) {
            self.start = start
            self.end = end
            self.label = label
            self.embedding = embedding.map(HalfFloats.init)
        }
    }

    public var engine: String
    public var turns: [SpeakerTurn]
    public var voices: [Voice]
    public var utterances: [Utterance]
    public var processedAt: Date
    public var processingSeconds: Double
    /// 当てはめた学習済みの声の版 (`VoiceLibrary.version`)。nil は名前を当てていない
    public var appliedVersion: String?

    public init(engine: String, turns: [SpeakerTurn], voices: [Voice], utterances: [Utterance],
                processedAt: Date = Date(), processingSeconds: Double, appliedVersion: String? = nil) {
        self.engine = engine
        self.turns = turns
        self.voices = voices
        self.utterances = utterances
        self.processedAt = processedAt
        self.processingSeconds = processingSeconds
        self.appliedVersion = appliedVersion
    }
}

/// 学習した声 (自宅サーバの `GET /api/v1/speakers/voices`、または iPhone で学習したもの)。
/// iPhone の話者分離の結果に名前を当てるのに使う。
public struct VoiceLibrary: Codable, Equatable, Sendable {
    /// 声のプロファイル (名前のない声も含む。vector は正規化した平均の声)
    public struct Profile: Codable, Equatable, Sendable {
        public var id: Int
        public var name: String?
        public var ignored: Bool?
        public var weight: Double
        public var vector: PackedFloats

        public init(id: Int, name: String?, ignored: Bool? = nil, weight: Double, vector: [Float]) {
            self.id = id
            self.name = name
            self.ignored = ignored
            self.weight = weight
            self.vector = PackedFloats(vector)
        }

        public var isNamed: Bool { isNamedSpeaker(name) }
    }

    /// 名前を付けた人を学習したモデル (自宅サーバの speaker_model.py と同じ)
    public struct Model: Codable, Equatable, Sendable {
        public var speakerIds: [Int]
        /// 変換後の空間で正規化した重心 (人数 × 次元)
        public var centroids: [PackedFloats]
        /// 割り当ての下限と、「確認したい発話」の線
        public var thresholds: [Double]
        public var review: [Double]?
        /// クラス内共分散の白色化 (無ければ使わない)。projection は 次元 × 次元 (行ごと)
        public var mean: PackedFloats?
        public var projection: PackedFloats?

        public init(speakerIds: [Int], centroids: [[Float]], thresholds: [Double], review: [Double]? = nil,
                    mean: [Float]? = nil, projection: [Float]? = nil) {
            self.speakerIds = speakerIds
            self.centroids = centroids.map(PackedFloats.init)
            self.thresholds = thresholds
            self.review = review
            self.mean = mean.map(PackedFloats.init)
            self.projection = projection.map(PackedFloats.init)
        }
    }

    public struct Settings: Codable, Equatable, Sendable {
        /// 話者分離のまとめのしきい値 (1 − cos)
        public var diarizationThreshold: Double
        /// 名前のない既知の声とみなす類似度
        public var matchThreshold: Double
        /// 新しい声とみなす最短の発話 (秒)
        public var minSeconds: Double

        public init(diarizationThreshold: Double = 0.3, matchThreshold: Double = 0.6, minSeconds: Double = 3.0) {
            self.diarizationThreshold = diarizationThreshold
            self.matchThreshold = matchThreshold
            self.minSeconds = minSeconds
        }
    }

    public var version: String
    /// server / iphone
    public var source: String
    public var embeddingModel: String?
    public var settings: Settings
    public var profiles: [Profile]
    public var model: Model?

    public init(version: String, source: String, embeddingModel: String? = nil, settings: Settings = Settings(),
                profiles: [Profile], model: Model?) {
        self.version = version
        self.source = source
        self.embeddingModel = embeddingModel
        self.settings = settings
        self.profiles = profiles
        self.model = model
    }

    public var namedCount: Int { profiles.filter(\.isNamed).count }

    func profile(_ id: Int) -> Profile? { profiles.first { $0.id == id } }
}

/// 学習した声のモデルで点数を付ける (speaker_model.py の SpeakerModel と同じ計算)
struct VoiceScorer {
    static let margin = 0.05
    static let switchMargin = 0.10

    let model: VoiceLibrary.Model
    let dim: Int
    private let projection: [Float]?
    private let mean: [Float]?
    private let centroids: [[Float]]

    init?(_ model: VoiceLibrary.Model?) {
        guard let model, !model.speakerIds.isEmpty, model.centroids.count == model.speakerIds.count,
              model.thresholds.count == model.speakerIds.count else { return nil }
        self.model = model
        centroids = model.centroids.map(\.values)
        dim = centroids[0].count
        if let p = model.projection?.values, let m = model.mean?.values, p.count == dim * dim, m.count == dim {
            projection = p
            mean = m
        } else {
            projection = nil
            mean = nil
        }
    }

    func contains(_ id: Int?) -> Bool { id.map(model.speakerIds.contains) ?? false }

    func transform(_ x: [Float]) -> [Float] {
        guard let projection, let mean else { return VoiceMath.normalized(x) }
        let c = (0..<dim).map { x[$0] - mean[$0] }
        var out = [Float](repeating: 0, count: dim)
        for i in 0..<dim where c[i] != 0 {
            let row = i * dim
            for j in 0..<dim { out[j] += c[i] * projection[row + j] }
        }
        return VoiceMath.normalized(out)
    }

    func scores(_ emb: [Float]) -> [Double] {
        let z = transform(emb)
        return centroids.map { Double(VoiceMath.dot(z, $0)) }
    }

    func score(_ emb: [Float], for id: Int) -> Double? {
        guard let i = model.speakerIds.firstIndex(of: id) else { return nil }
        return scores(emb)[i]
    }

    func threshold(_ id: Int) -> Double {
        model.thresholds[model.speakerIds.firstIndex(of: id)!]
    }

    /// 下限を超え、2 位とも差がある人
    func confident(_ emb: [Float]) -> (id: Int?, score: Double) {
        let s = scores(emb)
        let order = s.indices.sorted { s[$0] > s[$1] }
        let best = order[0]
        let margin = order.count > 1 ? s[best] - s[order[1]] : 1.0
        let id = model.speakerIds[best]
        if s[best] >= threshold(id) && margin >= Self.margin { return (id, s[best]) }
        return (nil, s[best])
    }
}

enum VoiceMath {
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let n = dot(v, v).squareRoot()
        return n > 1e-9 ? v.map { $0 / n } : v
    }
}

/// 録音の中の話者・発話に、学習した声で人を当てる (自宅サーバの speakers.identify と speaker_model.apply_model と同じ判断)。
/// 自宅サーバと違い、声のプロファイルは書き換えない (新しい声は「その他」のまま)。
public struct VoiceMatcher: Sendable {
    /// 当てた結果。speakerId は自宅サーバの話者 ID (新しい声・iPhone だけで学習した人は nil)
    public struct Decision: Equatable, Sendable {
        public var speakerId: Int?
        /// 表示名 (名前のない声は「その他」、声と言えないほど短いものは nil)
        public var name: String?
        public var score: Double?

        public static let unknown = Decision(speakerId: nil, name: nil, score: nil)
    }

    public struct Result: Equatable, Sendable {
        public var labels: [String: Decision]
        /// `DeviceSpeakers.utterances` と同じ順
        public var utterances: [Decision]
    }

    /// 発話 1 つ単位で付け替えを考える最短の長さ (秒)
    static let refineSeconds = 1.5

    public let library: VoiceLibrary?

    public init(library: VoiceLibrary?) {
        self.library = library
    }

    public func match(_ device: DeviceSpeakers) -> Result {
        let settings = library?.settings ?? VoiceLibrary.Settings()
        let scorer = VoiceScorer(library?.model)
        var names: [Int: String?] = [:]
        // 声のプロファイル (正規化した平均の声と重み)。identify の中で更新するので複製して使う
        var all: [Int: (vector: [Float], weight: Double)] = [:]
        for p in library?.profiles ?? [] {
            all[p.id] = (VoiceMath.normalized(p.vector.values), p.weight)
            names[p.id] = p.name
        }
        var profiles = all.filter { scorer?.contains($0.key) != true }
        // 録音の中で初めて聞いた声 (負の仮の ID)
        var nextNew = -1

        var labels: [String: Decision] = [:]
        var labelIds: [String: Int?] = [:]
        var labelEmb: [String: [Float]] = [:]
        for voice in device.voices.sorted(by: { $0.seconds > $1.seconds }) {
            let emb = VoiceMath.normalized(voice.embedding.values)
            labelEmb[voice.label] = emb
            var bestId: Int?
            var bestSim = -1.0
            for (id, p) in profiles {
                let s = Double(VoiceMath.dot(emb, p.vector))
                if s > bestSim || (s == bestSim && id < (bestId ?? .max)) {
                    bestId = id
                    bestSim = s
                }
            }
            if let scorer {
                let (learned, score) = scorer.confident(emb)
                if let learned {
                    let learnedSim = all[learned].map { Double(VoiceMath.dot(emb, $0.vector)) } ?? 1.0
                    if !(bestId != nil && bestSim >= settings.matchThreshold && bestSim > learnedSim) {
                        labelIds[voice.label] = learned
                        labels[voice.label] = Decision(speakerId: learned, name: nil, score: score)
                        continue
                    }
                }
            }
            if let id = bestId, bestSim >= settings.matchThreshold {
                let p = profiles[id]!
                let updated = zip(p.vector, emb).map { $0 * Float(p.weight) + $1 * Float(voice.seconds) }
                profiles[id] = (VoiceMath.normalized(updated), p.weight + voice.seconds)
                if all[id] != nil { all[id] = profiles[id] }
                labelIds[voice.label] = id
                labels[voice.label] = Decision(speakerId: id, name: nil, score: bestSim)
            } else if voice.seconds >= settings.minSeconds {
                let id = nextNew
                nextNew -= 1
                profiles[id] = (emb, voice.seconds)
                all[id] = profiles[id]
                labelIds[voice.label] = id
                labels[voice.label] = Decision(speakerId: id, name: nil, score: nil)
            } else {
                labelIds[voice.label] = .some(nil)
                labels[voice.label] = .unknown
            }
        }

        let vectors = all.mapValues(\.vector)
        // 学習したモデルで、ラベルの人を付け直す (今の人でも十分その人らしければ変えない)
        if let scorer {
            for (label, emb) in labelEmb {
                let current = labelIds[label] ?? nil
                if let new = decideLabel(scorer, emb, current: current, profiles: vectors) {
                    labelIds[label] = new
                    labels[label] = Decision(speakerId: new, name: nil, score: scorer.score(emb, for: new))
                }
            }
        }

        // 発話ごとに、ラベルの人と違うと言えるなら付け替える
        var utterances: [Decision] = []
        for u in device.utterances {
            let labelId: Int? = u.label.flatMap { labelIds[$0] ?? nil }
            var id = labelId
            var score = u.label.flatMap { labels[$0]?.score }
            if let scorer, let e = u.embedding, u.end - u.start >= Self.refineSeconds {
                let emb = VoiceMath.normalized(e.values)
                if let auto = decideUtterance(scorer, emb, labelSpeaker: labelId, profiles: vectors) {
                    id = auto
                    score = scorer.score(emb, for: auto)
                }
            }
            if let id {
                utterances.append(Decision(speakerId: id, name: nil, score: score))
            } else {
                utterances.append(u.label.flatMap { labels[$0] } ?? .unknown)
            }
        }

        // 名前を付ける (名前のない声と新しい声は「その他」。仮の ID は外す)
        func named(_ d: Decision) -> Decision {
            guard let id = d.speakerId else { return d }
            let name = (names[id] ?? nil).flatMap { isNamedSpeaker($0) ? $0 : nil } ?? otherSpeakerName
            return Decision(speakerId: id > 0 ? id : nil, name: name, score: d.score)
        }
        return Result(labels: labels.mapValues(named), utterances: utterances.map(named))
    }

    func closerToCurrent(_ emb: [Float], current: Int?, learned: Int, profiles: [Int: [Float]]) -> Bool {
        guard let current, let c = profiles[current], let l = profiles[learned] else { return false }
        return VoiceMath.dot(emb, c) >= VoiceMath.dot(emb, l)
    }

    func decideLabel(_ scorer: VoiceScorer, _ emb: [Float], current: Int?, profiles: [Int: [Float]]) -> Int? {
        let (best, _) = scorer.confident(emb)
        guard let best, best != current else { return nil }
        if let current, scorer.contains(current) {
            if let s = scorer.score(emb, for: current), s >= scorer.threshold(current) { return nil }
        } else if closerToCurrent(emb, current: current, learned: best, profiles: profiles) {
            return nil
        }
        return best
    }

    func decideUtterance(_ scorer: VoiceScorer, _ emb: [Float], labelSpeaker: Int?, profiles: [Int: [Float]]) -> Int? {
        let (best, score) = scorer.confident(emb)
        guard let best, best != labelSpeaker else { return nil }
        if let labelSpeaker, scorer.contains(labelSpeaker) {
            if let own = scorer.score(emb, for: labelSpeaker), own >= scorer.threshold(labelSpeaker),
               score - own < VoiceScorer.switchMargin { return nil }
        } else if closerToCurrent(emb, current: labelSpeaker, learned: best, profiles: profiles) {
            return nil
        }
        return best
    }

    /// 文字起こしの区間に話者を付ける。人が指定した区間 (speakerManual) は変えない。変わったら true
    @discardableResult
    public func apply(_ result: Result, device: DeviceSpeakers, to transcript: inout Transcript) -> Bool {
        var changed = false
        for i in transcript.pieces.indices where transcript.pieces[i].speakerManual != true {
            let p = transcript.pieces[i]
            var label = Self.label(for: p.start, p.end, turns: device.turns)
            var decision = label.flatMap { result.labels[$0] } ?? .unknown
            if let u = Self.utteranceIndex(for: p.start, p.end, utterances: device.utterances), u < result.utterances.count {
                decision = result.utterances[u]
                label = device.utterances[u].label ?? label
            }
            if p.speaker != decision.name || p.speakerId != decision.speakerId || p.speakerLabel != label {
                transcript.pieces[i].speaker = decision.name
                transcript.pieces[i].speakerId = decision.speakerId
                transcript.pieces[i].speakerLabel = label
                changed = true
            }
        }
        return changed
    }

    /// 区間と最も長く重なる話者ラベル (重ならなければ 1 秒以内の最も近い区間)
    public static func label(for start: Double, _ end: Double, turns: [SpeakerTurn]) -> String? {
        var best: String?
        var bestOverlap = 0.0
        for t in turns {
            let overlap = min(end, t.end) - max(start, t.start)
            if overlap > bestOverlap {
                best = t.label
                bestOverlap = overlap
            }
        }
        if best == nil, !turns.isEmpty {
            let mid = (start + end) / 2
            func gap(_ t: SpeakerTurn) -> Double { min(abs(mid - t.start), abs(mid - t.end)) }
            if let nearest = turns.min(by: { gap($0) < gap($1) }), gap(nearest) < 1.0 { best = nearest.label }
        }
        return best
    }

    /// 文字起こしの区間に対応する発話 (区間の半分以上が重なるもの)
    static func utteranceIndex(for start: Double, _ end: Double, utterances: [DeviceSpeakers.Utterance]) -> Int? {
        let length = max(end - start, 1e-3)
        var best: Int?
        var bestOverlap = 0.0
        for (i, u) in utterances.enumerated() {
            let overlap = min(end, u.end) - max(start, u.start)
            if overlap > bestOverlap {
                best = i
                bestOverlap = overlap
            }
        }
        guard let best, bestOverlap >= 0.5 * min(length, utterances[best].end - utterances[best].start) else { return nil }
        return best
    }

    /// 話者分離の区間を、同じ話者が続けて話した発話にまとめる (自宅サーバの regions_from_turns と同じ)
    public static func regions(_ turns: [SpeakerTurn], mergeGap: Double = 1.0, maxSeconds: Double = 28.0,
                               pad: Double = 0, duration: Double? = nil) -> [(start: Double, end: Double, label: String)] {
        var merged: [(Double, Double, String)] = []
        for t in turns.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, last.2 == t.label, t.start - last.1 <= mergeGap, t.end - last.0 <= maxSeconds {
                merged[merged.count - 1].1 = max(last.1, t.end)
            } else {
                merged.append((t.start, t.end, t.label))
            }
        }
        var out: [(start: Double, end: Double, label: String)] = []
        for (s0, e0, label) in merged {
            var s = max(0, s0 - pad)
            let e = duration.map { min($0, e0 + pad) } ?? e0 + pad
            while e - s > maxSeconds {
                out.append((s, s + maxSeconds, label))
                s += maxSeconds
            }
            out.append((s, e, label))
        }
        return out
    }
}

public extension VoiceLibrary {
    /// 名前の人らしさ (学習した人だけ): 点数と、「確認したい発話」の線
    func likeness(_ embedding: [Float], name: String) -> (score: Double, review: Double)? {
        guard let model, let scorer = VoiceScorer(model),
              let id = profiles.first(where: { $0.name == name && model.speakerIds.contains($0.id) })?.id,
              let i = model.speakerIds.firstIndex(of: id) else { return nil }
        let s = scorer.scores(VoiceMath.normalized(embedding))[i]
        return (s, model.review?[safe: i] ?? model.thresholds[i])
    }

    /// 学習した人の名前
    var learnedNames: [String] {
        guard let model else { return [] }
        return profiles.filter { model.speakerIds.contains($0.id) }.compactMap(\.name)
    }
}

public extension DeviceSpeakers {
    /// 時間の範囲と最も重なる発話の声の特徴
    func embedding(for start: Double, _ end: Double) -> [Float]? {
        var best: (Double, [Float])?
        for u in utterances {
            guard let e = u.embedding?.values else { continue }
            let overlap = min(end, u.end) - max(start, u.start)
            if overlap > 0, overlap >= 0.5 * min(end - start, u.end - u.start), overlap > (best?.0 ?? 0) { best = (overlap, e) }
        }
        return best?.1
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
