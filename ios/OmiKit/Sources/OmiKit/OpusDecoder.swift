@preconcurrency import AVFoundation

public enum OpusCodingError: Error {
    case formatUnavailable
    case converterUnavailable
    case conversionFailed(String)
}

/// Apple 標準の AudioToolbox で Opus パケットを 16 bit PCM にデコードする。
/// サードパーティの libopus バインディングは使わない。
public final class OpusDecoder {
    public let sampleRate: Double
    public let outputFormat: AVAudioFormat
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public init(sampleRate: Double = 16_000, framesPerPacket: UInt32 = 320) throws {
        self.sampleRate = sampleRate
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &asbd),
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false)
        else { throw OpusCodingError.formatUnavailable }
        guard let converter = AVAudioConverter(from: input, to: output) else { throw OpusCodingError.converterUnavailable }
        inputFormat = input
        outputFormat = output
        self.converter = converter
    }

    /// パケット 1 つをデコードする。
    public func decode(_ packet: Data) throws -> AVAudioPCMBuffer {
        let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: max(packet.count, 1))
        packet.withUnsafeBytes { raw in
            if let base = raw.baseAddress { compressed.data.copyMemory(from: base, byteCount: packet.count) }
        }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))

        // 1 パケットは最大 120 ms
        let capacity = AVAudioFrameCount(sampleRate * 0.12)
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw OpusCodingError.formatUnavailable
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return compressed
        }
        if status == .error {
            throw OpusCodingError.conversionFailed(error?.localizedDescription ?? "unknown")
        }
        return out
    }

    /// 複数パケットをまとめてデコードし Int16 サンプル列を返す。デコードできないパケットは無音で埋める。
    public func decodeSamples(_ packets: [Data]) -> [Int16] {
        var samples: [Int16] = []
        samples.reserveCapacity(packets.count * Int(sampleRate / 50))
        for p in packets {
            if let buf = try? decode(p), let ch = buf.int16ChannelData {
                samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
            } else if let n = OpusPacket.sampleCount48k(p) {
                samples.append(contentsOf: repeatElement(0, count: n * Int(sampleRate) / 48_000))
            }
        }
        return samples
    }
}

/// テスト・シミュレーション用の Opus エンコーダ (Apple 標準)。
/// 実機では Omi のファームウェアが libopus でエンコードする。
public final class OpusEncoder {
    public let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let framesPerPacket: AVAudioFrameCount

    public init(sampleRate: Double = 16_000, framesPerPacket: UInt32 = 320, bitRate: Int = 32_000) throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let output = AVAudioFormat(streamDescription: &asbd),
              let input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false)
        else { throw OpusCodingError.formatUnavailable }
        guard let converter = AVAudioConverter(from: input, to: output) else { throw OpusCodingError.converterUnavailable }
        converter.bitRate = bitRate
        self.inputFormat = input
        self.outputFormat = output
        self.converter = converter
        self.framesPerPacket = framesPerPacket
    }

    /// Int16 PCM 全体をエンコードしてパケット列を返す。
    public func encode(samples: [Int16]) throws -> [Data] {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw OpusCodingError.formatUnavailable
        }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { pcm.int16ChannelData![0].update(from: base, count: samples.count) }
        }

        var packets: [Data] = []
        var supplied = false
        while true {
            let out = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 64, maximumPacketSize: 1275)
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return pcm
            }
            if status == .error { throw OpusCodingError.conversionFailed(error?.localizedDescription ?? "unknown") }
            if let descs = out.packetDescriptions {
                for i in 0..<Int(out.packetCount) {
                    let d = descs[i]
                    packets.append(Data(bytes: out.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize)))
                }
            }
            if status == .endOfStream || out.packetCount == 0 { break }
        }
        return packets
    }
}
