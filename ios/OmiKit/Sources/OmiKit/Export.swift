import Foundation

/// 録音と文字起こしの書き出し (PC での分析用)。音声と文字起こしは別々のフォルダにし、zip にして渡す。
/// どちらにも録音の一覧 (recordings.csv / .jsonl) を入れ、録音 ID とファイル名で突き合わせられるようにする。
public enum OmiExport {
    public enum AudioFormat: String, CaseIterable, Sendable {
        /// 録ったまま (Ogg Opus, 16 kHz モノラル)。小さい
        case opus
        /// WAV (16 kHz / 16 bit / モノラル)。多くの道具でそのまま読める (1 分 約 1.9 MB)
        case wav
    }

    public struct Result: Sendable {
        public var directory: URL
        public var recordings: Int
        public var files: Int
        public var bytes: Int64
    }

    /// 期間の中の、話し声のある (または分からない) 録音
    public static func select(_ segments: [SegmentMetadata], interval: DateInterval?, includeSilent: Bool = false) -> [SegmentMetadata] {
        segments.filter { m in
            guard m.state == .closed else { return false }
            if !includeSilent && m.hasSpeech == false { return false }
            return interval.map { $0.start <= m.startedAt && m.startedAt < $0.end } ?? true
        }.sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - 音声

    public static func audio(_ segments: [SegmentMetadata], store: SegmentStore, format: AudioFormat, timeZone: TimeZone = .current,
                             to dir: URL, progress: ((Int, Int) -> Void)? = nil) throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        var bytes: Int64 = 0
        var files = 0
        let names = Names(timeZone: timeZone)
        for (i, meta) in segments.enumerated() {
            progress?(i, segments.count)
            let source = store.audioURL(for: meta)
            guard fm.fileExists(atPath: source.path) else { continue }
            let folder = dir.appendingPathComponent(names.day(meta.startedAt), isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("\(names.base(meta)).\(format.rawValue)")
            switch format {
            case .opus:
                try? fm.removeItem(at: file)
                try fm.copyItem(at: source, to: file)
            case .wav:
                let ogg = try OggOpusReader.read(url: source, verifyCRC: false)
                let rate = ogg.head.inputSampleRate == 0 ? 16_000 : Int(ogg.head.inputSampleRate)
                let samples = try OpusDecoder(sampleRate: Double(rate)).decodeSamples(ogg.packets)
                try WAV.make(samples: samples, sampleRate: rate).write(to: file, options: .atomic)
            }
            bytes += Int64((try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0)
            files += 1
            var row = recordingRow(meta, names: names)
            row["file"] = "\(names.day(meta.startedAt))/\(file.lastPathComponent)"
            rows.append(row)
        }
        progress?(segments.count, segments.count)
        try writeRecordings(rows, to: dir)
        try readme(audioReadme(format), to: dir)
        return Result(directory: dir, recordings: rows.count, files: files, bytes: bytes)
    }

    // MARK: - 文字起こし

    public static func transcripts(_ segments: [SegmentMetadata], markers: [Marker], corrector: VocabularyCorrector,
                                   timeZone: TimeZone = .current, to dir: URL) throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = Names(timeZone: timeZone)
        var utterances: [[String: Any]] = []
        var csv = [["date", "start", "end", "recording_id", "offset_start_s", "offset_end_s", "speaker", "language", "text",
                    "source", "manual"]]
        var recordings: [[String: Any]] = []
        var files = 0
        let subtitles = dir.appendingPathComponent("subtitles", isDirectory: true)
        for meta in segments {
            var row = recordingRow(meta, names: names)
            guard let (raw, source) = chosen(meta) else {
                recordings.append(row)
                continue
            }
            let fixed = corrector.correct(raw)
            row["transcript_source"] = source
            row["subtitles"] = "subtitles/\(names.day(meta.startedAt))/\(names.base(meta)).srt"
            recordings.append(row)
            for (p, original) in Swift.zip(fixed.pieces, raw.pieces) {
                let start = meta.startedAt.addingTimeInterval(p.start), end = meta.startedAt.addingTimeInterval(p.end)
                var u: [String: Any] = [
                    "recording_id": meta.id, "start": names.iso(start), "end": names.iso(end),
                    "offset_start_s": round3(p.start), "offset_end_s": round3(p.end), "text": p.text, "source": source,
                ]
                u["speaker"] = p.speaker ?? NSNull()
                u["speaker_id"] = p.speakerId ?? NSNull()
                u["speaker_label"] = p.speakerLabel ?? NSNull()
                u["manual"] = p.speakerManual ?? false
                u["language"] = p.language ?? NSNull()
                if original.text != p.text { u["original_text"] = original.text }
                utterances.append(u)
                csv.append([names.day(start), names.clock(start), names.clock(end), meta.id, String(round3(p.start)),
                            String(round3(p.end)), p.speaker ?? "", p.language ?? "", p.text, source,
                            p.speakerManual == true ? "1" : "0"])
            }
            // 字幕 (音声のファイルと同じ名前。プレーヤーで音声と並べて確かめられる)
            let folder = subtitles.appendingPathComponent(names.day(meta.startedAt), isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try srt(fixed).write(to: folder.appendingPathComponent("\(names.base(meta)).srt"), atomically: true, encoding: .utf8)
            files += 1
        }
        try jsonLines(utterances).write(to: dir.appendingPathComponent("utterances.jsonl"), options: .atomic)
        try csvData(csv).write(to: dir.appendingPathComponent("utterances.csv"), options: .atomic)
        try writeRecordings(recordings, to: dir)

        // 印 (書き出す日のもの。録音の時間帯 (前後 2 秒) に入れば、その録音 ID)
        let spans = segments.map { ($0.id, $0.startedAt.addingTimeInterval(-2),
                                    ($0.endedAt ?? $0.startedAt.addingTimeInterval($0.durationSeconds)).addingTimeInterval(2)) }
        let days = Set(segments.map { names.day($0.startedAt) })
        var markerRows = [["date", "time", "kind", "label", "recording_id"]]
        for m in markers.sorted(by: { $0.at < $1.at }) where days.contains(names.day(m.at)) {
            let seg = spans.first { $0.1 <= m.at && m.at <= $0.2 }?.0
            markerRows.append([names.day(m.at), names.clock(m.at), m.kind.rawValue, m.kind.exportLabel, seg ?? ""])
        }
        try csvData(markerRows).write(to: dir.appendingPathComponent("markers.csv"), options: .atomic)

        // 日ごとの Markdown (AI に渡すものと同じ形)
        let daysDir = dir.appendingPathComponent("days", isDirectory: true)
        try fm.createDirectory(at: daysDir, withIntermediateDirectories: true)
        for day in days.sorted() {
            if let md = AINotes.timeline(day: day, timeZone: timeZone, segments: segments, markers: markers, corrector: corrector) {
                try md.write(to: daysDir.appendingPathComponent("\(day).md"), atomically: true, encoding: .utf8)
                files += 1
            }
        }
        try readme(transcriptReadme, to: dir)
        return Result(directory: dir, recordings: recordings.count, files: files + 4, bytes: folderSize(dir))
    }

    /// フォルダを zip にする (Foundation の「アップロード用に読む」を使う)。zip は dir と同じ場所に置く
    public static func zip(_ dir: URL) throws -> URL {
        let target = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + ".zip")
        try? FileManager.default.removeItem(at: target)
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: .forUploading, error: &coordinatorError) { zipped in
            do { try FileManager.default.copyItem(at: zipped, to: target) } catch { copyError = error }
        }
        if let e = coordinatorError ?? copyError { throw e }
        return target
    }

