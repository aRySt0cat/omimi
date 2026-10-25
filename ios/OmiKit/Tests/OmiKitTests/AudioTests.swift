import Foundation
import Testing
@testable import OmiKit

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("omikit-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 440 Hz のサイン波 (16 kHz)
func sine(seconds: Double, frequency: Double = 440, amplitude: Double = 8000) -> [Int16] {
    (0..<Int(16_000 * seconds)).map { Int16(amplitude * sin(2 * .pi * frequency * Double($0) / 16_000)) }
}

func rms(_ s: ArraySlice<Int16>) -> Double {
    guard !s.isEmpty else { return 0 }
    return sqrt(s.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(s.count))
}

@Suite struct OggTests {
    @Test func crcMatchesReferenceVector() {
        // Ogg の CRC-32 (poly 0x04C11DB7, 反転なし, 初期値 0)
        #expect(OggCRC.checksum(Array("123456789".utf8)) == 0x89A1_897F)
    }

    @Test func lacing() {
        #expect(OggOpusWriter.lacing(for: 80) == [80])
        #expect(OggOpusWriter.lacing(for: 255) == [255, 0])
        #expect(OggOpusWriter.lacing(for: 600) == [255, 255, 90])
    }

    @Test func roundTrip() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("a.opus")
        let writer = try OggOpusWriter(url: url, tags: [("OMI_SEGMENT_ID", "abc")], packetsPerPage: 7)
        let packets = (0..<100).map { fakeOpus(UInt8($0), length: 20 + $0 * 3) } // 300 byte 超も含む
        for p in packets { try writer.write(packet: p) }
        try writer.close()

        let file = try OggOpusReader.read(url: url)
        #expect(file.packets == packets)
        #expect(file.tags["OMI_SEGMENT_ID"] == "abc")
        #expect(file.head.inputSampleRate == 16_000)
        #expect(file.isComplete)
        #expect(file.lastGranule == 100 * 960)
        #expect(abs(file.durationSeconds - 2.0) < 0.0001)
    }

    @Test func truncatedFileIsReadable() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("b.opus")
        let writer = try OggOpusWriter(url: url, packetsPerPage: 10)
        for i in 0..<25 { try writer.write(packet: fakeOpus(UInt8(i))) }
        try writer.flush()
        // close せずに途中で切る (アプリ強制終了を模擬)
        var data = try Data(contentsOf: url)
        data.removeLast(5)
        let file = try OggOpusReader.read(data: data)
        #expect(file.packets.count == 20) // 完結した 2 ページ分
        #expect(!file.isComplete)
        #expect(file.lastGranule == 20 * 960)
    }

    @Test func corruptedPageIsDetected() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("c.opus")
        let writer = try OggOpusWriter(url: url)
        try writer.write(packet: fakeOpus(1))
        try writer.close()
        var data = try Data(contentsOf: url)
        data[data.count - 3] ^= 0xFF
        #expect(throws: OggError.self) { try OggOpusReader.read(data: data) }
    }
}

@Suite struct CodecTests {
    @Test func appleOpusRoundTrip() throws {
        let input = sine(seconds: 1.0)
        let packets = try OpusEncoder().encode(samples: input)
        #expect(packets.count >= 49 && packets.count <= 51)
        for p in packets { #expect(OpusPacket.sampleCount48k(p) == 960) }

        let decoded = try OpusDecoder().decodeSamples(packets)
        #expect(abs(decoded.count - input.count) <= 320)
        // コーデック遅延を無視してエネルギーで比較
        let r = rms(decoded[1600..<14400])
        #expect(r > rms(input[1600..<14400]) * 0.7, "rms=\(r)")
    }

    @Test func concealmentPacketDecodesToFrameOfSilenceOrPLC() throws {
        let packets = try OpusEncoder().encode(samples: sine(seconds: 0.2))
        let decoder = try OpusDecoder()
        for p in packets { _ = try decoder.decode(p) }
        let filler = try #require(OpusPacket.concealment(matching: packets[0]))
        let buf = try decoder.decode(filler)
        #expect(buf.frameLength == 320)
    }
}
