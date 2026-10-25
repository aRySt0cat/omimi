import Foundation
import Observation
import OmiKit
import Security

/// UserDefaults のキー。バックグラウンドのキューからも `Prefs` 経由で読む。
enum PrefKey {
    static let deviceTranscription = "deviceTranscription"
    static let localeID = "localeID"
    static let secondaryLocaleID = "secondaryLocaleID"
    static let segmentMinutes = "segmentMinutes"
    static let savedDeviceID = "savedDeviceID"
    static let savedDeviceName = "savedDeviceName"
    static let recordingEnabled = "recordingEnabled"
    static let ledBrightness = "ledBrightness"
    static let micGain = "micGain"
    static let deviceSpeakers = "deviceSpeakers"
}

/// スレッドを問わず読める設定値 (UserDefaults はスレッドセーフ)。
enum Prefs {
    // UserDefaults はスレッドセーフ
    nonisolated(unsafe) static let defaults: UserDefaults = {
        let d = UserDefaults.standard
        d.register(defaults: [
            PrefKey.deviceTranscription: true,
            PrefKey.localeID: "ja-JP",
            // 主言語と同時に認識して自動で切り替える言語 ("" なら主言語のみ)
            PrefKey.secondaryLocaleID: "en-US",
            PrefKey.segmentMinutes: 5,
            PrefKey.recordingEnabled: true,
            // ランプは常に点いていて電池を使うので、既定では消す
            PrefKey.ledBrightness: 0,
            // マイクの感度は録音の質に関わるので、既定では本体の設定のまま (-1)
            PrefKey.micGain: -1,
            // iPhone の中で話者を聞き分ける (充電中・アプリを開いているとき)
            PrefKey.deviceSpeakers: true,
        ])
        return d
    }()

    /// 用語集の正しい表記 (iPhone の文字起こしにヒントとして渡す)
    static var vocabularyTerms: [String] { defaults.stringArray(forKey: "vocabularyTerms") ?? [] }
    static var deviceTranscription: Bool { defaults.bool(forKey: PrefKey.deviceTranscription) }
    static var localeID: String { defaults.string(forKey: PrefKey.localeID) ?? "ja-JP" }
    static var secondaryLocaleID: String { defaults.string(forKey: PrefKey.secondaryLocaleID) ?? "" }
    /// 文字起こしに使う言語 (先頭が主言語)
    static var locales: [Locale] {
        var ids = [localeID]
        if !secondaryLocaleID.isEmpty, secondaryLocaleID != localeID { ids.append(secondaryLocaleID) }
        return ids.map { Locale(identifier: $0) }
    }
    static var segmentSeconds: Double { Double(max(1, defaults.integer(forKey: PrefKey.segmentMinutes))) * 60 }
    static var recordingEnabled: Bool { defaults.bool(forKey: PrefKey.recordingEnabled) }
    static var ledBrightness: Int { defaults.integer(forKey: PrefKey.ledBrightness) }
    static var micGain: Int { defaults.integer(forKey: PrefKey.micGain) }
    static var deviceSpeakers: Bool { defaults.bool(forKey: PrefKey.deviceSpeakers) }
    static var savedDeviceID: UUID? { defaults.string(forKey: PrefKey.savedDeviceID).flatMap(UUID.init(uuidString:)) }
}

/// 以前に使っていた自宅サーバの API トークン (Keychain) を消す
enum Keychain {
    static func removeLegacyServerToken() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "omimi.server-token"] as CFDictionary)
    }
}

/// 設定画面用 (メインスレッド)。値を変えると UserDefaults に保存する。
@MainActor @Observable
final class AppSettings {
    private let d = Prefs.defaults

    var deviceTranscription: Bool { didSet { d.set(deviceTranscription, forKey: PrefKey.deviceTranscription) } }
    var localeID: String { didSet { d.set(localeID, forKey: PrefKey.localeID) } }
    var secondaryLocaleID: String { didSet { d.set(secondaryLocaleID, forKey: PrefKey.secondaryLocaleID) } }
    var segmentMinutes: Int { didSet { d.set(segmentMinutes, forKey: PrefKey.segmentMinutes) } }
    var recordingEnabled: Bool { didSet { d.set(recordingEnabled, forKey: PrefKey.recordingEnabled) } }
    var ledBrightness: Int { didSet { d.set(ledBrightness, forKey: PrefKey.ledBrightness) } }
    var micGain: Int { didSet { d.set(micGain, forKey: PrefKey.micGain) } }
    var deviceSpeakers: Bool { didSet { d.set(deviceSpeakers, forKey: PrefKey.deviceSpeakers) } }

    init() {
        deviceTranscription = Prefs.deviceTranscription
        localeID = Prefs.localeID
        secondaryLocaleID = Prefs.secondaryLocaleID
        segmentMinutes = d.integer(forKey: PrefKey.segmentMinutes)
        recordingEnabled = Prefs.recordingEnabled
        ledBrightness = Prefs.ledBrightness
        micGain = Prefs.micGain
        deviceSpeakers = Prefs.deviceSpeakers
    }
}