    // MARK: - 中身

    struct Names {
        let timeZone: TimeZone
        private let dayF: DateFormatter
        private let timeF: DateFormatter
        private let fileF: DateFormatter
        private let isoF: ISO8601DateFormatter

        init(timeZone: TimeZone) {
            self.timeZone = timeZone
            func f(_ format: String) -> DateFormatter {
                let d = DateFormatter()
                d.calendar = Calendar(identifier: .gregorian)
                d.locale = Locale(identifier: "en_US_POSIX")
                d.timeZone = timeZone
                d.dateFormat = format
                return d
            }
            dayF = f("yyyy-MM-dd")
            timeF = f("HH:mm:ss")
            fileF = f("yyyy-MM-dd_HHmmss")
            isoF = ISO8601DateFormatter()
            isoF.timeZone = timeZone
            isoF.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }

        func day(_ d: Date) -> String { dayF.string(from: d) }
        func clock(_ d: Date) -> String { timeF.string(from: d) }
        func iso(_ d: Date) -> String { isoF.string(from: d) }
        /// `2026-10-13_104012_<録音 ID>`
        func base(_ m: SegmentMetadata) -> String { "\(fileF.string(from: m.startedAt))_\(m.id)" }
    }

    static func chosen(_ meta: SegmentMetadata) -> (Transcript, String)? {
        if let s = meta.serverTranscript, !s.pieces.isEmpty { return (s, "server") }
        if let d = meta.transcript, !d.pieces.isEmpty { return (d, "device") }
        return nil
    }

