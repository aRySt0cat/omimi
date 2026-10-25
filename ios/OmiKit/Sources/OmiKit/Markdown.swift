import Foundation

/// AI のまとめを表示するための、Markdown の段落レベルの構造。
/// 行の中の書式 (太字・リンクなど) は表示側で `AttributedString(markdown:)` に任せる。HTML は解釈しない。
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case quote([MarkdownBlock])
    case list(ordered: Bool, items: [MarkdownListItem])
    case code(String)
    case table(header: [String], rows: [[String]])
    case rule
}

public struct MarkdownListItem: Equatable, Sendable {
    public var text: String
    /// チェックボックス: nil ならふつうの項目、true なら済み
    public var checked: Bool?
    public var children: [MarkdownListItem]

    public init(text: String, checked: Bool? = nil, children: [MarkdownListItem] = []) {
        self.text = text
        self.checked = checked
        self.children = children
    }
}

public enum Markdown {
    public static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            if trimmed.hasPrefix("<!--") {
                while i < lines.count, !lines[i].contains("-->") { i += 1 }
                i += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                var buf: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    buf.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(.code(buf.joined(separator: "\n")))
                continue
            }
            if let heading = heading(trimmed) {
                blocks.append(heading)
                i += 1
                continue
            }
            if isRule(trimmed) {
                blocks.append(.rule)
                i += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                var buf: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var l = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    if l.first == " " { l = l.dropFirst() }
                    buf.append(String(l))
                    i += 1
                }
                blocks.append(.quote(parse(buf.joined(separator: "\n"))))
                continue
            }
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if listMarker(line) != nil {
                var buf: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if listMarker(l) != nil || (!buf.isEmpty && l.hasPrefix("  ") && !l.trimmingCharacters(in: .whitespaces).isEmpty) {
                        buf.append(l)
                        i += 1
                    } else if l.trimmingCharacters(in: .whitespaces).isEmpty, i + 1 < lines.count,
                              listMarker(lines[i + 1]) != nil, lines[i + 1].hasPrefix(" ") {
                        i += 1 // 入れ子の前の空行
                    } else {
                        break
                    }
                }
                let (ordered, items) = listItems(buf)
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }
            var buf: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || (!buf.isEmpty && startsBlock(lines[i])) { break }
                buf.append(t)
                i += 1
            }
            blocks.append(.paragraph(joinLines(buf)))
        }
        return blocks
    }

    /// 改行で続く行をつなぐ。日本語どうしは空白を入れない。
    public static func joinLines(_ lines: [String]) -> String {
        lines.reduce("") { acc, line in
            guard let last = acc.unicodeScalars.last else { return line }
            return acc + (isCJK(last) ? "" : " ") + line
        }
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        (0x3000...0x30FF).contains(s.value) || (0x3400...0x9FFF).contains(s.value) || (0xFF00...0xFFEF).contains(s.value)
    }

    static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        var text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        let chars = line.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func startsBlock(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return heading(t) != nil || t.hasPrefix(">") || t.hasPrefix("```") || t.hasPrefix("~~~") || t.hasPrefix("|")
            || t.hasPrefix("<!--") || isRule(t) || listMarker(line) != nil
    }

    /// 箇条書きの行なら (字下げ, 番号付きか, 本文)
    static func listMarker(_ line: String) -> (indent: Int, ordered: Bool, text: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return (indent, false, rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 3, rest.dropFirst(digits.count).hasPrefix(". ") {
            return (indent, true, rest.dropFirst(digits.count + 2).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func listItems(_ lines: [String]) -> (ordered: Bool, items: [MarkdownListItem]) {
        var flat: [(indent: Int, ordered: Bool, text: String)] = []
        for line in lines {
            if let m = listMarker(line) {
                flat.append(m)
            } else if !flat.isEmpty {
                flat[flat.count - 1].text = joinLines([flat[flat.count - 1].text, line.trimmingCharacters(in: .whitespaces)])
            }
        }
        var index = 0
        func build(_ indent: Int) -> [MarkdownListItem] {
            var items: [MarkdownListItem] = []
            while index < flat.count, flat[index].indent >= indent {
                if flat[index].indent > indent, !items.isEmpty {
                    items[items.count - 1].children = build(flat[index].indent)
                    continue
                }
                items.append(item(flat[index].text))
                index += 1
            }
            return items
        }
        var items: [MarkdownListItem] = []
        while index < flat.count { items += build(flat[index].indent) }
        return (flat.first?.ordered ?? false, items)
    }

    static func item(_ text: String) -> MarkdownListItem {
        for (prefix, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(prefix) {
            return MarkdownListItem(text: String(text.dropFirst(prefix.count)), checked: checked)
        }
        return MarkdownListItem(text: text)
    }
}
