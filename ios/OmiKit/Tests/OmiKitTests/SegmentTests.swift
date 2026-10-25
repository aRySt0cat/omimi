import Foundation
import Testing
@testable import OmiKit

@Suite struct SegmentTests {
    @Test func rotatesAtMaxDuration() throws {
        let store = try SegmentStore(directory: try tempDir())
        let recorder = SegmentRecorder(store: store)
        let context = SegmentRecorder.Context(maxSegmentSeconds: 2)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var closed: [SegmentMetadata] = []
        // 5 秒分 (250 フレーム)
        for i in 0..<250 {
            closed += try recorder.append([AudioFrame(data: fakeOpus(UInt8(i % 255)))], context: context,
                                          now: start.addingTimeInterval(Double(i) * 0.02))
        }
        if let last = try recorder.close() { closed.append(last) }

        #expect(closed.map(\.durationSeconds) == [2, 2, 1])
        #expect(closed.allSatisfy { $0.state == .closed })
        // ローテーションしたセグメントは時間的に連続する
        #expect(closed[1].startedAt == closed[0].endedAt)
        #expect(closed[2].startedAt == closed[1].endedAt)
        #expect(store.all().count == 3)
        for meta in closed {
            let file = try OggOpusReader.read(url: store.audioURL(for: meta))
            #expect(file.packets.count == meta.frameCount)
            #expect(file.tags["OMI_SEGMENT_ID"] == meta.id)
        }
    }

    @Test func closeResetsContinuity() throws {
        let store = try SegmentStore(directory: try tempDir())
        let recorder = SegmentRecorder(store: store)
        let context = SegmentRecorder.Context(maxSegmentSeconds: 0.04)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try recorder.append([AudioFrame(data: fakeOpus(1)), AudioFrame(data: fakeOpus(2))], context: context, now: t0)
        try recorder.close() // 切断
        let later = t0.addingTimeInterval(3600)
        _ = try recorder.append([AudioFrame(data: fakeOpus(3))], context: context, now: later)
        let meta = try #require(try recorder.close())
        // 開始時刻は受信時刻からフレーム長 (20 ms) を引いた時刻
        #expect(abs(meta.startedAt.timeIntervalSince(later) + 0.02) < 0.0001)
    }

    /// マイク休止 (無音 10 秒でデバイスが送信を止める) を模擬する
    @Test func shortSilenceIsFilled() throws {
        let store = try SegmentStore(directory: try tempDir())
        let recorder = SegmentRecorder(store: store)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<50 {
            _ = try recorder.append([AudioFrame(data: fakeOpus(1))], context: .init(), now: t0.addingTimeInterval(Double(i + 1) * 0.02))
        }
        // 1 秒分届いた後、10 秒途切れてから再開
        let resume = t0.addingTimeInterval(11)
        for i in 0..<50 {
            _ = try recorder.append([AudioFrame(data: fakeOpus(2))], context: .init(), now: resume.addingTimeInterval(Double(i + 1) * 0.02))
        }
        let meta = try #require(try recorder.close())
        #expect(store.all().count == 1)
        #expect(abs(meta.startedAt.timeIntervalSince(t0)) < 0.0001)
        // 時間軸が実時間 (12 秒) と一致する
        #expect(abs(meta.durationSeconds - 12) < 0.03)
        #expect(abs((meta.silenceFilledSeconds ?? 0) - 10) < 0.03)
        let file = try OggOpusReader.read(url: store.audioURL(for: meta))
        #expect(file.packets.filter { $0.count == 1 }.count == 500)
    }

    @Test func longSilenceSplitsSegment() throws {
        let store = try SegmentStore(directory: try tempDir())
        let recorder = SegmentRecorder(store: store)
        let context = SegmentRecorder.Context(splitAfterSilence: 30)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try recorder.append([AudioFrame(data: fakeOpus(1))], context: context, now: t0)
        let later = t0.addingTimeInterval(120)
        let closed = try recorder.append([AudioFrame(data: fakeOpus(2))], context: context, now: later)
        #expect(closed.count == 1)
        #expect(abs(closed[0].durationSeconds - 0.02) < 0.0001)
        let second = try #require(try recorder.close())
        #expect(abs(second.startedAt.timeIntervalSince(later) + 0.02) < 0.0001)
        #expect(second.silenceFilledSeconds == 0)
    }

