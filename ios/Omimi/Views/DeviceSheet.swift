import OmiKit
import SwiftUI

/// Omi の接続: 近くの Omi を探して登録する。登録済みならその状態。
struct DeviceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if model.hasSavedDevice { current }
                    nearby
                    Text("Omi は一度に 1 台の iPhone にしかつながりません。公式アプリでつないでいる場合は、先に公式アプリ側で接続を解除してください。")
                        .font(.footnote).foregroundStyle(Palette.inkSoft)
                }
                .padding(20)
            }
            .paperBackground()
            .navigationTitle("Omi の接続")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .onAppear { model.startScan() }
            .onDisappear { model.stopScan() }
        }
        .presentationDetents([.medium, .large])
    }

    private var current: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaption(text: "登録している Omi")
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.stream?.deviceName ?? model.savedDeviceName ?? "Omi").font(.headline).foregroundStyle(Palette.ink)
                    Text(model.linkState.label).font(.footnote).foregroundStyle(Palette.inkSoft)
                    if let s = model.stream {
                        Text("ファームウェア \(s.firmware ?? "-")  音声 \(s.codec.wireName)\(model.mtu.map { "  MTU \($0)" } ?? "")")
                            .font(.caption).foregroundStyle(Palette.inkSoft)
                    }
                }
                Spacer()
                if let b = model.battery {
                    Text("\(b)%").font(Typeface.mincho(22, bold: false)).foregroundStyle(Palette.ink)
                }
            }
            if let rate = model.batteryLog.drainPerHour() {
                Text(batteryNote(rate))
                    .font(.footnote).foregroundStyle(Palette.inkSoft)
            }
            Button("登録を解除する", role: .destructive) {
                model.forgetDevice()
            }
            .font(.subheadline)
        }
    }

    private func batteryNote(_ rate: Double) -> String {
        var text = String(format: "直近は 1 時間に %.1f%% 減っています。", rate)
        if let h = model.batteryLog.hoursRemaining() { text += "このままだと残り約 \(Int(h)) 時間です。" }
        return text
    }

    private var nearby: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaption(text: model.hasSavedDevice ? "ほかの Omi" : "近くの Omi")
            if model.discovered.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("探しています。Omi の電源が入っているか確かめてください。").font(.subheadline).foregroundStyle(Palette.inkSoft)
                }
            }
            ForEach(model.discovered.sorted { $0.rssi > $1.rssi }) { d in
                Button {
                    model.select(d)
                    dismiss()
                } label: {
                    HStack {
                        Text(d.name).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                        Spacer()
                        SignalBars(rssi: d.rssi)
                        Text("つなぐ").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ai)
                    }
                    .padding(.vertical, 12).padding(.horizontal, 14)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 電波の強さ (近さ)
struct SignalBars: View {
    let rssi: Int

    var body: some View {
        let level = rssi > -60 ? 3 : rssi > -75 ? 2 : 1
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1).fill(i <= level ? Palette.ink : Palette.line)
                    .frame(width: 4, height: CGFloat(4 + i * 4))
            }
        }
        .accessibilityLabel(level == 3 ? "近い" : level == 2 ? "やや近い" : "遠い")
    }
}
