import Foundation

/// 受信したフレームをセグメント (Ogg Opus ファイル) に分けて保存する。
/// スレッドセーフではない。BLE のキューなど 1 つのキューからだけ呼ぶこと。
///
/// Omi CV1 は 10 秒無音が続くとマイクを休止し、音がするまでフレームを送らない
/// (ファームウェア `mic.c` の AAD)。そのためフレーム数ではなく到着時刻を基準にする:
/// - 短い途切れ (`gapFillThreshold` 〜 `splitAfterSilence`) は無音で埋めて時間軸を保つ
/// - 長い途切れ (`splitAfterSilence` 超) はセグメントを区切る (`closeIfIdle` で無音中に閉じる)
public final class SegmentRecorder {
    public struct Context: Sendable {
        public var deviceId: String?
        public var deviceName: String?
        public var firmware: String?
        public var codec: OmiCodec
        public var source: String
        public var maxSegmentSeconds: Double
        public var transcribeOnDevice: Bool
        /// これより長い途切れを無音で埋める (BLE の揺らぎは無視する)
        public var gapFillThreshold: Double
        /// これより長く無音が続いたらセグメントを区切る
        public var splitAfterSilence: Double

        public init(deviceId: String? = nil, deviceName: String? = nil, firmware: String? = nil,
                    codec: OmiCodec = .opusFS320, source: String = "live", maxSegmentSeconds: Double = 300,
                    transcribeOnDevice: Bool = true,
                    gapFillThreshold: Double = 2, splitAfterSilence: Double = 30) {
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.firmware = firmware
            self.codec = codec
            self.source = source
            self.maxSegmentSeconds = maxSegmentSeconds
            self.transcribeOnDevice = transcribeOnDevice
            self.gapFillThreshold = gapFillThreshold
            self.splitAfterSilence = splitAfterSilence
        }
    }

    public let store: SegmentStore
    public private(set) var current: SegmentMetadata?
    /// 現在のセグメントに書いた秒数 (無音の補完を含む)
    public var currentDuration: Double { writer?.durationSeconds ?? 0 }
    /// 最後にフレームを書いた時刻
    public private(set) var lastAppendAt: Date?

    private var writer: OggOpusWriter?
    private var concealed = 0
    private var silenceFilled = 0.0
    /// 連続録音中のローテーションでは次のセグメントを前のセグメントの終端時刻から始める
    private var nextStart: Date?

    public init(store: SegmentStore) {
        self.store = store
    }

    /// フレームを書き込む。`now` はこのフレーム群を受信した時刻。
    /// 閉じられたセグメント (規定の長さに達した・長い無音で区切った) のメタデータを返す。
    public func append(_ frames: [AudioFrame], context: Context, now: Date = Date()) throws -> [SegmentMetadata] {
        guard !frames.isEmpty else { return [] }
        guard context.codec.isOpus else { throw OpusCodingError.formatUnavailable }
        var closed: [SegmentMetadata] = []

        // このフレーム群の音声が始まった時刻
        let batchSeconds = Double(frames.reduce(0) { $0 + (OpusPacket.sampleCount48k($1.data) ?? 960) }) / 48_000
        let batchStart = now.addingTimeInterval(-batchSeconds)

        if let meta = current {
            let gap = batchStart.timeIntervalSince(meta.startedAt.addingTimeInterval(currentDuration))
            if gap > context.splitAfterSilence {
                if let m = try closeCurrent(continuing: false) { closed.append(m) }
            } else if gap > context.gapFillThreshold {
                try fillSilence(seconds: gap, reference: frames[0].data)
            }
        }

        for frame in frames {
            if writer == nil {
                try open(context: context, now: batchStart)
            }
            try writer?.write(packet: frame.data)
            if frame.concealed { concealed += 1 }
            if currentDuration >= context.maxSegmentSeconds, let meta = try closeCurrent(continuing: true) {
                closed.append(meta)
            }
        }
        lastAppendAt = now
        return closed
    }

    /// 最後のフレームから `seconds` 以上経っていれば現在のセグメントを閉じる (無音でマイクが休止したとき)。
    public func closeIfIdle(now: Date = Date(), after seconds: Double) throws -> SegmentMetadata? {
        guard current != nil, let last = lastAppendAt, now.timeIntervalSince(last) >= seconds else { return nil }
        return try close()
    }

    /// 現在のセグメントを閉じる (切断時・録音停止時)。
    @discardableResult
    public func close() throws -> SegmentMetadata? {
        defer { nextStart = nil }
        return try closeCurrent(continuing: false)
    }

    /// 書きかけのページをディスクへ書き出す (アプリがバックグラウンドへ移るときなど)。
    public func flush() throws {
        try writer?.flush()
    }

    /// マイク休止中の時間を「長さ 0 のフレーム」(デコーダは無音/PLC を出力) で埋める。
    private func fillSilence(seconds: Double, reference: Data) throws {
        guard let writer, let filler = OpusPacket.concealment(matching: reference),
              let samples = OpusPacket.sampleCount48k(filler) else { return }
        let count = Int(seconds * 48_000 / Double(samples))
        for _ in 0..<count { try writer.write(packet: filler) }
        silenceFilled += Double(count * samples) / 48_000
    }

    private func open(context: Context, now: Date) throws {
        // ローテーション直後なら前セグメントの終端から続ける (端末時計と大きくずれていれば現在時刻)
        let start = nextStart.flatMap { abs($0.timeIntervalSince(now)) < context.gapFillThreshold ? $0 : nil } ?? now
        nextStart = nil
        var meta = SegmentMetadata(
            id: SegmentMetadata.makeID(date: start), source: context.source, deviceId: context.deviceId,
            deviceName: context.deviceName, firmware: context.firmware, codec: context.codec,
            sampleRate: context.codec.sampleRate, startedAt: start,
            transcriptionState: context.transcribeOnDevice ? .pending : .skipped)
        meta.state = .recording
        let url = store.audioURL(for: meta)
        writer = try OggOpusWriter(
            url: url,
            head: OpusHead(channels: 1, preSkip: 0, inputSampleRate: UInt32(context.codec.sampleRate)),
            tags: [
                ("OMI_SEGMENT_ID", meta.id),
                ("OMI_STARTED_AT", OmiDateFormat.string(from: start)),
                ("OMI_CODEC", context.codec.wireName),
            ],
            attributes: store.fileAttributes)
        concealed = 0
        silenceFilled = 0
        try store.save(meta)
        current = meta
    }

    private func closeCurrent(continuing: Bool) throws -> SegmentMetadata? {
        guard let writer, var meta = current else { return nil }
        self.writer = nil
        current = nil
        try writer.close()
        let duration = writer.durationSeconds
        meta.state = .closed
        meta.durationSeconds = duration
        meta.frameCount = writer.packetCount
        meta.concealedFrames = concealed
        meta.silenceFilledSeconds = silenceFilled
        meta.endedAt = meta.startedAt.addingTimeInterval(duration)
        nextStart = continuing ? meta.endedAt : nil
        try store.save(meta)
        return meta
    }
}
