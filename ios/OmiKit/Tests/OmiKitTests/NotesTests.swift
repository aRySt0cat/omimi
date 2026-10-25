import Foundation
import Testing
@testable import OmiKit

@Suite struct MarkdownTests {
    @Test func parsesTheNightlyNoteFormat() {
        let source = """
        # 10月10日 (土)

        > 録音のテストを
        > した日。

        ## 話したこと

        - **12:42 録音の確認** — 声が録れているか
          確かめた。[12:42](omimi://segment/abc)
        - 二つ目

        ## やること

        - [ ] 見積もりを送る
        - [x] ビルドを通す
          - 注目は短く 1 回
          - 区切りは長めに 1 回
        1. 番号

        <!-- segment: x -->
        | 時刻 | 内容 |
        |---|---|
        | 13:13 | 誤認識 |

        ---

        ```
        ./nightly-mac.sh
        ```
        本文の
        続き。
        """
        let blocks = Markdown.parse(source)
        #expect(blocks[0] == .heading(level: 1, text: "10月10日 (土)"))
        #expect(blocks[1] == .quote([.paragraph("録音のテストをした日。")]))
        #expect(blocks[2] == .heading(level: 2, text: "話したこと"))
        #expect(blocks[3] == .list(ordered: false, items: [
            MarkdownListItem(text: "**12:42 録音の確認** — 声が録れているか確かめた。[12:42](omimi://segment/abc)"),
            MarkdownListItem(text: "二つ目"),
        ]))
        #expect(blocks[5] == .list(ordered: false, items: [
            MarkdownListItem(text: "見積もりを送る", checked: false),
            MarkdownListItem(text: "ビルドを通す", checked: true, children: [
                MarkdownListItem(text: "注目は短く 1 回"), MarkdownListItem(text: "区切りは長めに 1 回"),
            ]),
            MarkdownListItem(text: "番号"),
        ]))
        #expect(blocks[6] == .table(header: ["時刻", "内容"], rows: [["13:13", "誤認識"]]))
        #expect(blocks[7] == .rule)
        #expect(blocks[8] == .code("./nightly-mac.sh"))
        #expect(blocks[9] == .paragraph("本文の続き。"))
        #expect(blocks.count == 10)
    }

    @Test func joinsLatinLinesWithSpaces() {
        #expect(Markdown.parse("hello\nworld") == [.paragraph("hello world")])
        #expect(Markdown.parse("見出しではない#\n- a\n\n  - b") == [
            .paragraph("見出しではない#"), .list(ordered: false, items: [MarkdownListItem(text: "a", children: [MarkdownListItem(text: "b")])]),
        ])
        #expect(Markdown.parse("<b>html</b>") == [.paragraph("<b>html</b>")])
    }
}

@Suite struct NotesStoreTests {
    @Test func putListAndRemove() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try NotesStore(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try store.put(name: "2026-10-10.md", text: "# 10月10日 (土)\n\n> テストの日。\n", now: t0)
        try store.put(name: "2026-10-12.md", text: "# 12日\n", now: t0)
        try store.put(name: "2026-10-12 10:00〜11:00 会議の議事録.md", text: "# 定例\n\n本文です\n", now: t0)
        let todo = try store.put(name: "todo.md", text: "# やること\n", now: t0.addingTimeInterval(60))
        // 日のまとめは新しい順、そのほかのノートは新しい順
        #expect(store.all().map(\.name) == ["2026-10-12.md", "2026-10-10.md", "todo.md", "2026-10-12 10:00〜11:00 会議の議事録.md"])
        #expect(store.day("2026-10-10")?.summary == "テストの日。" && store.day("2026-10-10")?.isDay == true)
        #expect(!todo.isDay && todo.title == "やること")
        let meeting = try #require(store.all().first { $0.name.contains("会議") })
        #expect(meeting.title == "定例" && meeting.summary == "本文です" && meeting.date == nil)
        // 書き直すと置き換わり、開き直しても残る
        try store.put(name: "2026-10-10.md", text: "# 10日\n\n> 書き直した。\n", now: t0)
        let reopened = try NotesStore(directory: dir)
        #expect(reopened.text(of: "2026-10-10.md") == "# 10日\n\n> 書き直した。\n" && reopened.all().count == 4)
        reopened.remove("todo.md")
        #expect(try NotesStore(directory: dir).text(of: "todo.md") == nil)
    }
}
