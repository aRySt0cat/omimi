import Foundation
import Testing
@testable import OmiKit

@Suite struct MultilingualTests {
    /// 文字種で言語を判定する簡易版 (本番は NLLanguageRecognizer)
    func lang(_ s: String) -> String? {
        s.unicodeScalars.contains { $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) } ? "ja" : "en"
    }

    func chars(_ text: String, from start: Double, step: Double = 0.2, conf: Double = 0.95) -> [RecognizedToken] {
        text.enumerated().map { i, c in RecognizedToken(start: start + Double(i) * step, end: start + Double(i + 1) * step, text: String(c), confidence: conf) }
    }

    @Test func englishIslandReplacesJapaneseTransliteration() {
        // 日本語モデルは英語部分 (5〜8 秒) をカタカナ混じりで出してしまう
        let ja = RecognizedResult(language: "ja", start: 0, end: 12, text: "",
                                  tokens: chars("会議です。", from: 0) + [
                                      RecognizedToken(start: 5.0, end: 5.5, text: " Good", confidence: 0.9),
                                      RecognizedToken(start: 5.5, end: 6.5, text: "フィニッシュ", confidence: 0.5),
                                      RecognizedToken(start: 7.8, end: 8.0, text: "。", confidence: 0.8),
                                  ] + chars("はい。", from: 9))
        let en = [
            RecognizedResult(language: "en", start: 4.5, end: 8, text: "Good, I finished.", tokens: [
                RecognizedToken(start: 5.0, end: 5.5, text: "Good,", confidence: 0.9),
                RecognizedToken(start: 5.5, end: 7.5, text: " I finished.", confidence: 0.92),
            ]),
            // 日本語音声に対する英語モデルの出力は信頼度が低いので捨てる
            RecognizedResult(language: "en", start: 0, end: 1, text: "Kai gi des", tokens: [
                RecognizedToken(start: 0, end: 1, text: "Kai gi des", confidence: 0.2),
            ]),
        ]
        let pieces = MultilingualMerge.merge(primary: [ja], secondary: en, textLanguage: lang)
        #expect(pieces.map(\.text) == ["会議です。", "Good,", "I finished.", "はい。"] || pieces.map(\.text) == ["会議です。", "Good, I finished.", "はい。"])
        #expect(Set(pieces.map(\.language)) == ["ja", "en"])
        #expect(!pieces.contains { $0.text.contains("フィニッシュ") })
        #expect(abs(pieces.first { $0.language == "en" }!.start - 5.0) < 0.001)
    }

    @Test func foreignWordsAtIslandEdgesAreDropped() {
        // 日本語モデルのトークン時刻が英語モデルより少し早い
        let ja = RecognizedResult(language: "ja", start: 0, end: 12, text: "",
                                  tokens: chars("準備できましたか？", from: 2.5) + [
                                      RecognizedToken(start: 4.7, end: 5.9, text: " Good", confidence: 0.9),
                                      RecognizedToken(start: 10.3, end: 10.5, text: " everyone", confidence: 0.8),
                                      RecognizedToken(start: 10.5, end: 10.6, text: "。", confidence: 0.8),
                                  ] + chars("ありがとう", from: 11.3))
        let en = [RecognizedResult(language: "en", start: 5.6, end: 10.2, text: "Good morning, everyone.", tokens: [
            RecognizedToken(start: 5.6, end: 10.2, text: "Good morning, everyone.", confidence: 0.9),
        ])]
        let pieces = MultilingualMerge.merge(primary: [ja], secondary: en, textLanguage: lang)
        #expect(pieces.map(\.text) == ["準備できましたか？", "Good morning, everyone.", "ありがとう"])
    }

    @Test func secondaryRejectedWhenTextLanguageMismatches() {
        let ja = RecognizedResult(language: "ja", start: 0, end: 2, text: "", tokens: chars("わかりました", from: 0))
        // 信頼度は高いが中身がローマ字の日本語
        let en = RecognizedResult(language: "en", start: 0, end: 2, text: "わかりました", tokens: [
            RecognizedToken(start: 0, end: 2, text: "わかりました", confidence: 0.9),
        ])
        let pieces = MultilingualMerge.merge(primary: [ja], secondary: [en], textLanguage: lang)
        #expect(pieces.map(\.text) == ["わかりました"])
    }

    @Test func splitsIntoSentencesAtPunctuationAndPauses() {
        let tokens = chars("ありがとう。では", from: 0) + chars("すみません", from: 3)
        let pieces = MultilingualMerge.sentences(tokens, language: "ja")
        #expect(pieces.map(\.text) == ["ありがとう。", "では", "すみません"])
        #expect(abs(pieces[2].start - 3) < 0.0001)
        let en = [RecognizedToken(start: 0, end: 0.5, text: "Hi."), RecognizedToken(start: 0.6, end: 1, text: " Yes")]
        #expect(MultilingualMerge.sentences(en, language: "en").map(\.text) == ["Hi.", "Yes"])
    }

    @Test func meanConfidenceIsLengthWeighted() {
        let r = RecognizedResult(language: "en", start: 0, end: 1, text: "", tokens: [
            RecognizedToken(start: 0, end: 1, text: "a", confidence: 0.0),
            RecognizedToken(start: 0, end: 1, text: "bbb", confidence: 1.0),
        ])
        #expect(abs(r.meanConfidence - 0.75) < 0.0001)
    }

    @Test func cleanStripsOrphanPunctuation() {
        #expect(MultilingualMerge.clean("。ありがとう。") == "ありがとう。")
        #expect(!MultilingualMerge.hasContent("。、 "))
    }

    @Test func pieceDecodesOldJSONWithoutNewFields() throws {
        let old = #"{"start":0,"end":1,"text":"hi"}"#
        let p = try JSONDecoder().decode(TranscriptPiece.self, from: Data(old.utf8))
        #expect(p.language == nil && p.speaker == nil)
    }
}