    static func recordingRow(_ m: SegmentMetadata, names: Names) -> [String: Any] {
        let end = m.endedAt ?? m.startedAt.addingTimeInterval(m.durationSeconds)
        let speakers = Array(Set((chosen(m)?.0.pieces ?? []).compactMap(\.speaker))).sorted()
        var row: [String: Any] = ["id": m.id, "start": names.iso(m.startedAt), "end": names.iso(end),
                                  "duration_s": round3(m.durationSeconds), "speakers": speakers]
        row["has_speech"] = m.hasSpeech ?? NSNull()
        row["device"] = m.deviceName ?? NSNull()
        return row
    }

    static func writeRecordings(_ rows: [[String: Any]], to dir: URL) throws {
        try jsonLines(rows).write(to: dir.appendingPathComponent("recordings.jsonl"), options: .atomic)
        var csv = [["id", "start", "end", "duration_s", "has_speech", "speakers", "file", "subtitles"]]
        for r in rows {
            csv.append([r["id"] as? String ?? "", r["start"] as? String ?? "", r["end"] as? String ?? "",
                        (r["duration_s"] as? Double).map { String($0) } ?? "", (r["has_speech"] as? Bool).map { $0 ? "1" : "0" } ?? "",
                        (r["speakers"] as? [String] ?? []).joined(separator: " / "), r["file"] as? String ?? "",
                        r["subtitles"] as? String ?? ""])
        }
        try csvData(csv).write(to: dir.appendingPathComponent("recordings.csv"), options: .atomic)
    }

    static func jsonLines(_ rows: [[String: Any]]) throws -> Data {
        var out = Data()
        for r in rows {
            out.append(try JSONSerialization.data(withJSONObject: r, options: [.sortedKeys, .withoutEscapingSlashes]))
            out.append(0x0A)
        }
        return out
    }

    /// Excel でも文字化けしないよう、UTF-8 の BOM を付ける
    static func csvData(_ rows: [[String]]) -> Data {
        func cell(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        let text = rows.map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
    }

    static func srt(_ t: Transcript) -> String {
        func stamp(_ s: Double) -> String {
            let ms = Int((max(0, s) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return t.pieces.enumerated().map { i, p in
            let who = p.speaker.map { "\($0): " } ?? ""
            return "\(i + 1)\n\(stamp(p.start)) --> \(stamp(max(p.end, p.start + 0.3)))\n\(who)\(p.text)\n"
        }.joined(separator: "\n")
    }

    static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    static func folderSize(_ dir: URL) -> Int64 {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = e?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func readme(_ text: String, to dir: URL) throws {
        try text.write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    }

    static func audioReadme(_ format: AudioFormat) -> String {
        """
        Omimi の録音 (音声)

        - <日付>/<日付>_<時刻>_<録音 ID>.\(format.rawValue): 録音 1 件。\(format == .opus ? "Ogg Opus (16 kHz モノラル)。ffmpeg や VLC で再生・変換できます。" : "WAV (16 kHz / 16 bit / モノラル)。")
        - recordings.csv / recordings.jsonl: 録音の一覧 (ID・開始と終了の時刻・長さ・話し声の有無・話者・ファイル)。
        - 文字起こしを別に書き出すと、同じ録音 ID と同じファイル名の字幕 (.srt) が入っています。

        個人や周囲の人の会話を含みます。取り扱いに注意してください。
        """
    }

    static let transcriptReadme = """
    Omimi の文字起こし

    - utterances.csv: 発話 1 つが 1 行 (日付・時刻・録音 ID・録音の先頭からの秒・話者・言語・文・人が話者を直したか)。Excel で開けます (UTF-8)。
    - utterances.jsonl: 同じ内容の JSON Lines。時刻は ISO 8601 (タイムゾーン付き)。用語集で直す前の文は original_text。
    - recordings.csv / recordings.jsonl: 録音の一覧。音声を書き出したときと同じ録音 ID です。
    - subtitles/<日付>/<日付>_<時刻>_<録音 ID>.srt: 録音ごとの字幕。音声のファイルと同じ名前です。
    - days/<日付>.md: その日の会話を時系列に並べたもの (AI に渡すものと同じ形)。
    - markers.csv: Omi のボタンで付けた印 (highlight = 注目 / split = 区切り / memo = メモ)。

    話者の「その他」は名前を付けていない人です。source は文字起こしのもと (device = iPhone の Apple の音声認識、server = 以前に自宅サーバの Whisper で書いたもの)。
    個人や周囲の人の会話を含みます。取り扱いに注意してください。
    """
}

extension Marker.Kind {
    var exportLabel: String {
        switch self {
        case .highlight: "注目"
        case .split: "区切り"
        case .memo: "メモ"
        }
    }
}
