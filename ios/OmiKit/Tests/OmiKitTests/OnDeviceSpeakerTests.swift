import CoreML
import Foundation
import Testing
@testable import OmiKit
@testable import OmiSpeakers

/// iPhone の話者分離。期待値は自宅サーバと同じ実装 (kaldi-native-fbank / ONNX / sherpa-onnx / サーバの話者識別) で
/// 合成した入力から作ったもの (ios/Tools/make_speaker_fixtures.py)。
@Suite struct OnDeviceSpeakerTests {
    struct Fixture: Decodable {
        struct Fbank: Decodable { var seconds: Double; var f0: Double; var frames: Int; var rows: [String: [Float]] }
        struct Embedding: Decodable { var a: [Float]; var b: [Float] }
        struct Clustering: Decodable { var seed: Int; var n: Int; var d: Int; var labels: [String: [Int]] }
        struct Matcher: Decodable {
            struct Expected: Decodable { var name: String?; var speakerId: Int? }
            var library: VoiceLibrary
            var voices: [DeviceSpeakers.Voice]
            var utterances: [DeviceSpeakers.Utterance]
            var expected: [Expected]
        }
        struct Trainer: Decodable {
            struct S: Decodable { var embedding: PackedFloats; var person: String; var weight: Double; var confirmed: Bool }
            struct Expected: Decodable {
                var people: [String]; var projection: Bool; var thresholds: [Double]; var review: [Double]
                var centroids: [PackedFloats]
            }
            var samples: [S]
            var background: [PackedFloats]
            var expected: Expected
        }
        var fbank: Fbank
        var embedding: Embedding
        var clustering: Clustering
        var matcher: Matcher
        var trainer: Trainer
        var trainerWccn: Trainer
    }

    static let fixture: Fixture = {
        let url = Bundle.module.url(forResource: "speakers", withExtension: "json", subdirectory: "Fixtures")!
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try! d.decode(Fixture.self, from: Data(contentsOf: url))
    }()

    /// make_speaker_fixtures.py の signal() と同じ合成音
    static func signal(seconds: Double, f0: Double, phase: Double = 0) -> [Float] {
        var state: UInt64 = 7
        return (0..<Int(seconds * 16_000)).map { i in
            let t = Double(i) / 16_000
            let inst = f0 * t + 0.5 * sin(2 * .pi * 2 * t + phase)
            var x = 0.0
            for k in 1...5 { x += 0.12 / Double(k) * sin(2 * .pi * Double(k) * inst) }
            state = (state &* 1103515245 &+ 12345) % (1 << 31)
            let noise = Double(state) / Double(1 << 30) - 1
            return Float(x * (0.6 + 0.4 * sin(2 * .pi * 0.5 * t)) + 0.01 * noise)
        }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        VoiceMath.dot(VoiceMath.normalized(a), VoiceMath.normalized(b))
    }

    @Test func fbankMatchesKaldi() {
        let f = Self.fixture.fbank
        let feats = KaldiFbank().compute(Self.signal(seconds: f.seconds, f0: f.f0))
        #expect(feats.count == f.frames * 80)
        for (key, row) in f.rows {
            let i = Int(key)!
            let mine = Array(feats[(i * 80)..<((i + 1) * 80)])
            let worst = zip(mine, row).map { abs($0 - $1) }.max()!
            #expect(worst < 2e-3, "frame \(i): \(worst)")
        }
    }

    @Test func clusteringMatchesSherpa() {
        let c = Self.fixture.clustering
        var state: UInt64 = UInt64(c.seed)
        let vectors: [[Float]] = (0..<c.n).map { _ in
            (0..<c.d).map { _ in
                state = (state &* 1103515245 &+ 12345) % (1 << 31)
                return Float(Double(state) / Double(1 << 30) - 1)
            }
        }
        for (t, expected) in c.labels {
            #expect(Diarizer.completeLinkage(vectors.map(VoiceMath.normalized), threshold: Double(t)!) == expected, "threshold \(t)")
        }
        #expect(Diarizer.completeLinkage([], threshold: 0.3) == [])
        #expect(Diarizer.completeLinkage([[1, 0]], threshold: 0.3) == [0])
    }

    /// 自宅サーバの identify / decide_label / decide_utterance と同じ名前になる
    @Test func matcherAgreesWithServer() {
        let m = Self.fixture.matcher
        let device = DeviceSpeakers(engine: "test", turns: [], voices: m.voices, utterances: m.utterances, processingSeconds: 0)
        let result = VoiceMatcher(library: m.library).match(device)
        #expect(result.utterances.map(\.name) == m.expected.map(\.name))
        #expect(result.utterances.map(\.speakerId) == m.expected.map(\.speakerId))
        // 学習した声がなければ、名前は当てない (声はすべて「その他」、短いものは不明)
        let none = VoiceMatcher(library: nil).match(device)
        #expect(none.utterances.allSatisfy { !isNamedSpeaker($0.name) })
        #expect(none.labels["S0"]?.name == otherSpeakerName && none.labels["S0"]?.speakerId == nil)
    }

