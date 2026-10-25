import Foundation

/// Opus パケットの TOC バイト解析 (RFC 6716 §3.1)。
public enum OpusPacket {
    /// パケットの長さを 48 kHz サンプル数で返す (Ogg の granule position 計算用)。
    public static func sampleCount48k(_ packet: Data) -> Int? {
        guard let toc = packet.first else { return nil }
        let config = Int(toc >> 3)
        let perFrame: Int
        switch config {
        case 0..<12: perFrame = [480, 960, 1920, 2880][config % 4]  // SILK 10/20/40/60 ms
        case 12..<16: perFrame = [480, 960][config % 2]             // Hybrid 10/20 ms
        default: perFrame = [120, 240, 480, 960][config % 4]        // CELT 2.5/5/10/20 ms
        }
        let frames: Int
        switch toc & 0x03 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            guard packet.count >= 2 else { return nil }
            frames = Int(packet[packet.startIndex + 1] & 0x3F)
        }
        let total = perFrame * frames
        // 1 パケットは最大 120 ms (RFC 6716 R5)
        guard total > 0, total <= 5760 else { return nil }
        return total
    }

    /// 欠落フレームを埋めるパケット。直前パケットと同じ構成で長さ 0 のフレーム 1 つ
    /// (= DTX / 欠落扱い) を表す 1 byte パケットを返す。デコーダは PLC で補完する。
    public static func concealment(matching reference: Data) -> Data? {
        guard let toc = reference.first else { return nil }
        return Data([toc & 0xFC])
    }
}