    @Test func idleSegmentIsClosed() throws {
        let store = try SegmentStore(directory: try tempDir())
        let recorder = SegmentRecorder(store: store)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try recorder.append([AudioFrame(data: fakeOpus(1))], context: .init(), now: t0)
        #expect(try recorder.closeIfIdle(now: t0.addingTimeInterval(10), after: 30) == nil)
        let meta = try #require(try recorder.closeIfIdle(now: t0.addingTimeInterval(31), after: 30))
        #expect(meta.state == .closed)
        #expect(recorder.current == nil)
        #expect(try recorder.closeIfIdle(now: t0.addingTimeInterval(100), after: 30) == nil)
    }

    @Test func concealedFramesAreCounted() throws {
        let store = try SegmentStore(directory: try tempDir())
        let recorder = SegmentRecorder(store: store)
        _ = try recorder.append([AudioFrame(data: fakeOpus(1)), AudioFrame(data: Data([0xB8]), concealed: true)],
                               context: .init())
        let meta = try #require(try recorder.close())
        #expect(meta.concealedFrames == 1)
        #expect(meta.frameCount == 2)
    }

    @Test func interruptedSegmentIsRecovered() throws {
        let dir = try tempDir()
        do {
            let store = try SegmentStore(directory: dir)
            let recorder = SegmentRecorder(store: store)
            _ = try recorder.append((0..<60).map { AudioFrame(data: fakeOpus(UInt8($0))) }, context: .init())
            try recorder.flush()
            // close せずに破棄 (アプリ強制終了)
        }
        let store = try SegmentStore(directory: dir)
        #expect(store.all().first?.state == .recording)
        let recovered = store.recoverInterrupted()
        #expect(recovered.count == 1)
        #expect(recovered[0].state == .closed)
        #expect(recovered[0].frameCount == 60)
        #expect(abs(recovered[0].durationSeconds - 1.2) < 0.001)
    }

    @Test func metadataJSONRoundTrip() throws {
        var meta = SegmentMetadata(codec: .opusFS320, sampleRate: 16_000, startedAt: Date(timeIntervalSince1970: 1_800_000_000.123))
        meta.transcript = Transcript(engine: "apple-speech", locale: "ja-JP", pieces: [.init(start: 0, end: 1.5, text: "こんにちは")])
        let data = try JSONEncoder.omi.encode(meta)
        let back = try JSONDecoder.omi.decode(SegmentMetadata.self, from: data)
        #expect(back.id == meta.id)
        #expect(abs(back.startedAt.timeIntervalSince1970 - 1_800_000_000.123) < 0.001)
        #expect(back.transcript?.pieces.first?.text == "こんにちは")
        // 以前の版で保存したもの (送信の状態など、今は使わない項目つき) も読める
        let old = #"""
        {"id":"20261010T000000Z-abcd1234","state":"closed","source":"live","codec":21,"sampleRate":16000,
         "startedAt":"2026-10-10T00:00:00.000Z","durationSeconds":3,"frameCount":150,"concealedFrames":0,
         "audioFileName":"x.opus","transcriptionState":"done","requestServerTranscription":true,
         "upload":{"audioUploaded":true,"transcriptUploaded":false,"attempts":1}}
        """#
        let decoded = try JSONDecoder.omi.decode(SegmentMetadata.self, from: Data(old.utf8))
        #expect(decoded.id == "20261010T000000Z-abcd1234" && decoded.state == .closed)
    }
}

@Suite struct BatteryLogTests {
    @Test func drainRateAndRemaining() {
        var log = BatteryLog()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        log.record(80, at: t0)
        log.record(80, at: t0.addingTimeInterval(600))      // 同じ値は記録しない
        log.record(78, at: t0.addingTimeInterval(3600))
        log.record(74, at: t0.addingTimeInterval(3 * 3600))
        #expect(log.samples.count == 3)
        let now = t0.addingTimeInterval(3 * 3600)
        #expect(abs((log.drainPerHour(now: now) ?? 0) - 2.0) < 0.001)
        #expect(abs((log.hoursRemaining(now: now) ?? 0) - 37.0) < 0.001)
        log.record(95, at: now.addingTimeInterval(60))        // 充電されたら測り直し
        #expect(log.samples.count == 1)
        #expect(log.drainPerHour(now: now.addingTimeInterval(60)) == nil)
    }
}