    @Test func appliesToTranscriptButKeepsManualPieces() {
        let m = Self.fixture.matcher
        let turns = [SpeakerTurn(start: 0, end: 5, label: "S0"), SpeakerTurn(start: 5.5, end: 8, label: "S1"),
                     SpeakerTurn(start: 8.5, end: 11, label: "S2")]
        let device = DeviceSpeakers(engine: "test", turns: turns, voices: m.voices, utterances: m.utterances, processingSeconds: 0)
        let matcher = VoiceMatcher(library: m.library)
        let result = matcher.match(device)
        var t = Transcript(engine: "apple", locale: "ja-JP", pieces: [
            TranscriptPiece(start: 0.2, end: 2.8, text: "おはよう"),
            TranscriptPiece(start: 3.6, end: 4.9, text: "元気?"),
            TranscriptPiece(start: 5.6, end: 6.9, text: "うん", speaker: "佐藤", speakerManual: true),
            TranscriptPiece(start: 9.0, end: 10.5, text: "どうも"),
        ])
        #expect(matcher.apply(result, device: device, to: &t))
        #expect(t.pieces.map(\.speaker) == ["自分", "田中", "佐藤", otherSpeakerName])
        #expect(t.pieces[0].speakerId == 1 && t.pieces[3].speakerId == 3)
        #expect(!matcher.apply(result, device: device, to: &t))  // 2 回目は変わらない
    }

