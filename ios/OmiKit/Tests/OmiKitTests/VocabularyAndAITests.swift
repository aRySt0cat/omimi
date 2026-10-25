import Foundation
import Testing
@testable import OmiKit

@Suite struct VocabularyTests {
    let entries = [
        VocabularyEntry(id: 1, term: "下河内", reading: "しもがうち", aliases: ["しもがうち", "下川内", "下"]),
        VocabularyEntry(id: 2, term: "Omi", aliases: ["オミ", "オミー"]),
    ]

    /// サーバ (vocabulary.py) と同じ置き換え: 2 文字以上、その位置で一致するいちばん長い表記
    @Test func correctsLikeTheServer() {
        let c = VocabularyCorrector(entries)
        #expect(c.correct("しもがうちさんとオミーとオミ") == "下河内さんとOmiとOmi")
        #expect(c.correct("下の階") == "下の階")
        #expect(c.correct("") == "" && VocabularyCorrector([]).isEmpty)
        let t = Transcript(engine: "apple", locale: "ja-JP", pieces: [TranscriptPiece(start: 0, end: 1, text: "下川内です")])
        #expect(c.correct(t).pieces[0].text == "下河内です")
    }

    @Test func splitsAliasesAndDecodes() throws {
        #expect(VocabularyInput.splitAliases("霜河内、 下川内,下河内\n ") == ["霜河内", "下川内", "下河内"])
        let d = JSONDecoder.omi
        d.keyDecodingStrategy = .convertFromSnakeCase
        let e = try d.decode(VocabularyEntry.self, from: Data(#"""
        {"id":3,"term":"下河内","reading":null,"aliases":["しもがうち"],"note":"同僚","created_at":"2026-10-13T00:00:00Z","updated_at":"2026-10-13T00:00:00Z"}
        """#.utf8))
        #expect(e.term == "下河内" && e.reading == nil && e.aliases == ["しもがうち"])
    }
}

@Suite struct AILinkTests {
    /// 127.0.0.1 で戻りを受け取る (実際に通信する)
    @Test func loopbackReceivesTheCallback() async throws {
        let port = UInt16.random(in: 20_000...40_000)
        let link = LoopbackCallback(port: port)
        try await link.start()
        defer { link.stop() }
        #expect(link.redirectURI == "http://127.0.0.1:\(port)/auth/callback")

        let session = URLSession(configuration: .ephemeral)
        let (_, other) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        #expect((other as? HTTPURLResponse)?.statusCode == 404)

        async let got = link.waitForCallback(timeout: 10)
        let (page, response) = try await session.data(from: URL(string: "\(link.redirectURI)?code=c1&state=s1&client_id=oaiapp_x")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: page, as: UTF8.self).contains("接続しています"))
        let url = try await got
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "code" }?.value == "c1" && items.first { $0.name == "state" }?.value == "s1")
    }

    @Test func loopbackCanBeCancelled() async throws {
        let link = LoopbackCallback(port: UInt16.random(in: 40_001...50_000))
        try await link.start()
        defer { link.stop() }
        link.cancel()
        await #expect(throws: LoopbackError.self) { try await link.waitForCallback(timeout: 10) }
    }
}
