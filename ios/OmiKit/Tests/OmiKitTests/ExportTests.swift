import Foundation
import Testing
@testable import OmiKit

/// 音声と文字起こしの書き出し (PC での分析用)
@Suite struct ExportTests {
    /// 本物の Opus で 2 秒の録音を作る
    func record(_ store: SegmentStore, at start: Date, pieces: [TranscriptPiece]) throws -> SegmentMetadata {
        let samples = (0..<32_000).map { Int16(8000 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        let packets = try OpusEncoder().encode(samples: samples)
        let recorder = SegmentRecorder(store: store)
        _ = try recorder.append(packets.map { AudioFrame(data: $0) }, context: .init(), now: start)
        let meta = try #require(try recorder.close())
        return try #require(store.update(meta.id) {
            $0.transcriptionState = .done
            $0.transcript = Transcript(engine: "apple-speech", locale: "ja-JP", pieces: pieces)
        })
    }

    @Test func transcriptsAndAudio() throws {
        let root = try tempDir()
        let store = try SegmentStore(directory: root.appendingPathComponent("store"))
        let t0 = Date(timeIntervalSince1970: 1_791_850_000)  // 2026-10-13 09:06:40 (日本時間)
        let a = try record(store, at: t0, pieces: [
            TranscriptPiece(start: 0.2, end: 1.0, text: "下川内さん、おはよう", language: "ja", speaker: "自分", speakerManual: true),
            TranscriptPiece(start: 1.1, end: 1.9, text: "おはよう, \"元気\"?", language: "ja", speaker: otherSpeakerName, speakerLabel: "S1"),
        ])
        let silent = try record(store, at: t0.addingTimeInterval(600), pieces: [])
        let markers = [Marker(kind: .highlight, at: t0.addingTimeInterval(1))]
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        let corrector = VocabularyCorrector([VocabularyEntry(id: 1, term: "下河内", aliases: ["下川内"])])

        // 話し声のない録音は、既定では書き出さない
        let selected = OmiExport.select(store.all(), interval: DateInterval(start: t0.addingTimeInterval(-60), duration: 3600))
        #expect(selected.map(\.id) == [a.id])
        #expect(OmiExport.select(store.all(), interval: nil, includeSilent: true).map(\.id) == [a.id, silent.id])

        // 期待するファイル名と時刻 (録音の開始は、受け取った音声の長さだけ前になる)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let base = "\(f.string(from: a.startedAt))_\(a.id)"
        f.dateFormat = "HH:mm:ss"
        let startClock = f.string(from: a.startedAt.addingTimeInterval(0.2)), endClock = f.string(from: a.startedAt.addingTimeInterval(1.0))

        // 文字起こし
        let tdir = root.appendingPathComponent("t")
        let t = try OmiExport.transcripts(selected, markers: markers, corrector: corrector, timeZone: tz, to: tdir)
        #expect(t.recordings == 1)
        let csv = try Data(contentsOf: tdir.appendingPathComponent("utterances.csv"))
        #expect(csv.prefix(3) == Data([0xEF, 0xBB, 0xBF]))  // Excel 向けの BOM
        let lines = String(decoding: csv.dropFirst(3), as: UTF8.self).components(separatedBy: "\r\n")
        #expect(lines[0] == "date,start,end,recording_id,offset_start_s,offset_end_s,speaker,language,text,source,manual")
        #expect(lines[1] == "2026-10-13,\(startClock),\(endClock),\(a.id),0.2,1.0,自分,ja,下河内さん、おはよう,device,1")
        #expect(lines[2].hasSuffix(",その他,ja,\"おはよう, \"\"元気\"\"?\",device,0"))
        let jsonl = try String(contentsOf: tdir.appendingPathComponent("utterances.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        #expect(jsonl.count == 2 && jsonl[0]["original_text"] as? String == "下川内さん、おはよう")
        #expect((jsonl[0]["start"] as? String)?.hasPrefix("2026-10-13T09:06:") == true && (jsonl[0]["start"] as? String)?.hasSuffix("+09:00") == true)
        #expect(jsonl[1]["speaker_label"] as? String == "S1" && jsonl[0]["manual"] as? Bool == true)
        let srt = try String(contentsOf: tdir.appendingPathComponent("subtitles/2026-10-13/\(base).srt"), encoding: .utf8)
        #expect(srt.hasPrefix("1\n00:00:00,200 --> 00:00:01,000\n自分: 下河内さん、おはよう\n\n2\n"))
        #expect(try String(contentsOf: tdir.appendingPathComponent("days/2026-10-13.md"), encoding: .utf8).contains("⭐ **注目**"))
        let markerCSV = String(decoding: try Data(contentsOf: tdir.appendingPathComponent("markers.csv")).dropFirst(3), as: UTF8.self)
        #expect(markerCSV.contains(",highlight,注目,\(a.id)"))
        #expect(FileManager.default.fileExists(atPath: tdir.appendingPathComponent("README.txt").path))

        // 音声 (そのまま / WAV)。ファイル名は字幕と同じ
        let opusDir = root.appendingPathComponent("a1")
        let o = try OmiExport.audio(selected, store: store, format: .opus, timeZone: tz, to: opusDir)
        let opus = opusDir.appendingPathComponent("2026-10-13/\(base).opus")
        #expect(o.files == 1 && FileManager.default.fileExists(atPath: opus.path))
        let copied = try Data(contentsOf: opus), original = try Data(contentsOf: store.audioURL(for: a))
        #expect(copied == original)
        let recordings = String(decoding: try Data(contentsOf: opusDir.appendingPathComponent("recordings.csv")).dropFirst(3), as: UTF8.self)
        #expect(recordings.contains("2026-10-13/\(base).opus"))
        let wavDir = root.appendingPathComponent("a2")
        var steps: [Int] = []
        _ = try OmiExport.audio(selected, store: store, format: .wav, timeZone: tz, to: wavDir) { done, _ in steps.append(done) }
        let wav = try Data(contentsOf: wavDir.appendingPathComponent("2026-10-13/\(base).wav"))
        #expect(wav.prefix(4) == Data("RIFF".utf8) && abs(wav.count - 44 - 64_000) < 4_000)
        #expect(steps == [0, 1])

        // zip
        let z = try OmiExport.zip(tdir)
        let zipped = try Data(contentsOf: z)
        #expect(z.lastPathComponent == "t.zip" && zipped.prefix(2) == Data("PK".utf8))
    }
}