    /// 自宅サーバの speaker_model.train と同じ学習 (白色化を使わない場合と使う場合)
    @Test(arguments: [false, true]) func trainerAgreesWithServer(wccn: Bool) throws {
        let t = wccn ? Self.fixture.trainerWccn : Self.fixture.trainer
        let lib = try #require(VoiceTrainer.train(
            samples: t.samples.map { .init(embedding: $0.embedding.values, person: $0.person, weight: $0.weight, confirmed: $0.confirmed) },
            background: t.background.map(\.values)))
        let model = try #require(lib.model)
        let names = model.speakerIds.map { id in lib.profiles.first { $0.id == id }!.name! }
        #expect(names == t.expected.people)
        #expect((model.projection != nil) == t.expected.projection)
        for (a, b) in zip(model.thresholds, t.expected.thresholds) { #expect(abs(a - b) < 1e-4) }
        for (a, b) in zip(model.review ?? [], t.expected.review) { #expect(abs(a - b) < 1e-4) }
        for (a, b) in zip(model.centroids, t.expected.centroids) { #expect(Self.cosine(a.values, b.values) > 0.9999) }
        #expect(lib.source == "iphone" && model.speakerIds.allSatisfy { $0 < 0 })
    }

    /// iPhone だけで学習した人は、ID なしで名前だけを付ける
    @Test func onDeviceLibraryNamesWithoutIDs() throws {
        let t = Self.fixture.trainer
        let lib = try #require(VoiceTrainer.train(
            samples: t.samples.map { .init(embedding: $0.embedding.values, person: $0.person, weight: $0.weight, confirmed: $0.confirmed) },
            background: []))
        let a = t.samples.first { $0.person == "A" && $0.confirmed }!.embedding.values
        let device = DeviceSpeakers(engine: "t", turns: [SpeakerTurn(start: 0, end: 5, label: "S0")],
                                    voices: [.init(label: "S0", seconds: 5, embedding: a)],
                                    utterances: [.init(start: 0, end: 5, label: "S0", embedding: a)], processingSeconds: 0)
        let r = VoiceMatcher(library: lib).match(device)
        #expect(r.labels["S0"] == VoiceMatcher.Decision(speakerId: nil, name: "A", score: r.labels["S0"]?.score))
        #expect(r.utterances[0].name == "A" && r.utterances[0].speakerId == nil)
    }

    @Test func eigenDecomposition() {
        // 対称行列 A = V Λ Vᵀ を復元できる
        let n = 5
        var a = [Double](repeating: 0, count: n * n)
        for i in 0..<n { for j in 0..<n { a[i * n + j] = 1.0 / Double(i + j + 1) + (i == j ? 1 : 0) } }
        let (values, vectors) = VoiceTrainer.symmetricEigen(a, n: n)
        for i in 0..<n {
            for j in 0..<n {
                var s = 0.0
                for e in 0..<n { s += vectors[i * n + e] * values[e] * vectors[j * n + e] }
                #expect(abs(s - a[i * n + j]) < 1e-10)
            }
        }
        #expect(VoiceTrainer.percentile([1, 2, 3, 4], 25) == 1.75 && VoiceTrainer.percentile([5], 90) == 5)
    }

    /// 名前も ID もない声は、録音の中の話者 (ラベル) で見分けて直せる
    @Test func labelScopeForUnnamedVoices() {
        var t = Transcript(engine: "apple", locale: "ja-JP", pieces: [
            TranscriptPiece(start: 0, end: 2, text: "a", speaker: otherSpeakerName, speakerLabel: "S0"),
            TranscriptPiece(start: 2, end: 4, text: "b", speaker: otherSpeakerName, speakerLabel: "S1"),
            TranscriptPiece(start: 4, end: 6, text: "c", speaker: otherSpeakerName, speakerLabel: "S0"),
            TranscriptPiece(start: 6, end: 8, text: "d", speaker: "自分", speakerId: 3, speakerLabel: "S2"),
        ])
        #expect(!t.pieces[0].sameSpeaker(as: t.pieces[1]) && t.pieces[0].sameSpeaker(as: t.pieces[2]))
        let edit = SpeakerEdit(segmentId: "s", scope: .label("S0"), target: .newName("佐藤"))
        #expect(t.pieces.map(edit.matches) == [true, false, true, false])
        #expect(edit.apply(to: &t))
        #expect(t.pieces.map(\.speaker) == ["佐藤", otherSpeakerName, "佐藤", "自分"])
        // 名前だけの人 (ID なし) は名前で
        #expect(SpeakerEdit(segmentId: "s", scope: .named("佐藤"), target: .unknown).apply(to: &t))
        #expect(t.pieces.map(\.speaker) == [nil, otherSpeakerName, nil, "自分"])
    }

    /// サーバの regions_from_turns と同じまとめ方
    @Test func regionsLikeServer() {
        let turns = [SpeakerTurn(start: 0, end: 2, label: "S0"), SpeakerTurn(start: 2.5, end: 4, label: "S0"),
                     SpeakerTurn(start: 6, end: 40, label: "S1"), SpeakerTurn(start: 41.5, end: 42, label: "S1")]
        let r = VoiceMatcher.regions(turns, duration: 45)
        #expect(r.map(\.start) == [0, 6, 34, 41.5] && r.map(\.end) == [4, 34, 40, 42])
        #expect(r.map(\.label) == ["S0", "S1", "S1", "S1"])
    }

    @Test func packedFloatsRoundTrip() throws {
        let v: [Float] = [0.5, -1.25, 3.0e-3, 0]
        let d = DeviceSpeakers(engine: "e", turns: [], voices: [.init(label: "S0", seconds: 1, embedding: v)],
                               utterances: [.init(start: 0, end: 1, label: nil, embedding: nil)], processingSeconds: 0.1)
        let back = try JSONDecoder.omi.decode(DeviceSpeakers.self, from: JSONEncoder.omi.encode(d))
        #expect(back.voices[0].embedding.values == v.map { Float(Float16($0)) })
        let lib = VoiceLibrary(version: "v", source: "iphone", profiles: [.init(id: 1, name: "a", weight: 1, vector: v)], model: nil)
        #expect(try JSONDecoder.omi.decode(VoiceLibrary.self, from: JSONEncoder.omi.encode(lib)) == lib)
    }

    // MARK: - Core ML (アプリに同梱するモデル)

    static var modelsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../Omimi/Models").standardized
    }

    static let networks: SpeakerNetworks? = {
        let dir = modelsDirectory
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("SpeakerEmbedding.mlpackage").path) else { return nil }
        let seg = try! MLModel.compileModel(at: dir.appendingPathComponent("SpeakerSegmentation.mlpackage"))
        let emb = try! MLModel.compileModel(at: dir.appendingPathComponent("SpeakerEmbedding.mlpackage"))
        return try! SpeakerNetworks(segmentationURL: seg, embeddingURL: emb, computeUnits: .cpuAndNeuralEngine)
    }()

    @Test(.enabled(if: networks != nil)) func embeddingMatchesONNX() throws {
        let nets = try #require(Self.networks)
        let a = try #require(try nets.embed(Self.signal(seconds: 2, f0: 140)))
        let b = try #require(try nets.embed(Self.signal(seconds: 2, f0: 230, phase: 1)))
        #expect(Self.cosine(a, Self.fixture.embedding.a) > 0.999)
        #expect(Self.cosine(b, Self.fixture.embedding.b) > 0.999)
        // 短すぎる音声は特徴を取らない (サーバでも NaN になる長さ)
        #expect(try nets.embed([Float](repeating: 0.1, count: 1200)) == nil)
    }

    @Test(.enabled(if: networks != nil)) func silenceHasNoSpeakers() throws {
        let nets = try #require(Self.networks)
        let diarizer = Diarizer()
        #expect(try diarizer.diarize([Float](repeating: 0, count: 4000), networks: nets).isEmpty)  // 0.5 秒未満
        #expect(try diarizer.diarize([Float](repeating: 0, count: 16_000 * 3), networks: nets).isEmpty)  // 1 窓
        #expect(try diarizer.diarize([Float](repeating: 0, count: 16_000 * 25 + 123), networks: nets).isEmpty)  // 複数の窓 + 端
        let result = try SpeakerAnalyzer(networks: nets).analyze([Float](repeating: 0, count: 16_000 * 12))
        #expect(result.turns.isEmpty && result.voices.isEmpty && result.utterances.isEmpty)
    }
}
