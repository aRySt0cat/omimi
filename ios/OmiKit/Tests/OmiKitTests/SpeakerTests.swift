import Foundation
import Testing
@testable import OmiKit

@Suite struct SpeakerEditTests {
    func transcript() -> Transcript {
        Transcript(engine: "apple", locale: "ja-JP", pieces: [
            TranscriptPiece(start: 0, end: 2, text: "おはよう", speaker: "自分", speakerId: 3),
            TranscriptPiece(start: 2.5, end: 4, text: "元気?", speaker: "話者5", speakerId: 5),
            TranscriptPiece(start: 4.2, end: 6, text: "うん", speaker: "話者5", speakerId: 5),
            TranscriptPiece(start: 7, end: 8, text: "えっと"),
        ])
    }

    @Test func rangeChangesOnlyThePiecesMostlyInside() {
        var t = transcript()
        let edit = SpeakerEdit(segmentId: "s", scope: .range(start: 2.4, end: 4.5), target: .newName("田中"))
        #expect(edit.apply(to: &t))
        #expect(t.pieces.map(\.speaker) == ["自分", "田中", "話者5", nil])
        #expect(t.pieces[1].speakerId == nil && t.pieces[1].speakerManual == true && t.pieces[2].speakerManual == nil)
    }

    @Test func speakerScopeChangesEveryPieceOfThatSpeaker() {
        var t = transcript()
        SpeakerEdit(segmentId: "s", scope: .speaker(from: 5), target: .speaker(id: 7, name: "田中")).apply(to: &t)
        #expect(t.pieces.map(\.speaker) == ["自分", "田中", "田中", nil])
        #expect(t.pieces.map(\.speakerId) == [3, 7, 7, nil])
        // 「不明」のところをまとめて指定する
        SpeakerEdit(segmentId: "s", scope: .speaker(from: nil), target: .speaker(id: 3, name: "自分")).apply(to: &t)
        #expect(t.pieces[3].speaker == "自分")
        // 不明にする / 確認 (話者は変えず、指定済みにする)
        SpeakerEdit(segmentId: "s", scope: .range(start: 0, end: 2), target: .unknown).apply(to: &t)
        #expect(t.pieces[0].speaker == nil && t.pieces[0].speakerId == nil)
        var u = transcript()
        SpeakerEdit(segmentId: "s", scope: .range(start: 0, end: 2), target: .confirm).apply(to: &u)
        #expect(u.pieces[0].speaker == "自分" && u.pieces[0].speakerManual == true)
    }

    @Test func voiceScopeNamesTheVoiceEverywhere() {
        var t = transcript()
        SpeakerEdit(segmentId: "s", scope: .voice(id: 5), target: .newName("田中")).apply(to: &t)
        #expect(t.pieces.map(\.speaker) == ["自分", "田中", "田中", nil])
        // 声ごと決めたときは、人が指定した発話にはしない
        #expect(t.pieces[1].speakerManual == nil)
        #expect(isNamedSpeaker("田中") && !isNamedSpeaker("その他") && !isNamedSpeaker(nil) && !isNamedSpeaker(""))
    }

    @Test func editsSurviveRestartAndOldPiecesDecode() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let edits = [SpeakerEdit(segmentId: "a", scope: .range(start: 1, end: 2), target: .newName("田中"), createdAt: at),
                     SpeakerEdit(segmentId: "b", scope: .speaker(from: nil), target: .unknown, createdAt: at)]
        let data = try JSONEncoder.omi.encode(edits)
        #expect(try JSONDecoder.omi.decode([SpeakerEdit].self, from: data) == edits)
        let old = #"{"start":0,"end":1,"text":"a","speaker":"自分","speakerId":3}"#
        #expect(try JSONDecoder.omi.decode(TranscriptPiece.self, from: Data(old.utf8)).speakerManual == nil)
    }

    @Test func wavAndClipPackets() throws {
        let wav = WAV.make(samples: [0, 1, -1, 32767], sampleRate: 16_000)
        #expect(wav.count == 44 + 8)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF" && String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == 16_000)

        // 20 ms のパケット 100 個 (2 秒) から 0.5〜1.0 秒を取り出す
        let packet = Data([0x08] + Array(repeating: 0, count: 10))  // TOC: CELT 20 ms
        let file = OggOpusFile(head: OpusHead(), tags: [:], packets: Array(repeating: packet, count: 100),
                               lastGranule: 96_000, isComplete: true)
        let picked = OggClip.packets(file, from: 0.5, to: 1.0, lead: 0.1)
        #expect((29...31).contains(picked.count))  // 0.4 秒から 1.0 秒まで (境目は浮動小数点の誤差あり)
    }
}
