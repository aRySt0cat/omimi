import Foundation

public struct AudioFrame: Equatable, Sendable {
    /// コーデックのフレーム 1 つ分 (Opus パケット 1 つ)
    public var data: Data
    /// 欠落を埋めるために挿入したフレームなら true
    public var concealed: Bool

    public init(data: Data, concealed: Bool = false) {
        self.data = data
        self.concealed = concealed
    }
}

/// オーディオ notification をコーデックフレームに組み立てる。
///
/// ファームウェア (`transport.c` `push_to_gatt`) は 1 フレームを MTU-3 byte ごとに分割し、
/// 各 notification に `[packetIndex u16 LE][subIndex u8]` を付ける。
/// iOS では MTU が十分大きいため通常 1 notification = 1 フレーム (subIndex 0) だが、
/// 分割された場合も正しく扱う。`maxFragmentPayload` (= MTU-3) が分かっていれば、
/// それより短い断片をフレームの終端とみなして即座に出力する。分からない場合は
/// 次の subIndex 0 の到着で終端が確定するため 1 notification 分遅れる。
/// ストリーム終了時は `flush()` を呼ぶこと。
///
/// パケット欠落時は Opus の PLC 用パケットを挿入し、録音の時間軸がずれないようにする。
public struct AudioPacketAssembler: Sendable {
    public struct Stats: Equatable, Sendable {
        public var notifications = 0
        public var duplicates = 0
        public var lostPackets = 0
        public var framesEmitted = 0
        public var concealedFrames = 0
        public var discardedFragments = 0
        public var restarts = 0
    }

    public private(set) var stats = Stats()
    /// 1 回の欠落で挿入する補完フレームの上限 (20 ms × 250 = 5 秒)
    public var maxConcealedFramesPerGap: Int
    /// これより大きいインデックスの飛びはストリーム再開とみなす (公式アプリと同じ値)
    public var restartThreshold: Int
    /// false にすると補完フレームを挿入しない
    public var concealsLoss: Bool
    /// 1 notification に載る最大ペイロード (ATT MTU - 3)。これより短い断片はフレーム終端。
    public var maxFragmentPayload: Int?

    private var lastIndex: UInt16?
    private var lastSubIndex: UInt8 = 0
    private var pending: Data?
    private var lastFrame: Data?

    public init(concealsLoss: Bool = true, maxConcealedFramesPerGap: Int = 250, restartThreshold: Int = 4096) {
        self.concealsLoss = concealsLoss
        self.maxConcealedFramesPerGap = maxConcealedFramesPerGap
        self.restartThreshold = restartThreshold
    }

    public mutating func push(_ notification: Data) -> [AudioFrame] {
        let bytes = [UInt8](notification)
        guard bytes.count > 3 else { return [] }
        let index = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let subIndex = bytes[2]
        let payload = Data(bytes[3...])
        stats.notifications += 1

        var out: [AudioFrame] = []
        if let last = lastIndex {
            let delta = Int(index &- last)
            if delta == 0 {
                stats.duplicates += 1
                return []
            }
            if delta > restartThreshold {
                stats.restarts += 1
                out += takePending()
            } else if delta > 1 {
                let missing = delta - 1
                stats.lostPackets += missing
                out += takePending()
                out += concealmentFrames(count: min(missing, maxConcealedFramesPerGap))
            }
        }
        lastIndex = index

        if subIndex == 0 {
            out += takePending()
            pending = payload
        } else if pending != nil, subIndex == lastSubIndex &+ 1 {
            pending?.append(payload)
        } else {
            // 先頭を失ったフレームの続き。復元できないので破棄し次の subIndex 0 を待つ。
            pending = nil
            stats.discardedFragments += 1
        }
        lastSubIndex = subIndex
        if let limit = maxFragmentPayload, payload.count < limit {
            out += takePending()
        }
        return out
    }

    /// 保留中のフレームを出力する (切断・セグメント終了時)。
    public mutating func flush() -> [AudioFrame] {
        takePending()
    }

    /// 接続し直したときに呼ぶ。統計は保持する。
    public mutating func resetStream() {
        lastIndex = nil
        lastSubIndex = 0
        pending = nil
    }

    public mutating func resetStats() {
        stats = Stats()
    }

    private mutating func takePending() -> [AudioFrame] {
        guard let frame = pending, !frame.isEmpty else {
            pending = nil
            return []
        }
        pending = nil
        lastFrame = frame
        stats.framesEmitted += 1
        return [AudioFrame(data: frame)]
    }

    private mutating func concealmentFrames(count: Int) -> [AudioFrame] {
        guard concealsLoss, count > 0, let reference = lastFrame,
              let filler = OpusPacket.concealment(matching: reference) else { return [] }
        stats.concealedFrames += count
        return Array(repeating: AudioFrame(data: filler, concealed: true), count: count)
    }
}
