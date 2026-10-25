import Foundation

/// 「AI で整理」の添付 (その日の会話・用語集) と、出力の読み取り。指示は `AIPrompts`。
public enum AINotes {
    public static let noteMark = "<<<NOTE>>>", todoMark = "<<<TODO>>>", endMark = "<<<END>>>"
    /// 添付する会話の上限 (文字)。超えたら後ろを省く
    public static let maxTimelineChars = 400_000
    static let weekdays = Array("月火水木金土日")

    /// `YYYY-MM-DD` → `10月13日 (火)`
    public static func dayTitle(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let wd = weekday(day) else { return day }
        return "\(parts[1])月\(parts[2])日 (\(wd))"
    }

    /// `YYYY-MM-DD` の曜日 (月〜日)
    static func weekday(_ day: String) -> Character? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        (comps.year, comps.month, comps.day) = (parts[0], parts[1], parts[2])
        let cal = Calendar(identifier: .gregorian)
        guard let date = cal.date(from: comps) else { return nil }
        return weekdays[(cal.component(.weekday, from: date) + 5) % 7]  // 月曜を 0 にする
    }

    /// 添付 (`<file path="...">`)
    public static func materials(_ files: [(name: String, text: String)]) -> String {
        files.map { name, text in
            var t = text
            if t.count > maxTimelineChars { t = String(t.prefix(maxTimelineChars)) + "\n\n(長いので、ここから後ろは省きました)\n" }
            while t.hasSuffix("\n") || t.hasSuffix(" ") { t.removeLast() }
            return "<file path=\"\(name)\">\n\(t)\n</file>"
        }.joined(separator: "\n\n")
    }

    /// AI の出力から (その日のまとめ, todo.md) を取り出す
    public static func parse(_ output: String) -> (note: String?, todo: String?) {
        guard let start = output.range(of: noteMark) else { return (nil, nil) }
        let body = output[start.upperBound...]
        let note: Substring, rest: Substring?
        if let t = body.range(of: todoMark) {
            note = body[..<t.lowerBound]
            rest = body[t.upperBound...]
        } else {
            note = body
            rest = nil
        }
        func clean(_ s: Substring?) -> String? {
            guard var s = s.map({ String($0) }) else { return nil }
            if let end = s.range(of: endMark) { s = String(s[..<end.lowerBound]) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // コードブロックで囲まれて返ってきたときは外す
            if s.hasPrefix("```") && s.hasSuffix("```") {
                if let nl = s.firstIndex(of: "\n") {
                    s = String(s[s.index(after: nl)...])
                    if let close = s.range(of: "```", options: .backwards) { s = String(s[..<close.lowerBound]) }
                    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    s = ""
                }
            }
            return s.isEmpty ? nil : s + "\n"
        }
        return (clean(note), clean(rest))
    }

    /// 用語集 (AI 向け。自宅サーバの vocabulary.md と同じ形)
    public static func vocabularyMarkdown(_ entries: [VocabularyEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        func cell(_ s: String?) -> String { (s ?? "").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        var lines = ["# 用語集", "",
                     "人名・専門用語など、文字起こしで間違えやすい語です。まとめでは「正しい表記」を使い、",
                     "文字起こしの中の「よく間違う表記」や、読みが近い別の語は、文脈に合えば正しい表記に直して読んでください。", "",
                     "| 正しい表記 | 読み | よく間違う表記 | 説明 |", "|---|---|---|---|"]
        for e in entries {
            lines.append("| \(cell(e.term)) | \(cell(e.reading)) | \(cell(e.aliases.joined(separator: "、"))) | \(cell(e.note)) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// その日 (range があればその時間帯) の会話を、iPhone にある録音から Markdown にする。記録がなければ nil
    public static func timeline(day: String, timeZone: TimeZone, segments: [SegmentMetadata], markers: [Marker],
                                corrector: VocabularyCorrector, range: TimeRange? = nil, preferServer: Bool = true) -> String? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = cal
        dayFormatter.timeZone = timeZone
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.calendar = cal
        timeFormatter.timeZone = timeZone
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm:ss"
        func hms(_ d: Date) -> String { timeFormatter.string(from: d) }

        let window = range.flatMap { $0.interval(day: day, timeZone: timeZone) }
        func end(_ m: SegmentMetadata) -> Date { m.endedAt ?? m.startedAt.addingTimeInterval(m.durationSeconds) }
        let todays = segments.filter { m in
            guard m.state == .closed else { return false }
            if let window { return m.startedAt < window.end && end(m) > window.start }
            return dayFormatter.string(from: m.startedAt) == day
        }.sorted { $0.startedAt < $1.startedAt }
        guard !todays.isEmpty else { return nil }
        func inWindow(_ t: Date) -> Bool { window.map { $0.start <= t && t < $0.end } ?? true }
        let dayMarkers = markers.filter { window != nil ? inWindow($0.at) : dayFormatter.string(from: $0.at) == day }

        enum Item { case segment(SegmentMetadata, Transcript?, String), utterance(Date, TranscriptPiece), marker(Date, Marker.Kind) }
        var items: [(Date, Int, Item)] = []
        var speakerSeconds: [String: Double] = [:]
        var silent = 0
        for meta in todays {
            // 自宅サーバと同じく、優先する方に文があればそれ、なければもう一方
            let order: [(Transcript?, String)] = preferServer
                ? [(meta.serverTranscript, "server"), (meta.transcript, "device")]
                : [(meta.transcript, "device"), (meta.serverTranscript, "server")]
            let picked = order.first { $0.0?.pieces.isEmpty == false }
            var chosen = picked?.0.map { corrector.correct($0) }
            // 時間帯の外の発話は省く
            if window != nil { chosen?.pieces.removeAll { !inWindow(meta.startedAt.addingTimeInterval($0.start)) } }
            if meta.hasSpeech == false { silent += 1 }
            items.append((meta.startedAt, 0, .segment(meta, chosen, picked?.1 ?? "None")))
            for p in chosen?.pieces ?? [] {
                if let s = p.speaker { speakerSeconds[s, default: 0] += max(0, p.end - p.start) }
                items.append((meta.startedAt.addingTimeInterval(p.start), 2, .utterance(meta.startedAt.addingTimeInterval(p.start), p)))
            }
        }
        for m in dayMarkers {
            items.append((m.at, 1, .marker(m.at, m.kind)))
        }
        items.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }

        let labels: [Marker.Kind: (String, String, String)] = [
            .highlight: ("⭐", "注目", "ここは大事"), .split: ("✂️", "区切り", "話題の切れ目"), .memo: ("📝", "メモ", "ここから本人のメモ・指示"),
        ]
        var lines = ["# \(day) (\(weekday(day).map(String.init) ?? ""))\(range.map { " " + $0.label } ?? "") のライフログ", ""]
        if let range { lines.append("- 時間帯: \(range.label) (この間の発話だけ)") }
        lines.append("- 録音: 話し声あり \(todays.count - silent) 件 / 話し声なし \(silent) 件 (省略)")
        if !speakerSeconds.isEmpty {
            lines.append("- 話者: " + speakerSeconds.sorted { $0.value > $1.value }
                .map { "\($0.key) (\(duration($0.value)))" }.joined(separator: ", "))
        }
        let kinds = Dictionary(grouping: dayMarkers, by: \.kind)
        if !kinds.isEmpty {
            lines.append("- 印: " + [Marker.Kind.highlight, .split, .memo].compactMap { k in
                kinds[k].map { "\(labels[k]!.0) \(labels[k]!.1) \($0.count)" }
            }.joined(separator: " / "))
        }
        let offset = timeZone.secondsFromGMT(for: todays[0].startedAt)
        lines.append(String(format: "- タイムゾーン: %@%02d%02d", offset >= 0 ? "+" : "-", abs(offset) / 3600, abs(offset) % 3600 / 60))
        lines.append("")

        var skip: Set<String> = []
        var current: String?
        for (t, _, item) in items {
            switch item {
            case let .segment(meta, chosen, source):
                if meta.hasSpeech == false {
                    skip.insert(meta.id)
                    continue
                }
                current = meta.id
                let end = meta.endedAt ?? meta.startedAt.addingTimeInterval(meta.durationSeconds)
                let speakers = Array(Set((chosen?.pieces ?? []).compactMap(\.speaker))).sorted()
                lines += ["", "## \(hms(t)) – \(hms(end)) · \(duration(meta.durationSeconds)) · \(speakers.isEmpty ? "話者不明" : speakers.joined(separator: ", "))",
                          "<!-- segment: \(meta.id) source: \(source) -->", ""]
                if meta.hasSpeech == nil {
                    lines.append("_(処理中)_")
                } else if chosen == nil {
                    lines.append("_(短い発話のみ。文字起こしなし)_")
                }
            case let .utterance(at, p):
                guard let id = current, !skip.contains(id) else { continue }
                let lang = p.language.map { " (\($0))" } ?? ""
                lines.append("- \(hms(at)) **\(p.speaker ?? "不明")**\(lang): \(p.text)")
            case let .marker(at, kind):
                let (symbol, label, note) = labels[kind]!
                if kind == .split {
                    lines += ["", "--- \(symbol) **\(label)** \(hms(at)) (\(note)) ---", ""]
                } else {
                    lines.append("- \(hms(at)) \(symbol) **\(label)** (\(note))")
                }
            }
        }
        var text = lines.joined(separator: "\n")
        while text.hasSuffix("\n") || text.hasSuffix(" ") { text.removeLast() }
        return text + "\n"
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return "\(s / 3600)時間\(s % 3600 / 60)分" }
        if s >= 60 { return "\(s / 60)分\(s % 60)秒" }
        return "\(s)秒"
    }
}

/// まとめの題名と要約 (自宅サーバの notes.summarize と同じ)
public enum NoteSummarizer {
    public static func summarize(_ text: String) -> (title: String?, summary: String?) {
        var title: String?
        var quote: [String] = []
        var paragraph: [String] = []
        var inCode = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode { continue }
            if title == nil && line.hasPrefix("# ") {
                title = plain(String(line.dropFirst(2)))
                continue
            }
            if line.hasPrefix(">") {
                quote.append(line.drop(while: { $0 == ">" || $0 == " " }).trimmingCharacters(in: .whitespaces))
                continue
            }
            if !quote.isEmpty { break }
            if line.isEmpty {
                if !paragraph.isEmpty { break }
                continue
            }
            if line.hasPrefix("#") || line.hasPrefix("-") || line.hasPrefix("*") || line.hasPrefix("|") || line.hasPrefix("<!--")
                || line.range(of: #"^\d+\."#, options: .regularExpression) != nil {
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(line)
        }
        var summary: String? = plain((quote.isEmpty ? paragraph : quote).joined(separator: " "))
        if summary?.isEmpty == true { summary = nil }
        if let s = summary, s.count > 140 { summary = String(s.prefix(139)) + "…" }
        return (title, summary)
    }

    static func plain(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[*_`~]+"#, with: "", options: .regularExpression)
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
