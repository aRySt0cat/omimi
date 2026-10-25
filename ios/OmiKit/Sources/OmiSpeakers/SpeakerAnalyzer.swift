import Foundation
import OmiKit

/// 録音 1 件の話者分離と声の特徴づくり (自宅サーバの worker.process_diarization と同じ手順)。
/// 名前の当てはめは `VoiceMatcher` で行う (学習した声が変わっても、ここをやり直さずに付け直せる)。
public struct SpeakerAnalyzer: Sendable {
    public static let engine = "pyannote-segmentation-3.0+wespeaker-resnet34@iphone"
    /// 話者ごとの声の特徴に使う最長の音声 (秒)
    static let maxVoiceSeconds = 60.0
    /// 声の特徴を取る発話の最短の長さ (秒)
    static let minUtteranceSeconds = 1.0

    public let networks: SpeakerNetworks

    public init(networks: SpeakerNetworks) {
        self.networks = networks
    }

    /// - Parameter audio: 16 kHz モノラル (-1〜1)
    public func analyze(_ audio: [Float], settings: VoiceLibrary.Settings = .init()) throws -> DeviceSpeakers {
        let started = Date()
        let rate = Double(SpeakerNetworks.sampleRate)
        let turns = try Diarizer(clusteringThreshold: settings.diarizationThreshold).diarize(audio, networks: networks)

        func clip(_ start: Double, _ end: Double) -> ArraySlice<Float> {
            let a = max(0, min(audio.count, Int(start * rate))), b = max(a, min(audio.count, Int(end * rate)))
            return audio[a..<b]
        }

        // 話者ラベルごとに発話をつなげて声の特徴を取る
        var joined: [String: [Float]] = [:]
        var order: [String] = []
        for t in turns {
            if joined[t.label] == nil { order.append(t.label) }
            joined[t.label, default: []].append(contentsOf: clip(t.start, t.end))
        }
        var voices: [DeviceSpeakers.Voice] = []
        for label in order {
            try Task.checkCancellation()
            guard let samples = joined[label], samples.count >= SpeakerNetworks.sampleRate / 2 else { continue }
            let limit = min(samples.count, Int(Self.maxVoiceSeconds * rate))
            guard let e = try networks.embed(Array(samples[..<limit])) else { continue }
            voices.append(.init(label: label, seconds: Double(samples.count) / rate, embedding: normalized(e)))
        }

        var utterances: [DeviceSpeakers.Utterance] = []
        let duration = Double(audio.count) / rate
        for r in VoiceMatcher.regions(turns, pad: 0, duration: duration) {
            try Task.checkCancellation()
            var e: [Float]?
            if r.end - r.start >= Self.minUtteranceSeconds {
                e = try networks.embed(Array(clip(r.start, r.end))).map(normalized)
            }
            utterances.append(.init(start: (r.start * 1000).rounded() / 1000, end: (r.end * 1000).rounded() / 1000,
                                    label: r.label, embedding: e))
        }
        return DeviceSpeakers(engine: Self.engine, turns: turns, voices: voices, utterances: utterances,
                              processingSeconds: Date().timeIntervalSince(started))
    }
}
