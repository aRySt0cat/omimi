import Foundation

// Ogg Opus (RFC 3533 / RFC 7845) の最小限の書き込み・読み込み実装。
// デバイスから届いた Opus パケットを再エンコードせずにそのまま保存する。
// ページ単位で追記するため、アプリが途中で落ちても書き込み済みページは再生できる。

public enum OggError: Error, Equatable {
    case notOgg
    case notOpus
    case truncated
    case badCRC(pageSequence: UInt32)
    case closed
}

enum OggCRC {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var r = UInt32(i) << 24
        for _ in 0..<8 {
            r = (r & 0x8000_0000) != 0 ? (r << 1) ^ 0x04C1_1DB7 : (r << 1)
        }
        return r
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0
        for b in bytes {
            crc = (crc << 8) ^ table[Int(((crc >> 24) & 0xFF) ^ UInt32(b))]
        }
        return crc
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

private extension Array where Element == UInt8 {
    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var v: T = 0
        for i in 0..<MemoryLayout<T>.size {
            v |= T(self[offset + i]) << (8 * i)
        }
        return v
    }
}

public struct OpusHead: Equatable, Sendable {
    public var channels: UInt8
    public var preSkip: UInt16
    public var inputSampleRate: UInt32

    public init(channels: UInt8 = 1, preSkip: UInt16 = 0, inputSampleRate: UInt32 = 16000) {
        self.channels = channels
        self.preSkip = preSkip
        self.inputSampleRate = inputSampleRate
    }

    var packet: Data {
        var d = Data("OpusHead".utf8)
        d.append(1) // version
        d.append(channels)
        d.appendLE(preSkip)
        d.appendLE(inputSampleRate)
        d.appendLE(Int16(0)) // output gain
        d.append(0) // channel mapping family
        return d
    }

    init?(packet: Data) {
        let b = [UInt8](packet)
        guard b.count >= 19, packet.prefix(8) == Data("OpusHead".utf8) else { return nil }
        channels = b[9]
        preSkip = b.readLE(UInt16.self, at: 10)
        inputSampleRate = b.readLE(UInt32.self, at: 12)
    }
}

/// Ogg Opus ファイルへの追記ライタ。スレッドセーフではない (呼び出し側で直列化する)。
public final class OggOpusWriter {
    public let url: URL
    /// 書き込んだ音声の総サンプル数 (48 kHz 換算, Ogg の granule position)
    public private(set) var granulePosition: Int64 = 0
    public private(set) var packetCount = 0
    public var durationSeconds: Double { Double(granulePosition) / 48_000 }

    private let handle: FileHandle
    private let serial: UInt32
    private let packetsPerPage: Int
    private var pageSequence: UInt32 = 0
    private var segmentTable: [UInt8] = []
    private var body = Data()
    private var packetsInPage = 0
    private var isClosed = false

    /// - Parameters:
    ///   - packetsPerPage: 1 ページに入れるパケット数。20 ms フレームで 50 なら 1 秒ごとにディスクへ書き出す。
    ///   - tags: OpusTags に書くコメント (`KEY=value`)
    ///   - attributes: ファイル作成時の属性 (iOS のデータ保護クラスなど)
    public init(url: URL, head: OpusHead = OpusHead(), tags: [(String, String)] = [],
                serial: UInt32 = UInt32.random(in: 1...UInt32.max), packetsPerPage: Int = 50,
                attributes: [FileAttributeKey: Any]? = nil) throws {
        self.url = url
        self.serial = serial
        self.packetsPerPage = max(1, min(packetsPerPage, 255))
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attributes) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)

        try writePage(packets: [head.packet], granule: 0, headerType: 0x02)
        var tagPacket = Data("OpusTags".utf8)
        let vendor = Data("omi-original-app".utf8)
        tagPacket.appendLE(UInt32(vendor.count))
        tagPacket.append(vendor)
        tagPacket.appendLE(UInt32(tags.count))
        for (key, value) in tags {
            let c = Data("\(key)=\(value)".utf8)
            tagPacket.appendLE(UInt32(c.count))
            tagPacket.append(c)
        }
        try writePage(packets: [tagPacket], granule: 0, headerType: 0)
    }

    deinit {
        try? handle.close()
    }

    /// Opus パケットを 1 つ追加する。granule position は TOC から計算する。
    public func write(packet: Data) throws {
        guard !isClosed else { throw OggError.closed }
        let samples = OpusPacket.sampleCount48k(packet) ?? 960
        let lacing = Self.lacing(for: packet.count)
        if segmentTable.count + lacing.count > 255 {
            try flushPage(headerType: 0)
        }
        segmentTable += lacing
        body.append(packet)
        granulePosition += Int64(samples)
        packetsInPage += 1
        packetCount += 1
        if packetsInPage >= packetsPerPage {
            try flushPage(headerType: 0)
        }
    }

    /// 書きかけのページをディスクへ書き出す。
    public func flush() throws {
        guard !isClosed, packetsInPage > 0 else { return }
        try flushPage(headerType: 0)
    }

    /// 最終ページ (EOS) を書いて閉じる。
    public func close() throws {
        guard !isClosed else { return }
        try flushPage(headerType: 0x04)
        isClosed = true
        try handle.synchronize()
        try handle.close()
    }

    private func flushPage(headerType: UInt8) throws {
        guard packetsInPage > 0 || headerType & 0x04 != 0 else { return }
        try writeRawPage(segmentTable: segmentTable, body: body, granule: granulePosition, headerType: headerType)
        segmentTable.removeAll(keepingCapacity: true)
        body.removeAll(keepingCapacity: true)
        packetsInPage = 0
    }

    private func writePage(packets: [Data], granule: Int64, headerType: UInt8) throws {
        var table: [UInt8] = []
        var data = Data()
        for p in packets {
            table += Self.lacing(for: p.count)
            data.append(p)
        }
        try writeRawPage(segmentTable: table, body: data, granule: granule, headerType: headerType)
    }

    private func writeRawPage(segmentTable: [UInt8], body: Data, granule: Int64, headerType: UInt8) throws {
        var page = Data("OggS".utf8)
        page.append(0) // version
        page.append(headerType)
        page.appendLE(granule)
        page.appendLE(serial)
        page.appendLE(pageSequence)
        page.appendLE(UInt32(0)) // CRC placeholder
        page.append(UInt8(segmentTable.count))
        page.append(contentsOf: segmentTable)
        page.append(body)
        let crc = OggCRC.checksum(page)
        page.replaceSubrange(22..<26, with: withUnsafeBytes(of: crc.littleEndian) { Data($0) })
        try handle.write(contentsOf: page)
        pageSequence += 1
    }

    static func lacing(for length: Int) -> [UInt8] {
        // 255 の倍数の場合は終端に 0 を置く
        Array(repeating: 255, count: length / 255) + [UInt8(length % 255)]
    }
}

