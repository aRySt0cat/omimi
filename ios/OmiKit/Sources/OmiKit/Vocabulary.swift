import Foundation

/// 用語集の 1 語 (`GET /api/v1/vocabulary`)。人名・専門用語など、文字起こしで間違えやすい語
public struct VocabularyEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    /// 正しい表記
    public var term: String
    /// 読み
    public var reading: String?
    /// よく間違う表記
    public var aliases: [String]
    /// 説明 (AI がまとめるときに参考にする)
    public var note: String?

    public init(id: Int, term: String, reading: String? = nil, aliases: [String] = [], note: String? = nil) {
        self.id = id
        self.term = term
        self.reading = reading
        self.aliases = aliases
        self.note = note
    }
}

/// 送る用語 (追加・変更)
public struct VocabularyInput: Encodable, Equatable, Sendable {
    public var term: String
    public var reading: String?
    public var aliases: [String]
    public var note: String?

    public init(term: String, reading: String?, aliases: [String], note: String?) {
        self.term = term
        self.reading = reading
        self.aliases = aliases
        self.note = note
    }

    /// 「、」「,」や改行で区切った「よく間違う表記」
    public static func splitAliases(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "、,，\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// 「よく間違う表記」を正しい表記に置き換える (サーバと同じ規則: 2 文字以上、長いものから)
public struct VocabularyCorrector: Sendable {
    private let pairs: [(String, String)]

    public init(_ entries: [VocabularyEntry]) {
        var pairs: [(String, String)] = []
        for e in entries {
            for alias in e.aliases {
                let a = alias.trimmingCharacters(in: .whitespaces)
                if a.count >= 2 && a != e.term { pairs.append((a, e.term)) }
            }
        }
        self.pairs = pairs.sorted { $0.0.count > $1.0.count }
    }

    public var isEmpty: Bool { pairs.isEmpty }

    public func correct(_ text: String) -> String {
        guard !pairs.isEmpty, !text.isEmpty else { return text }
        var out = ""
        var i = text.startIndex
        // 左から見て、その位置で一致するいちばん長い表記を置き換える (置き換えた結果はもう一度は見ない)
        outer: while i < text.endIndex {
            for (alias, term) in pairs where text[i...].hasPrefix(alias) {
                out += term
                i = text.index(i, offsetBy: alias.count)
                continue outer
            }
            out.append(text[i])
            i = text.index(after: i)
        }
        return out
    }

    public func correct(_ transcript: Transcript) -> Transcript {
        guard !pairs.isEmpty else { return transcript }
        var t = transcript
        for i in t.pieces.indices { t.pieces[i].text = correct(t.pieces[i].text) }
        return t
    }
}
