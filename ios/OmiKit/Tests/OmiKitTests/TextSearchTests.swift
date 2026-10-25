import Foundation
import Testing
@testable import OmiKit

@Suite struct TextSearchTests {
    @Test func foldsKanaWidthAndCase() {
        let t = TextSearch.terms("おみ　ＡＢＣ  meeting")
        #expect(t == ["おみ", "ＡＢＣ", "meeting"])
        #expect(TextSearch.matches(t, "オミの abc の Meeting です"))
        #expect(!TextSearch.matches(t, "オミの abc です"))  // すべて含むものだけ
        let text = "オミとおみ、OMI"
        let r = TextSearch.ranges(of: TextSearch.terms("おみ omi"), in: text)
        #expect(r.map { String(text[$0]) } == ["オミ", "おみ", "OMI"])
        #expect(TextSearch.ranges(of: ["あ"], in: "") == [] && TextSearch.terms("   ") == [])
        // 重なる言葉はまとめる
        let s = "下河内さん"
        #expect(TextSearch.ranges(of: ["下河", "河内"], in: s).map { String(s[$0]) } == ["下河内"])
    }

    @Test func searchesConversationsAndNotes() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func seg(_ id: String, _ offset: Double, _ pieces: [TranscriptPiece]) -> SegmentMetadata {
            var m = SegmentMetadata(id: id, codec: .opusFS320, sampleRate: 16_000, startedAt: t0.addingTimeInterval(offset))
            m.state = .closed
            m.transcript = Transcript(engine: "apple", locale: "ja-JP", pieces: pieces)
            return m
        }
        let a = seg("a", 0, [TranscriptPiece(start: 1, end: 2, text: "下川内さんと見積もりの話", speaker: "自分"),
                             TranscriptPiece(start: 3, end: 4, text: "見積もりは金曜", speaker: "田中")])
        let b = seg("b", 3600, [TranscriptPiece(start: 0, end: 1, text: "ミツモリが届いた", speaker: "田中")])
        let vocab = [VocabularyEntry(id: 1, term: "下河内", reading: "しもがうち", aliases: ["下川内"])]
        let corrector = VocabularyCorrector(vocab)
        // 文字で
        let r = TextSearch.search("見積もり", segments: [a, b], corrector: corrector)
        #expect(r.total == 2 && r.hits.map(\.segmentId) == ["a", "a"] && r.hits.allSatisfy { !$0.byReading })
        // かなは読みでも (カタカナのものは文字で、漢字のものは読みで)
        let k = TextSearch.search("みつもり", segments: [a, b], corrector: corrector)
        #expect(k.total == 3 && k.hits.map(\.segmentId) == ["b", "a", "a"])  // 新しい順
        #expect(k.hits.map(\.byReading) == [false, true, true])
        // 用語集で直した表記で見つかる。用語集の読みでも見つかる
        #expect(TextSearch.search("下河内", segments: [a, b], corrector: corrector).total == 1)
        let q = TextSearch.query("しもがうち", vocabulary: vocab)
        #expect(q.terms[0].forms.contains("下河内"))
        let byVocab = TextSearch.search(q, segments: [a, b], corrector: corrector)
        #expect(byVocab.total == 1 && !byVocab.hits[0].byReading)
        #expect(TextSearch.ranges(of: q.allForms, in: byVocab.hits[0].text).map { String(byVocab.hits[0].text[$0]) } == ["下河内"])
        // 話者で絞る・件数の上限
        #expect(TextSearch.search("見積もり", segments: [a, b], corrector: corrector, filter: .init(speaker: "田中")).total == 1)
        let limited = TextSearch.search("見積もり ", segments: [a, b], corrector: corrector, limit: 1)
        #expect(limited.total == 2 && limited.hits.count == 1)

