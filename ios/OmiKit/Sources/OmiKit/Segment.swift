import Foundation

/// 文字起こし結果の 1 区間。時刻はセグメント先頭からの秒。
public struct TranscriptPiece: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    /// 言語 ("ja", "en" など)
    public var language: String?
    /// 話者名 (サーバの話者分離・識別の結果)
    public var speaker: String?
    /// サーバの話者プロファイル ID
    public var speakerId: Int?
    /// 人が話者を指定した発話
    public var speakerManual: Bool?
    /// 録音の中での話者 ("S0" など)。名前も ID もない声どうしを見分ける
    public var speakerLabel: String?

    public init(start: Double, end: Double, text: String, language: String? = nil,
                speaker: String? = nil, speakerId: Int? = nil, speakerManual: Bool? = nil, speakerLabel: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.language = language
        self.speaker = speaker
        self.speakerId = speakerId
        self.speakerManual = speakerManual
        self.speakerLabel = speakerLabel
    }

    /// 同じ人の続けての発言としてまとめてよいか (ID も名前もない声は、録音の中の話者で分ける)
    public func sameSpeaker(as other: TranscriptPiece) -> Bool {
        guard speaker == other.speaker, speakerId == other.speakerId else { return false }
        if speakerId == nil, !isNamedSpeaker(speaker) { return speakerLabel == other.speakerLabel }
        return true
    }
}

public struct Transcript: Codable, Equatable, Sendable {
    /// 例: "apple-speech", "faster-whisper:large-v3-turbo"
    public var engine: String
    public var locale: String
    public var createdAt: Date
    public var pieces: [TranscriptPiece]

    public var text: String { pieces.map(\.text).joined(separator: "\n") }

    public init(engine: String, locale: String, createdAt: Date = Date(), pieces: [TranscriptPiece]) {
        self.engine = engine
        self.locale = locale
        self.createdAt = createdAt
        self.pieces = pieces
    }
}

/// 録音セグメント (数分ごとに区切った 1 ファイル) のメタデータ。
/// 音声ファイル `<id>.opus` と並べて `<id>.json` として保存する。
public struct SegmentMetadata: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        /// 録音中 (アプリが落ちた場合は起動時に復旧する)
        case recording
        /// 録音完了
        case closed
    }

    public enum TranscriptionState: String, Codable, Sendable {
        case pending
        case done
        case failed
        /// 端末での文字起こしをしない設定
        case skipped
    }

    public var id: String
    public var state: State
    public var source: String
    public var deviceId: String?
    public var deviceName: String?
    public var firmware: String?
    public var codec: OmiCodec
    public var sampleRate: Int
    /// 最初のフレームを受信した時刻 (端末の時計)
    public var startedAt: Date
    public var endedAt: Date?
    /// 書き込んだ音声の長さ (秒, 補完フレームを含む)
    public var durationSeconds: Double
    public var frameCount: Int
    /// BLE パケット欠落を補完したフレーム数
    public var concealedFrames: Int
    /// デバイスのマイクが無音で休止していた間を無音で埋めた秒数
    public var silenceFilledSeconds: Double?
    public var audioFileName: String

    public var transcriptionState: TranscriptionState
    public var transcriptionError: String?
    public var transcript: Transcript?
    /// 以前に自宅サーバから受け取った処理結果 (Whisper の文字起こし・話者付き)。今は受け取らない
    public var serverTranscript: Transcript?
    /// 以前に自宅サーバの話者分離で、発話区間が見つかったか
    public var serverHasSpeech: Bool?
    /// iPhone で行った話者分離 (声の特徴を含む)。学習した声が変わったら、ここから名前を付け直す
    public var deviceSpeakers: DeviceSpeakers?
    /// 文字起こしの話者をどこで決めたか (以前に自宅サーバから受け取った録音は server)
    public var speakerSource: SpeakerSource?

    public enum SpeakerSource: String, Codable, Sendable {
        case device
        case server
    }

    public init(id: String = SegmentMetadata.makeID(), source: String = "live", deviceId: String? = nil,
                deviceName: String? = nil, firmware: String? = nil, codec: OmiCodec, sampleRate: Int,
                startedAt: Date, transcriptionState: TranscriptionState = .pending) {
        self.id = id
        self.state = .recording
        self.source = source
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.firmware = firmware
        self.codec = codec
        self.sampleRate = sampleRate
        self.startedAt = startedAt
        self.durationSeconds = 0
        self.frameCount = 0
        self.concealedFrames = 0
        self.audioFileName = "\(id).opus"
        self.transcriptionState = transcriptionState
    }

    /// 時系列でソートできる ID: `20261010T120000Z-1a2b3c4d`
    public static func makeID(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "\(f.string(from: date))-\(suffix)"
    }

    /// 話し声があるか。文字起こしが済むまでは分からない (nil)。
    /// Omi は物音でもマイクが起きるため、話し声のない短い録音がたまる。
    public var hasSpeech: Bool? {
        let texts = [transcript, serverTranscript].compactMap { $0 }
        if texts.contains(where: { !$0.pieces.isEmpty }) { return true }
        if serverHasSpeech == true { return true }
        if transcriptionState == .done || serverTranscript != nil || serverHasSpeech == false { return false }
        return nil
    }

    /// 話者が付いているか (iPhone か自宅サーバの結果)
    public var hasSpeakers: Bool {
        (serverTranscript?.pieces ?? []).contains { $0.speaker != nil } || (transcript?.pieces ?? []).contains { $0.speaker != nil }
    }

    /// 自宅サーバの話者分離の結果が反映済みか (以前の版で保存したものは、話者があればサーバのもの)
    public var hasServerSpeakers: Bool {
        speakerSource == .server || (speakerSource == nil && hasSpeakers)
    }

    /// iPhone で話者分離するもの (話し声がある)。以前に自宅サーバが話者を付けた録音も、声の学習のために声の特徴を取る
    public var needsDeviceSpeakers: Bool {
        state == .closed && deviceSpeakers == nil && transcriptionState == .done && (transcript?.pieces.isEmpty == false)
    }
}

/// ミリ秒付き ISO 8601 (例: `2026-10-10T03:00:00.123Z`)。サーバ (Python) と共通。
enum OmiDateFormat {
    static func string(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func date(from string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}

public extension JSONEncoder {
    static var omi: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(OmiDateFormat.string(from: date))
        }
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }
}

public extension JSONDecoder {
    static var omi: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = OmiDateFormat.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid date: \(s)")
            }
            return date
        }
        return d
    }
}
