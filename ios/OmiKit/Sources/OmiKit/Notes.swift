import CryptoKit
import Foundation

/// AI が書いたまとめ・ノートの 1 件
public struct NoteSummary: Codable, Equatable, Identifiable, Sendable {
    /// `2026-10-10.md` (その日のまとめ)、`todo.md`、`2026-10-10 10:00–11:30 会議の議事録.md` など
    public var name: String
    /// "day" (その日のまとめ) / "note" (そのほかのノート)
    public var kind: String
    /// その日のまとめなら `YYYY-MM-DD`
    public var date: String?
    public var title: String
    public var summary: String?
    public var updatedAt: Date
    public var bytes: Int
    public var sha256: String

    public var id: String { name }
    public var isDay: Bool { kind == "day" }

    public init(name: String, kind: String, date: String?, title: String, summary: String?, updatedAt: Date,
                bytes: Int, sha256: String) {
        self.name = name
        self.kind = kind
        self.date = date
        self.title = title
        self.summary = summary
        self.updatedAt = updatedAt
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// AI が書いたまとめを iPhone に保存する。
///
/// `index.json` に一覧、本文は名前のハッシュをファイル名にして置く (名前に `/` や日本語が入っても安全なように)。
public final class NotesStore: @unchecked Sendable {
    public let directory: URL
    private let fileAttributes: [FileAttributeKey: Any]
    private let lock = NSLock()
    private var index: [NoteSummary] = []

    public init(directory: URL, fileAttributes: [FileAttributeKey: Any] = [:], excludeFromBackup: Bool = false) throws {
        self.directory = directory
        self.fileAttributes = fileAttributes
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: fileAttributes)
        if excludeFromBackup {
            var dir = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder.omi.decode([NoteSummary].self, from: data) {
            index = Self.sorted(saved)
        }
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    func fileURL(for name: String) -> URL {
        let digest = SHA256.hash(data: Data(name.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).md")
    }

    /// 日のまとめ (新しい順) → そのほかのノート (新しい順)
    public func all() -> [NoteSummary] {
        lock.withLock { index }
    }

    public func day(_ date: String) -> NoteSummary? {
        all().first { $0.isDay && $0.date == date }
    }

    public func text(of name: String) -> String? {
        guard all().contains(where: { $0.name == name }) else { return nil }
        return try? String(contentsOf: fileURL(for: name), encoding: .utf8)
    }

    /// まとめを置く (同じ名前なら書き換える)
    @discardableResult
    public func put(name: String, text: String, now: Date = Date()) throws -> NoteSummary {
        let data = Data(text.utf8)
        try write(data, to: fileURL(for: name))
        let (title, summary) = NoteSummarizer.summarize(text)
        let date = name.range(of: #"^\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression) != nil ? String(name.prefix(10)) : nil
        let note = NoteSummary(name: name, kind: date != nil ? "day" : "note", date: date,
                               title: title ?? date ?? String(name.dropLast(3)), summary: summary, updatedAt: now,
                               bytes: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        try lock.withLock {
            index = Self.sorted(index.filter { $0.name != name } + [note])
            try write(JSONEncoder.omi.encode(index), to: indexURL)
        }
        return note
    }

    public func remove(_ name: String) {
        lock.withLock {
            index.removeAll { $0.name == name }
            try? write(JSONEncoder.omi.encode(index), to: indexURL)
        }
        try? FileManager.default.removeItem(at: fileURL(for: name))
    }

    static func sorted(_ notes: [NoteSummary]) -> [NoteSummary] {
        notes.filter(\.isDay).sorted { ($0.date ?? "") > ($1.date ?? "") }
            + notes.filter { !$0.isDay }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        if !fileAttributes.isEmpty {
            try? FileManager.default.setAttributes(fileAttributes, ofItemAtPath: url.path)
        }
    }
}