        let note = NoteSummary(name: "2026-10-13.md", kind: "day", date: "2026-10-13", title: "13日", summary: nil,
                               updatedAt: t0, bytes: 0, sha256: "")
        let hits = TextSearch.searchNotes(TextSearch.query("見積もり"), notes: [(note, "# 13日\n\n## 話したこと\n\n- **10:00 倉庫** — 見積もりを比べる\n")])
        #expect(hits.count == 1 && hits[0].snippet == "10:00 倉庫 — 見積もりを比べる" && hits[0].title == "10月13日 (火)")
    }

    /// 言語・日付・時間帯・話者で絞る。言葉がなくても条件だけで探せる
    @Test func filters() throws {
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        func at(_ d: Int, _ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))! }
        func seg(_ id: String, _ start: Date, _ pieces: [TranscriptPiece]) -> SegmentMetadata {
            var m = SegmentMetadata(id: id, codec: .opusFS320, sampleRate: 16_000, startedAt: start)
            m.state = .closed
            m.durationSeconds = 120
            m.transcript = Transcript(engine: "apple", locale: "ja-JP", pieces: pieces)
            return m
        }
        let morning = seg("m", at(20, 9, 0), [TranscriptPiece(start: 1, end: 2, text: "おはよう", language: "ja", speaker: "自分"),
                                             TranscriptPiece(start: 3, end: 4, text: "Good morning", language: "en", speaker: "Dan")])
        let night = seg("n", at(20, 23, 30), [TranscriptPiece(start: 1, end: 2, text: "おやすみ", speaker: "自分")])
        let yesterday = seg("y", at(19, 14, 0), [TranscriptPiece(start: 1, end: 2, text: "Thank you", language: "en", speaker: "Dan")])
        let all = [morning, night, yesterday]
        let none = VocabularyCorrector([])
        func ids(_ f: TextSearch.Filter, _ q: String = "") -> [String] {
            var f = f
            f.timeZone = tz
            return TextSearch.search(q, segments: all, corrector: none, filter: f).hits.map(\.text)
        }
        // 条件がなく言葉もなければ探さない
        #expect(TextSearch.search("", segments: all, corrector: none).total == 0)
        // 言語 (言語の分からない発話は日本語とみなす)
        #expect(ids(.init(language: "en")) == ["Good morning", "Thank you"])
        #expect(ids(.init(language: "ja")) == ["おやすみ", "おはよう"])
        // 日付
        let day20 = DateInterval(start: at(20, 0, 0), end: at(21, 0, 0))
        #expect(ids(.init(interval: day20)) == ["おやすみ", "Good morning", "おはよう"])
        #expect(ids(.init(language: "en", interval: day20)) == ["Good morning"])
        // 時間帯 (日をまたぐ範囲も)
        #expect(ids(.init(timeStart: 8 * 60, timeEnd: 12 * 60)) == ["Good morning", "おはよう"])
        #expect(ids(.init(timeStart: 22 * 60, timeEnd: 2 * 60)) == ["おやすみ"])
        // 言葉と組み合わせる・話者
        #expect(ids(.init(speaker: "Dan"), "thank") == ["Thank you"])
        #expect(ids(.init(interval: day20), "thank") == [])

        // まとめは日付の範囲で
        let n19 = NoteSummary(name: "2026-10-19.md", kind: "day", date: "2026-10-19", title: "19日", summary: nil, updatedAt: at(19, 23, 0), bytes: 0, sha256: "")
        let n20 = NoteSummary(name: "2026-10-20.md", kind: "day", date: "2026-10-20", title: "20日", summary: nil, updatedAt: at(20, 23, 0), bytes: 0, sha256: "")
        let notes = TextSearch.searchNotes(TextSearch.query("会議"), notes: [(n19, "# 会議\n"), (n20, "# 会議\n")], interval: day20, timeZone: tz)
        #expect(notes.map(\.name) == ["2026-10-20.md"])
        // 言葉がなければ、その日付のまとめをすべて
        let browse = TextSearch.searchNotes(TextSearch.query(""), notes: [(n19, "# 19日\n\n予定の確認\n"), (n20, "# 20日\n")], interval: day20, timeZone: tz)
        #expect(browse.map(\.name) == ["2026-10-20.md"])
        #expect(TextSearch.searchNotes(TextSearch.query(""), notes: [(n19, "# 19日\n\n予定の確認\n")]).isEmpty)
        let day19 = DateInterval(start: at(19, 0, 0), end: at(20, 0, 0))
        #expect(TextSearch.searchNotes(TextSearch.query(""), notes: [(n19, "# 19日\n\n予定の確認\n")], interval: day19, timeZone: tz).first?.snippet == "予定の確認")
        // 発話の言語は結果にも
        #expect(TextSearch.search("", segments: all, corrector: none, filter: .init(language: "en")).hits.map(\.language) == ["en", "en"])
    }
}
