import Foundation

/// 名前を付けていない人 (店員・アナウンス・通りすがりなど) の表示名。人の名前には使えない。
public let otherSpeakerName = "その他"

/// 名前のある人か (名前のない声と話者不明は「その他」)
public func isNamedSpeaker(_ name: String?) -> Bool {
    guard let name, !name.isEmpty else { return false }
    return name != otherSpeakerName
}

/// 誰にするか
public enum SpeakerTarget: Codable, Equatable, Sendable {
    /// 既にいる話者
    case speaker(id: Int, name: String)
    /// 名前で指定 (同じ名前の人がいればその人)
    case newName(String)
    /// 不明にする
    case unknown
    /// 今の話者で合っている (発話の確認)
    case confirm
}

/// iPhone で直した話者 (文字起こしに反映する)
public struct SpeakerEdit: Codable, Identifiable, Equatable, Sendable {
    public enum Scope: Codable, Equatable, Sendable {
        /// 録音の中の時間の範囲 (タップした発話)
        case range(start: Double, end: Double)
        /// 録音の中の、ある話者 (nil は ID のない「不明」「その他」) のところすべて
        case speaker(from: Int?)
        /// 名前のない声 (話者 ID。以前に自宅サーバが付けたもの) のすべての録音
        case voice(id: Int)
        /// 録音の中の、ID のない名前の人 (iPhone だけで名前を付けた人) のところすべて
        case named(String)
        /// 録音の中の、iPhone の話者分離で見分けた名前のない声 ("S0" など) のところすべて。
        /// 自宅サーバの話者分離とはラベルが違うので、送るときは発話の範囲に直す (`rangesForServer`)
        case label(String)
    }

    public var id: UUID
    public var segmentId: String
    public var scope: Scope
    public var target: SpeakerTarget
    public var createdAt: Date

    public init(id: UUID = UUID(), segmentId: String, scope: Scope, target: SpeakerTarget, createdAt: Date = Date()) {
        self.id = id
        self.segmentId = segmentId
        self.scope = scope
        self.target = target
        self.createdAt = createdAt
    }

    /// この指定が当たる区間か
    public func matches(_ p: TranscriptPiece) -> Bool {
        switch scope {
        case let .range(start, end):
            let overlap = min(end, p.end) - max(start, p.start)
            return overlap > 0 && overlap >= 0.5 * max(p.end - p.start, 0.001)
        case let .speaker(from):
            return from == nil ? (p.speakerId == nil && !isNamedSpeaker(p.speaker)) : p.speakerId == from
        case let .voice(id):
            return p.speakerId == id
        case let .named(name):
            return p.speakerId == nil && p.speaker == name
        case let .label(label):
            return p.speakerId == nil && !isNamedSpeaker(p.speaker) && p.speakerLabel == label
        }
    }

    /// 文字起こしに反映する。変わったら true。
    @discardableResult
    public func apply(to transcript: inout Transcript) -> Bool {
        var changed = false
        for i in transcript.pieces.indices {
            let p = transcript.pieces[i]
            guard matches(p) else { continue }
            var q = p
            switch target {
            case let .speaker(id, name):
                q.speaker = name
                q.speakerId = id
            case let .newName(name):
                q.speaker = name
                q.speakerId = nil
            case .unknown:
                q.speaker = nil
                q.speakerId = nil
            case .confirm:
                break
            }
            if case .voice = scope {
                // 声ごと決めたときは、発話を人が指定したことにはしない (学習し直したときに付け直せるように)
            } else {
                q.speakerManual = true
            }
            if q != p {
                transcript.pieces[i] = q
                changed = true
            }
        }
        return changed
    }
}

/// 16 bit モノラルの WAV
public enum WAV {
    public static func make(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBufferPointer { buf in
            for s in buf { withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) } }
        }
        return data
    }
}

public enum OggClip {
    /// Ogg Opus の録音から、時間の範囲 (秒) に入るパケットを取り出す。デコーダの立ち上がりのため少し前から取る。
    public static func packets(_ file: OggOpusFile, from start: Double, to end: Double, lead: Double = 0.1) -> [Data] {
        var t = 0.0
        var out: [Data] = []
        for p in file.packets {
            let duration = Double(OpusPacket.sampleCount48k(p) ?? 960) / 48_000
            if t + duration > start - lead && t < end { out.append(p) }
            t += duration
            if t >= end { break }
        }
        return out
    }
}
