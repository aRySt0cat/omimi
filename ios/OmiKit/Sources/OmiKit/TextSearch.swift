import Foundation

/// 会話とまとめの言葉の検索。ひらがなとカタカナ、全角と半角、大文字と小文字の違いは同じとみなす。
/// 空白で区切った言葉は、すべてを含むものを探す (かつ)。
/// かなだけの言葉は、読みでも探す (「みつもり」で「見積もり」、用語集の読み「しもがうち」で「下河内」)。
public enum TextSearch {
    /// 見つかった発話
    public struct Hit: Identifiable, Hashable, Sendable {
        public var segmentId: String
        public var start: Double
        public var end: Double
        public var at: Date
        public var speaker: String?
        public var speakerId: Int?
        /// 用語集で直した文 (画面と同じ)
        public var text: String
        /// 文字ではなく読みで見つかった
        public var byReading: Bool
        /// "ja" / "en" (分からなければ nil)
        public var language: String?
        public var id: String { "\(segmentId)@\(start)" }
    }

    /// 絞り込み (言葉がなくても、条件だけで探せる)
    public struct Filter: Hashable, Sendable {
        /// "ja" / "en" など。言語の分からない発話は defaultLanguage とみなす
        public var language: String?
        public var defaultLanguage = "ja"
        /// 日付の範囲 (発話の時刻がこの中)
        public var interval: DateInterval?
        /// 一日の中の時間帯 (0:00 からの分)。終わりが始まりより前なら日をまたぐ (22:00〜2:00 など)
        public var timeStart: Int?
        public var timeEnd: Int?
        public var speaker: String?
        public var timeZone = TimeZone.current

        public init(language: String? = nil, interval: DateInterval? = nil, timeStart: Int? = nil, timeEnd: Int? = nil,
                    speaker: String? = nil) {
            self.language = language
            self.interval = interval
            self.timeStart = timeStart
            self.timeEnd = timeEnd
            self.speaker = speaker
        }

        public var isActive: Bool { language != nil || interval != nil || hasTime || speaker != nil }
        public var hasTime: Bool { timeStart != nil && timeEnd != nil && timeStart != timeEnd }
        /// まとめにも当てはめられる条件だけか (まとめは日付でだけ絞れる。言語・時間帯・話者では絞れない)
        public var fitsNotes: Bool { language == nil && !hasTime && speaker == nil }

        func accepts(_ p: TranscriptPiece, at: Date, calendar: Calendar) -> Bool {
            if let speaker, p.speaker != speaker { return false }
            if let language, (p.language ?? defaultLanguage) != language { return false }
            if let interval, !(interval.start <= at && at < interval.end) { return false }
            if hasTime, let a = timeStart, let b = timeEnd {
                let c = calendar.dateComponents([.hour, .minute], from: at)
                let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                if a < b ? !(a <= m && m < b) : !(m >= a || m < b) { return false }
            }
            return true
        }
    }

    /// 見つかったまとめ
    public struct NoteHit: Identifiable, Hashable, Sendable {
        public var name: String
        public var title: String
        public var date: String?
        /// 見つかった行
        public var snippet: String
        public var count: Int
        public var id: String { name }
    }

    /// 探す言葉。言葉ごとに、同じとみなす書き方 (用語集の表記) と、読み (かなだけの言葉)
    public struct Query: Sendable, Equatable {
        public struct Term: Sendable, Equatable {
            /// 文字で探す書き方 (カタカナはひらがなにしてある)
            public var forms: [String]
            /// 読み (ローマ字)。かなだけの言葉のとき
            public var reading: String?
        }

        public var terms: [Term]
        public var isEmpty: Bool { terms.isEmpty }
        /// 文字で探す書き方 (強調に使う)
        public var allForms: [String] { terms.flatMap(\.forms) }
    }

