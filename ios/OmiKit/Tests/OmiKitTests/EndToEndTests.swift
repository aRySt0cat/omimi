@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import OmiKit
@testable import OmiTranscription

/// macOS の `say` で日本語音声を作り、BLE 受信 → 保存 → Apple 文字起こしまで通す。
/// 音声モデルのダウンロードが必要なため `OMI_E2E=1` のときだけ実行する。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OMI_E2E"] == "1"))
struct EndToEndTests {
    func speech(_ text: String, voice: String = "Kyoko") throws -> [Int16] {
        let dir = try tempDir()
        let aiff = dir.appendingPathComponent("speech.aiff")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", aiff.path, text]
        try p.run()
        p.waitUntilExit()

        let file = try AVAudioFile(forReading: aiff)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: src)
        let conv = AVAudioConverter(from: file.processingFormat, to: target)!
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(file.length))!
        var supplied = false
        var error: NSError?
        _ = conv.convert(to: out, error: &error) { _, s in
            if supplied { s.pointee = .endOfStream; return nil }
            supplied = true
            s.pointee = .haveData
            return src
        }
        return Array(UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength)))
    }

    @Test func bleToTranscript() async throws {
        let locale = Locale(identifier: "ja-JP")
        if await AppleSpeechTranscriber.modelStatus(for: locale) != .installed {
            try await AppleSpeechTranscriber.installModel(for: locale)
        }
        let samples = try speech("明日の会議は午後三時から始まります。資料の準備をお願いします。")
        let packets = try OpusEncoder().encode(samples: samples)

        let store = try SegmentStore(directory: try tempDir())
        let recorder = SegmentRecorder(store: store)
        var assembler = AudioPacketAssembler()
        for (i, p) in packets.enumerated() where i % 50 != 25 { // 1 秒に 1 パケット欠落させる
            let n = Data([UInt8(i & 0xFF), UInt8(i >> 8), 0]) + p
            _ = try recorder.append(assembler.push(n), context: .init())
        }
        _ = try recorder.append(assembler.flush(), context: .init())
        let meta = try #require(try recorder.close())
        #expect(meta.concealedFrames > 0)
        #expect(abs(meta.durationSeconds - Double(packets.count) * 0.02) < 0.05)

        let transcript = try await AppleSpeechTranscriber.transcribe(segmentURL: store.audioURL(for: meta), locale: locale)
        print(transcript.pieces)
        #expect(transcript.text.contains("会議"))
        #expect(transcript.pieces.first.map { $0.start >= 0 && $0.end <= meta.durationSeconds + 0.5 } == true)
    }

    @Test func japaneseEnglishAutoDetection() async throws {
        let locales = [Locale(identifier: "ja-JP"), Locale(identifier: "en-US")]
        if await AppleSpeechTranscriber.modelStatus(for: locales) != .installed {
            try await AppleSpeechTranscriber.installModel(for: locales)
        }
        let gap = [Int16](repeating: 0, count: 11_200)
        let samples = try speech("おはようございます。今日の会議の資料はもう準備できましたか。") + gap
            + speech("Good morning. Yes, I finished the slides last night, and I sent them to everyone.", voice: "Daniel") + gap
            + speech("ありがとうございます。では午後二時から始めましょう。")
        let t = try await AppleSpeechTranscriber.transcribe(samples: samples, sampleRate: 16_000, locales: locales)
        for p in t.pieces { print(String(format: "%5.1f-%5.1f [%@] %@", p.start, p.end, p.language ?? "-", p.text)) }
        let en = t.pieces.filter { $0.language == "en" }.map(\.text).joined(separator: " ")
        let ja = t.pieces.filter { $0.language == "ja" }.map(\.text).joined()
        #expect(en.contains("slides"))
        #expect(ja.contains("会議"))
        #expect(ja.contains("始めましょう"))
        #expect(!ja.contains("フィニッシュ"))
        #expect(t.locale == "ja-JP+en-US")
    }
}
