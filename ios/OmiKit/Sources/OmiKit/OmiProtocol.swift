import Foundation

/// Omi デバイスの GATT 定義。
///
/// 出典 (BasedHardware/omi):
/// - `sdks/device/PROTOCOL.md`
/// - `app/lib/services/devices/models.dart`
/// - `omi/firmware/omi/src/lib/core/transport.c`, `storage.c`
public enum OmiGATT {
    // オーディオ
    public static let audioService = "19B10000-E8F2-537E-4F6C-D104768A1214"
    /// NOTIFY: `[packetIndex u16 LE][subIndex u8][codec payload]`
    public static let audioData = "19B10001-E8F2-537E-4F6C-D104768A1214"
    /// READ: 1 byte のコーデック ID
    public static let audioCodec = "19B10002-E8F2-537E-4F6C-D104768A1214"

    // 設定 (READ/WRITE 1 byte、本体のフラッシュに保存される)
    public static let settingsService = "19B10010-E8F2-537E-4F6C-D104768A1214"
    /// ランプの明るさ 0〜100 (0 で消灯)。既定 50
    public static let ledDimRatio = "19B10011-E8F2-537E-4F6C-D104768A1214"
    /// マイクの感度 0〜8。既定 6 (+20 dB)。高いと物音でマイクが休止しにくくなる
    public static let micGain = "19B10012-E8F2-537E-4F6C-D104768A1214"

    // 時刻同期 (WRITE: u32 LE epoch 秒)。接続ごとに書き込む。
    // 未同期のデバイスはオフライン (SD) 録音を破棄するため必須。
    public static let timeSyncService = "19B10030-E8F2-537E-4F6C-D104768A1214"
    public static let timeSyncWrite = "19B10031-E8F2-537E-4F6C-D104768A1214"

    // オフラインストレージ (SD カード)
    public static let storageService = "30295780-4301-EABD-2904-2849ADFEAE43"
    public static let storageControl = "30295781-4301-EABD-2904-2849ADFEAE43"
    /// READ/NOTIFY: 4×u32 LE `[usedBytes][unreadPackets][freeBytes][rtcValid]`
    public static let storageStatus = "30295782-4301-EABD-2904-2849ADFEAE43"

    // ボタン (NOTIFY: int32 LE ×2、先頭が状態)
    public static let buttonService = "23BA7924-0000-1000-7450-346EAC492E92"
    public static let buttonState = "23BA7925-0000-1000-7450-346EAC492E92"

    // 振動 (WRITE: 1 byte。1=100 ms, 2=300 ms, 3=500 ms)
    public static let hapticService = "CAB1AB95-2EA5-4F4D-BB56-874B72CFC984"
    public static let hapticWrite = "CAB1AB96-2EA5-4F4D-BB56-874B72CFC984"

    // 標準サービス
    public static let batteryService = "180F"
    public static let batteryLevel = "2A19"
    public static let deviceInfoService = "180A"
    public static let modelNumber = "2A24"
    public static let firmwareRevision = "2A26"
}

/// コーデック ID (codec characteristic の先頭バイト)。
public enum OmiCodec: UInt8, Codable, Sendable {
    case pcm16 = 0
    case pcm8 = 1
    /// DevKit: 10 ms (160 samples) フレーム
    case opus = 20
    /// Omi CV1: 20 ms (320 samples) フレーム, CELT, 32 kbps VBR
    case opusFS320 = 21

    public var isOpus: Bool { self == .opus || self == .opusFS320 }

    public var sampleRate: Int {
        switch self {
        case .pcm8: return 8000
        default: return 16000
        }
    }

    public var wireName: String {
        switch self {
        case .pcm16: return "pcm16"
        case .pcm8: return "pcm8"
        case .opus: return "opus"
        case .opusFS320: return "opus_fs320"
        }
    }
}

public enum OmiTimeSync {
    /// 時刻同期 characteristic に書く 4 byte (u32 LE, UNIX epoch 秒)。
    public static func payload(for date: Date = Date()) -> Data {
        var epoch = UInt32(clamping: Int64(date.timeIntervalSince1970)).littleEndian
        return Data(bytes: &epoch, count: 4)
    }
}

/// オフラインストレージの状態 (storageStatus characteristic)。
public struct OmiStorageStatus: Equatable, Sendable {
    public var usedBytes: UInt32
    public var unreadPackets: UInt32
    public var freeBytes: UInt32
    public var rtcValid: Bool

    public init?(data: Data) {
        guard data.count >= 16 else { return nil }
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
        }
        usedBytes = u32(0)
        unreadPackets = u32(4)
        freeBytes = u32(8)
        rtcValid = u32(12) != 0
    }
}

public enum OmiButtonEvent: Int32, Sendable {
    case singleTap = 1
    case doubleTap = 2
    case longTap = 3
    case press = 4
    case release = 5

    public init?(data: Data) {
        guard data.count >= 4 else { return nil }
        let raw = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
        self.init(rawValue: raw)
    }
}