public struct OggOpusFile: Sendable {
    public var head: OpusHead
    public var tags: [String: String]
    public var packets: [Data]
    /// 最後に完結したページの granule position (48 kHz サンプル数)
    public var lastGranule: Int64
    /// EOS ページまで読めたか (false なら途中で書き込みが止まったファイル)
    public var isComplete: Bool

    public var durationSeconds: Double { Double(max(0, lastGranule - Int64(head.preSkip))) / 48_000 }
}

public enum OggOpusReader {
    /// ファイル全体を読み込む。末尾が途中で切れていても読めたところまで返す。
    public static func read(url: URL, verifyCRC: Bool = true) throws -> OggOpusFile {
        try read(data: Data(contentsOf: url), verifyCRC: verifyCRC)
    }

    public static func read(data: Data, verifyCRC: Bool = true) throws -> OggOpusFile {
        let b = [UInt8](data)
        var offset = 0
        var packets: [Data] = []
        var partial = Data()
        var lastGranule: Int64 = 0
        var complete = false

        while offset + 27 <= b.count {
            guard b[offset] == 0x4F, b[offset + 1] == 0x67, b[offset + 2] == 0x67, b[offset + 3] == 0x53 else {
                if offset == 0 { throw OggError.notOgg }
                break
            }
            let headerType = b[offset + 5]
            let granule = b.readLE(Int64.self, at: offset + 6)
            let sequence = b.readLE(UInt32.self, at: offset + 18)
            let storedCRC = b.readLE(UInt32.self, at: offset + 22)
            let nSegments = Int(b[offset + 26])
            let tableStart = offset + 27
            guard tableStart + nSegments <= b.count else { break }
            let table = b[tableStart..<(tableStart + nSegments)]
            let bodyLength = table.reduce(0) { $0 + Int($1) }
            let pageEnd = tableStart + nSegments + bodyLength
            guard pageEnd <= b.count else { break } // 書きかけのページ

            if verifyCRC {
                var page = Array(b[offset..<pageEnd])
                page[22] = 0; page[23] = 0; page[24] = 0; page[25] = 0
                guard OggCRC.checksum(page) == storedCRC else { throw OggError.badCRC(pageSequence: sequence) }
            }

            if headerType & 0x01 == 0 { partial.removeAll() }
            var cursor = tableStart + nSegments
            var completedOnPage = false
            for lace in table {
                partial.append(contentsOf: b[cursor..<(cursor + Int(lace))])
                cursor += Int(lace)
                if lace < 255 {
                    packets.append(partial)
                    partial = Data()
                    completedOnPage = true
                }
            }
            if completedOnPage, granule >= 0 { lastGranule = granule }
            if headerType & 0x04 != 0 { complete = true }
            offset = pageEnd
        }

        guard packets.count >= 2 else { throw packets.isEmpty ? OggError.notOgg : OggError.truncated }
        guard let head = OpusHead(packet: packets[0]) else { throw OggError.notOpus }
        let tags = parseTags(packets[1])
        let audio = Array(packets.dropFirst(2))
        // granule が書かれていない場合 (ヘッダのみ等) は TOC から計算する
        if lastGranule == 0 {
            lastGranule = Int64(audio.reduce(0) { $0 + (OpusPacket.sampleCount48k($1) ?? 0) })
        }
        return OggOpusFile(head: head, tags: tags, packets: audio, lastGranule: lastGranule, isComplete: complete)
    }

    static func parseTags(_ packet: Data) -> [String: String] {
        let b = [UInt8](packet)
        guard b.count >= 16, packet.prefix(8) == Data("OpusTags".utf8) else { return [:] }
        var offset = 8
        let vendorLength = Int(b.readLE(UInt32.self, at: offset))
        offset += 4 + vendorLength
        guard offset + 4 <= b.count else { return [:] }
        let count = Int(b.readLE(UInt32.self, at: offset))
        offset += 4
        var tags: [String: String] = [:]
        for _ in 0..<count {
            guard offset + 4 <= b.count else { break }
            let len = Int(b.readLE(UInt32.self, at: offset))
            offset += 4
            guard offset + len <= b.count else { break }
            if let s = String(bytes: b[offset..<(offset + len)], encoding: .utf8),
               let eq = s.firstIndex(of: "=") {
                tags[String(s[..<eq])] = String(s[s.index(after: eq)...])
            }
            offset += len
        }
        return tags
    }
}
