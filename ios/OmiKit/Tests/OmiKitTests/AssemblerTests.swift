import Foundation
import Testing
@testable import OmiKit

/// CELT WB 20 ms (config 23) の TOC を持つダミー Opus パケット
func fakeOpus(_ tag: UInt8, length: Int = 40) -> Data {
    Data([0xB8]) + Data(repeating: tag, count: length - 1)
}

func notification(index: UInt16, sub: UInt8 = 0, _ payload: Data) -> Data {
    Data([UInt8(index & 0xFF), UInt8(index >> 8), sub]) + payload
}

@Suite struct AssemblerTests {
    @Test func singleFramePerNotification() {
        var a = AudioPacketAssembler()
        #expect(a.push(notification(index: 0, fakeOpus(1))).isEmpty) // 1 つ遅れて出る
        #expect(a.push(notification(index: 1, fakeOpus(2))) == [AudioFrame(data: fakeOpus(1))])
        #expect(a.push(notification(index: 2, fakeOpus(3))) == [AudioFrame(data: fakeOpus(2))])
        #expect(a.flush() == [AudioFrame(data: fakeOpus(3))])
        #expect(a.stats.framesEmitted == 3)
        #expect(a.stats.lostPackets == 0)
    }

    @Test func emitsImmediatelyWhenFragmentIsShorterThanMTU() {
        var a = AudioPacketAssembler()
        a.maxFragmentPayload = 182 // MTU 185
        #expect(a.push(notification(index: 0, fakeOpus(1))) == [AudioFrame(data: fakeOpus(1))])
        #expect(a.push(notification(index: 1, fakeOpus(2))) == [AudioFrame(data: fakeOpus(2))])
        #expect(a.flush().isEmpty)
        // MTU が小さく分割された場合は最後の断片で出力
        a.maxFragmentPayload = 60
        let frame = fakeOpus(7, length: 150)
        #expect(a.push(notification(index: 2, sub: 0, frame.prefix(60))).isEmpty)
        #expect(a.push(notification(index: 3, sub: 1, frame.dropFirst(60).prefix(60))).isEmpty)
        #expect(a.push(notification(index: 4, sub: 2, frame.dropFirst(120))) == [AudioFrame(data: frame)])
    }

    @Test func fragmentedFrameIsReassembled() {
        var a = AudioPacketAssembler()
        let frame = fakeOpus(7, length: 150)
        _ = a.push(notification(index: 10, sub: 0, frame.prefix(60)))
        _ = a.push(notification(index: 11, sub: 1, frame.dropFirst(60).prefix(60)))
        _ = a.push(notification(index: 12, sub: 2, frame.dropFirst(120)))
        let out = a.push(notification(index: 13, sub: 0, fakeOpus(8)))
        #expect(out == [AudioFrame(data: frame)])
    }

    @Test func lostPacketsAreConcealed() {
        var a = AudioPacketAssembler()
        _ = a.push(notification(index: 0, fakeOpus(1)))
        // index 1, 2 を欠落
        let out = a.push(notification(index: 3, fakeOpus(4)))
        #expect(out.count == 3)
        #expect(out[0] == AudioFrame(data: fakeOpus(1)))
        #expect(out[1] == AudioFrame(data: Data([0xB8]), concealed: true))
        #expect(out[2].concealed)
        #expect(a.stats.lostPackets == 2)
        #expect(a.stats.concealedFrames == 2)
        // 補完パケットの長さは元フレームと同じ 20 ms
        #expect(OpusPacket.sampleCount48k(out[1].data) == 960)
    }

    @Test func indexWrapsAround() {
        var a = AudioPacketAssembler()
        _ = a.push(notification(index: 65535, fakeOpus(1)))
        let out = a.push(notification(index: 0, fakeOpus(2)))
        #expect(out == [AudioFrame(data: fakeOpus(1))])
        #expect(a.stats.lostPackets == 0)
    }

    @Test func duplicatesAreDropped() {
        var a = AudioPacketAssembler()
        _ = a.push(notification(index: 5, fakeOpus(1)))
        #expect(a.push(notification(index: 5, fakeOpus(1))).isEmpty)
        #expect(a.stats.duplicates == 1)
    }

    @Test func largeJumpIsRestartWithoutConcealment() {
        var a = AudioPacketAssembler()
        _ = a.push(notification(index: 100, fakeOpus(1)))
        let out = a.push(notification(index: 30000, fakeOpus(2)))
        #expect(out == [AudioFrame(data: fakeOpus(1))])
        #expect(a.stats.restarts == 1)
        #expect(a.stats.concealedFrames == 0)
    }

    @Test func orphanFragmentIsDiscarded() {
        var a = AudioPacketAssembler()
        _ = a.push(notification(index: 0, sub: 0, fakeOpus(1)))
        // index 1 (次フレームの先頭) を欠落し、その続きだけが届いた
        let out = a.push(notification(index: 2, sub: 1, Data([9, 9, 9])))
        #expect(out.first == AudioFrame(data: fakeOpus(1)))
        #expect(a.stats.discardedFragments == 1)
        #expect(a.flush().isEmpty)
    }

    @Test func headerOnlyNotificationIgnored() {
        var a = AudioPacketAssembler()
        #expect(a.push(Data([0, 0, 0])).isEmpty)
        #expect(a.stats.notifications == 0)
    }
}

@Suite struct ProtocolTests {
    @Test func timeSyncIsLittleEndianEpoch() {
        let d = OmiTimeSync.payload(for: Date(timeIntervalSince1970: 0x6512_3456))
        #expect(d == Data([0x56, 0x34, 0x12, 0x65]))
    }

    @Test func storageStatusParses() {
        var raw = Data()
        for v: UInt32 in [1000, 42, 5000, 1] { withUnsafeBytes(of: v.littleEndian) { raw.append(contentsOf: $0) } }
        let s = OmiStorageStatus(data: raw)
        #expect(s?.unreadPackets == 42)
        #expect(s?.rtcValid == true)
        #expect(OmiStorageStatus(data: Data([1, 2])) == nil)
    }

    @Test func buttonEvent() {
        #expect(OmiButtonEvent(data: Data([2, 0, 0, 0, 0, 0, 0, 0])) == .doubleTap)
    }

    @Test(arguments: [
        (UInt8(0xB8), 960),   // CELT WB 20 ms
        (UInt8(0xB0), 480),   // CELT WB 10 ms
        (UInt8(0x48), 960),   // SILK WB 20 ms
        (UInt8(0xF8), 960),   // CELT FB 20 ms
    ])
    func tocDuration(toc: UInt8, expected: Int) {
        #expect(OpusPacket.sampleCount48k(Data([toc, 0])) == expected)
    }

    @Test func tocMultiFrame() {
        #expect(OpusPacket.sampleCount48k(Data([0xB8 | 1, 0, 0])) == 1920) // code 1: 2 フレーム
        #expect(OpusPacket.sampleCount48k(Data([0xB8 | 3, 3, 0])) == 2880) // code 3: 3 フレーム
    }
}