@Suite struct MarkerTests {
    @Test func gesturesMapToMarkers() {
        var d = ButtonGestureDecoder()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(d.decode(.singleTap, at: t0) == .highlight)
        #expect(d.decode(.release, at: t0.addingTimeInterval(0.05)) == nil) // 1 回押しの後の「離した」
        #expect(d.decode(.doubleTap, at: t0.addingTimeInterval(5)) == .split)
        #expect(d.decode(.release, at: t0.addingTimeInterval(5.05)) == nil)
        #expect(d.decode(.release, at: t0.addingTimeInterval(10)) == .memo) // 単独の「離した」= 長押し
        #expect(d.decode(.press, at: t0.addingTimeInterval(11)) == nil)
    }

    @Test func storePersistsAndFilters() throws {
        let url = try tempDir().appendingPathComponent("markers.json")
        let store = MarkerStore(url: url)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        store.add(Marker(kind: .highlight, at: t0))
        store.add(Marker(kind: .memo, at: t0.addingTimeInterval(60)))
        let reloaded = MarkerStore(url: url)
        #expect(reloaded.all().map(\.kind) == [.highlight, .memo])
        #expect(reloaded.between(t0.addingTimeInterval(-1), t0.addingTimeInterval(1)).count == 1)
        reloaded.remove(reloaded.all()[0].id)
        #expect(MarkerStore(url: url).all().map(\.kind) == [.memo])
    }

    @Test func speechDetection() {
        var m = SegmentMetadata(codec: .opusFS320, sampleRate: 16_000, startedAt: Date())
        #expect(m.hasSpeech == nil)
        m.transcriptionState = .done
        m.transcript = Transcript(engine: "e", locale: "ja", pieces: [])
        #expect(m.hasSpeech == false)
        m.serverHasSpeech = true
        #expect(m.hasSpeech == true)
        m.serverHasSpeech = nil
        m.transcript?.pieces = [TranscriptPiece(start: 0, end: 1, text: "はい")]
        #expect(m.hasSpeech == true)
    }
}
