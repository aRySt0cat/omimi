import OmiKit
import SwiftUI
import UIKit

/// 配色: 藍墨の文字と、青みのある白い紙。印は山吹、録音中は朱。話者は日本の伝統色。
enum Palette {
    static let paper = dynamic(light: 0xEEF2F6, dark: 0x121A2B)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1A2438)
    static let ink = dynamic(light: 0x1D2A44, dark: 0xE6ECF5)
    static let inkSoft = dynamic(light: 0x5B6880, dark: 0x9AA7BD)
    static let line = dynamic(light: 0xD5DCE6, dark: 0x2A3650)
    /// 山吹: 印・強調
    static let yamabuki = dynamic(light: 0xC98A1E, dark: 0xF0B54A)
    /// 朱: 録音中
    static let shu = dynamic(light: 0xD8432F, dark: 0xFF6B57)
    /// 藍: 操作できるもの
    static let ai = dynamic(light: 0x2F5D9E, dark: 0x7FA6E0)

    /// 話者の色 (浅葱, 若竹, 桔梗, 紅梅, 柿, 鶸, 錆浅葱, 藤)
    static let speakers: [Color] = [0x1E9AA8, 0x4FA37E, 0x6E5AA8, 0xD4607E, 0xD9773A, 0x8FA33A, 0x5C8C94, 0x8E7CC3]
        .map { Color(rgb: $0) }

    /// 名前を付けた人は色、名前のない声と話者不明 (「その他」) はグレー
    static func speaker(id: Int?, name: String?) -> Color {
        if name == "自分" { return ink }
        guard let id, isNamedSpeaker(name) else { return inkSoft.opacity(0.6) }
        return speakers[abs(id) % speakers.count]
    }

    static func marker(_ kind: Marker.Kind) -> Color {
        switch kind {
        case .highlight: yamabuki
        case .split: ai
        case .memo: Color(rgb: 0x4FA37E)
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

/// 書体: 日付・大きな数字はヒラギノ明朝 (日誌らしさ)、本文はシステム (ヒラギノ角ゴ)。
enum Typeface {
    static func mincho(_ size: CGFloat, bold: Bool = true, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom(bold ? "HiraMinProN-W6" : "HiraMinProN-W3", size: size, relativeTo: style)
    }
}

extension Date {
    /// 「10月10日 土曜日」
    var journalTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: self)
    }

    var hhmm: String { formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
    var hhmmss: String {
        formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }
}

/// 時間の長さを日本語で (「1時間12分」「48分」「35秒」)
func spokenDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s >= 3600 { return "\(s / 3600)時間\(s % 3600 / 60)分" }
    if s >= 60 { return "\(s / 60)分" }
    return "\(s)秒"
}