    public static func query(_ text: String, vocabulary: [VocabularyEntry] = []) -> Query {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        return Query(terms: words.map { word in
            let f = fold(word)
            var forms = [f]
            // 用語集: 読み・表記・よく間違う表記のどれかと同じなら、ほかの書き方でも探す
            for e in vocabulary {
                let names = [e.term] + e.aliases + (e.reading.map { [$0] } ?? [])
                guard names.contains(where: { fold($0).compare(f, options: options) == .orderedSame }) else { continue }
                for n in [e.term] + e.aliases where !forms.contains(fold(n)) { forms.append(fold(n)) }
            }
            return Query.Term(forms: forms, reading: isKanaOrLatin(f) && f.count >= 2 ? reading(f) : nil)
        })
    }

    /// 探す言葉 (空白・全角空白で区切り、カタカナはひらがなにしたもの)
    public static func terms(_ query: String) -> [String] {
        self.query(query).terms.map { $0.forms[0] }
    }

    /// カタカナをひらがなに (1 文字ずつ。UTF-16 の長さは変わらない)
    static func fold(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if (0x30A1...0x30F6).contains(u.value), let h = Unicode.Scalar(u.value - 0x60) {
                scalars.append(h)
            } else {
                scalars.append(u)
            }
        }
        return String(scalars)
    }

    static let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive]

    static func hasKanji(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    static func isKanaOrLatin(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { u in
            (0x3041...0x309F).contains(u.value) || u.value == 0x30FC || u.properties.isAlphabetic && u.isASCII
        }
    }

    /// 読み (ローマ字、空白なし)。漢字は日本語の読みにする
    static func reading(_ s: String) -> String {
        if let cached = readingCache.object(forKey: s as NSString) { return cached as String }
        let cf = s as CFString
        let tokenizer = CFStringTokenizerCreate(nil, cf, CFRange(location: 0, length: CFStringGetLength(cf)),
                                                kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale)
        var out = ""
        var type = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while !type.isEmpty {
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                out += latin
            } else {
                let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                out += (s as NSString).substring(with: NSRange(location: r.location, length: r.length))
            }
            type = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        // 長音・記号の書き方の違いをならす (ā → a など)
        let result = out.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
        readingCache.setObject(result as NSString, forKey: s as NSString)
        return result
    }

    nonisolated(unsafe) static let readingCache: NSCache<NSString, NSString> = {
        let c = NSCache<NSString, NSString>()
        c.countLimit = 50_000
        return c
    }()

    /// 文の中の、言葉の場所 (重なりはまとめて、前から順に)
    public static func ranges(of forms: [String], in text: String) -> [Range<String.Index>] {
        guard !forms.isEmpty, !text.isEmpty else { return [] }
        let folded = fold(text)
        var found: [Range<Int>] = []
        for form in forms where !form.isEmpty {
            var from = folded.startIndex
            while from < folded.endIndex, let r = folded.range(of: form, options: options, range: from..<folded.endIndex) {
                found.append(r.lowerBound.utf16Offset(in: folded)..<r.upperBound.utf16Offset(in: folded))
                from = r.upperBound > r.lowerBound ? r.upperBound : folded.index(after: r.lowerBound)
            }
        }
        var merged: [Range<Int>] = []
        for r in found.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged.map { String.Index(utf16Offset: $0.lowerBound, in: text)..<String.Index(utf16Offset: $0.upperBound, in: text) }
    }

    /// すべての言葉を含むか。読みだけで見つかったときは byReading
    public static func match(_ query: Query, _ text: String) -> (found: Bool, byReading: Bool) {
        guard !query.isEmpty else { return (false, false) }
        let folded = fold(text)
        var byReading = false
        for term in query.terms {
            if term.forms.contains(where: { folded.range(of: $0, options: options) != nil }) { continue }
            // 読みで探すのは漢字を含む文だけ (かなだけの文は、文字で見つからなければ読みでも見つからない)
            guard let r = term.reading, !r.isEmpty, hasKanji(text), reading(text).contains(r) else { return (false, false) }
            byReading = true
        }
        return (true, byReading)
    }

    public static func matches(_ terms: [String], _ text: String) -> Bool {
        match(Query(terms: terms.map { Query.Term(forms: [fold($0)], reading: nil) }), text).found
    }

    /// 会話を探す (新しい順)。言葉がなければ、絞り込みの条件に合う発話をすべて
    public static func search(_ query: Query, segments: [SegmentMetadata], corrector: VocabularyCorrector,
                              filter: Filter = Filter(), limit: Int = 300) -> (hits: [Hit], total: Int) {
        guard !query.isEmpty || filter.isActive else { return ([], 0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = filter.timeZone
        var hits: [Hit] = []
        var total = 0
        for meta in segments.sorted(by: { $0.startedAt > $1.startedAt }) {
            guard let t = displayTranscript(meta) else { continue }
            // 日付の範囲の外の録音は読まない
            if let interval = filter.interval {
                let end = meta.endedAt ?? meta.startedAt.addingTimeInterval(meta.durationSeconds)
                if meta.startedAt >= interval.end || end < interval.start { continue }
            }
            for p in t.pieces.reversed() {
                guard filter.accepts(p, at: meta.startedAt.addingTimeInterval(p.start), calendar: calendar) else { continue }
                let text = corrector.isEmpty ? p.text : corrector.correct(p.text)
                let m = query.isEmpty ? (found: true, byReading: false) : match(query, text)
                guard m.found else { continue }
                total += 1
                if hits.count < limit {
                    hits.append(Hit(segmentId: meta.id, start: p.start, end: p.end, at: meta.startedAt.addingTimeInterval(p.start),
                                    speaker: p.speaker, speakerId: p.speakerId, text: text, byReading: m.byReading,
                                    language: p.language))
                }
            }
        }
        return (hits, total)
    }

    public static func search(_ text: String, segments: [SegmentMetadata], corrector: VocabularyCorrector,
                              filter: Filter = Filter(), limit: Int = 300) -> (hits: [Hit], total: Int) {
        search(query(text), segments: segments, corrector: corrector, filter: filter, limit: limit)
    }

    /// 画面に出している文字起こし (以前に自宅サーバの Whisper で書いたものがあればそれ)
    public static func displayTranscript(_ meta: SegmentMetadata) -> Transcript? {
        if let s = meta.serverTranscript, !s.pieces.isEmpty { return s }
        return meta.transcript
    }

    /// まとめを探す (文字で。まとめは長いので読みでは探さない)。日付の範囲があれば、その日のまとめだけ
    /// (言葉がなければ、その範囲のまとめをすべて)
    public static func searchNotes(_ query: Query, notes: [(summary: NoteSummary, text: String)],
                                   interval: DateInterval? = nil, timeZone: TimeZone = .current) -> [NoteHit] {
        guard !query.isEmpty || interval != nil else { return [] }
        let literal = Query(terms: query.terms.map { Query.Term(forms: $0.forms, reading: nil) })
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return notes.compactMap { note, text in
            if let interval {
                // 日付のあるまとめはその日、ほかのノートは書いた日で
                let day = note.date ?? f.string(from: note.updatedAt)
                guard let date = f.date(from: day), interval.start <= date.addingTimeInterval(86_399), date < interval.end else { return nil }
            }
            guard query.isEmpty || match(literal, text).found else { return nil }
            let lines = text.split(separator: "\n").map { NoteSummarizer.plain(String($0)).trimmingCharacters(in: CharacterSet(charactersIn: "#>- ")) }
            let hitLines = query.isEmpty ? [] : lines.filter { !ranges(of: query.allForms, in: $0).isEmpty }
            // 言葉がなければ、見出しの次の行
            let first = hitLines.first ?? lines.dropFirst().first { !$0.isEmpty } ?? note.title
            return NoteHit(name: note.name, title: note.isDay ? note.date.map(AINotes.dayTitle) ?? note.title : note.title,
                           date: note.date, snippet: String(first.prefix(160)), count: hitLines.count)
        }
    }
}
