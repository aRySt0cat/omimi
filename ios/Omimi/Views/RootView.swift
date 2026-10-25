import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("今日", systemImage: "circle.dotted.circle") { TodayView() }
            Tab("記録", systemImage: "text.line.first.and.arrowtriangle.forward") { JournalView() }
            Tab("まとめ", systemImage: "text.book.closed") { NotesView() }
            Tab("設定", systemImage: "slider.horizontal.3") { SettingsView() }
            Tab("検索", systemImage: "magnifyingglass", role: .search) { SearchView() }
        }
        .tint(Palette.ai)
    }
}

extension DeviceLinkState {
    var label: String {
        switch self {
        case .unsupported: "この端末は Bluetooth LE 非対応"
        case .bluetoothOff: "Bluetooth がオフ"
        case .unauthorized: "Bluetooth の使用が許可されていません"
        case .idle: "未登録"
        case .waiting: "近くにありません"
        case .connecting: "接続中"
        case .connected: "接続済み (録音は止めています)"
        case .streaming: "録音中"
        }
    }
}

/// 「1:23」「1:02:03」
func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
