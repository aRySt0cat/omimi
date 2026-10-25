import OmiKit
import SwiftUI

/// 「今日」: いま聞いているかと、今日どれだけ誰と話したかを一目で。
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var showDevice = false

    private var today: DayDigest {
        model.days.first { Calendar.current.isDateInToday($0.day) }
            ?? DayDigest(day: Calendar.current.startOfDay(for: Date()), conversations: [], silent: [], looseMarkers: [])
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    dial
                    if !today.speakers.isEmpty {
                        FlowLayout { ForEach(today.speakers) { SpeakerChip(share: $0) } }
                    }
                    if model.hasSavedDevice {
                        listeningPanel
                        markerPanel
                    } else {
                        connectPanel
                    }
                    recent
                    processingNote
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .paperBackground()
            .navigationDestination(for: String.self) { ConversationView(id: $0) }
            .sheet(isPresented: $showDevice) { DeviceSheet() }
        }
    }

    // MARK: - 見出し

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                JournalHeading(text: Date().journalTitle)
                HStack(spacing: 8) {
                    StatusDot(color: status.color, pulsing: status.pulsing)
                    Text(status.text).font(.subheadline).foregroundStyle(Palette.ink)
                }
            }
            Spacer()
            Button { showDevice = true } label: { deviceBadge }
                .buttonStyle(.plain)
                .accessibilityLabel("Omi の接続")
        }
    }

    private var deviceBadge: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(model.stream?.deviceName ?? model.savedDeviceName ?? "Omi").font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.ink)
            if let b = model.battery {
                HStack(spacing: 3) {
                    Image(systemName: b < 20 ? "battery.25percent" : "battery.75percent")
                    Text("\(b)%").monospacedDigit()
                }
                .font(.caption).foregroundStyle(b < 20 ? Palette.shu : Palette.inkSoft)
            } else {
                Text("接続の設定").font(.caption).foregroundStyle(Palette.ai)
            }
        }
        .padding(.top, 4)
    }

    private var silentNow: Bool {
        guard let last = model.progress?.lastFrameAt else { return true }
        return Date().timeIntervalSince(last) > 3
    }

    private var status: (text: String, color: Color, pulsing: Bool) {
        if !model.settings.recordingEnabled { return ("録音を止めています", Palette.inkSoft, false) }
        switch model.linkState {
        case .streaming:
            return silentNow ? ("静かです。Omi のマイクは休んでいます", Palette.ai, false) : ("聞いています", Palette.shu, true)
        case .connected, .connecting: return ("Omi に接続しています", Palette.yamabuki, false)
        case .waiting: return ("Omi が近くにありません", Palette.yamabuki, false)
        case .idle: return ("Omi がまだ登録されていません", Palette.inkSoft, false)
        case .bluetoothOff: return ("Bluetooth がオフです", Palette.shu, false)
        case .unauthorized: return ("Bluetooth の使用を許可してください", Palette.shu, false)
        case .unsupported: return ("この端末では Omi を使えません", Palette.inkSoft, false)
        }
    }

    // MARK: - 文字盤

    private var liveSeconds: Double { model.stream != nil ? (model.progress?.segmentSeconds ?? 0) : 0 }

    private var dial: some View {
        DayDial(day: today.day, conversations: today.conversations, markers: today.markers,
                liveSince: model.stream != nil ? model.progress?.segmentStartedAt : nil,
                isListening: model.linkState == .streaming && !silentNow)
            .overlay {
                // 「3時間11分」のように長くても、文字盤の数字 (18・6) と重ならない幅に収める
                GeometryReader { geo in
                    VStack(spacing: 4) {
                        Text(spokenDuration(today.talkSeconds + liveSeconds))
                            .font(Typeface.mincho(44, bold: false, relativeTo: .largeTitle))
                            .foregroundStyle(Palette.ink)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text("今日の会話").font(.footnote).foregroundStyle(Palette.inkSoft)
                    }
                    .frame(maxWidth: min(geo.size.width, geo.size.height) * 0.44)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            .padding(.horizontal, 8)
    }

    // MARK: - いまの録音

    private var listeningPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionCaption(text: "いまの録音")
                Spacer()
                Button(model.settings.recordingEnabled ? "止める" : "再開する") {
                    model.setRecording(!model.settings.recordingEnabled)
                }
                .buttonStyle(InkButtonStyle(prominent: !model.settings.recordingEnabled))
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VoiceMeter(levels: model.levels, active: model.linkState == .streaming && !silentNow)
                    .frame(height: 34)
            }
            if let p = model.progress, p.segmentID != nil {
                Text("このまとまり \(formatDuration(p.segmentSeconds))。話し終えて 30 秒たつか \(Int(p.maxSegmentSeconds / 60)) 分で区切り、文字起こしします。")
                    .font(.footnote).foregroundStyle(Palette.inkSoft)
            } else {
                Text("話し始めると、ここに声の強さが出ます。").font(.footnote).foregroundStyle(Palette.inkSoft)
            }
        }
    }

    // MARK: - 印

    private var recentMarker: Marker? {
        model.lastMarker.flatMap { Date().timeIntervalSince($0.at) < 6 ? $0 : nil }
    }

    private var markerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaption(text: "印を付ける")
            HStack(spacing: 0) {
                ForEach(Array(Marker.Kind.allCases.enumerated()), id: \.element) { i, kind in
                    if i > 0 { Rectangle().fill(Palette.line).frame(width: 1, height: 52) }
                    markerButton(kind)
                }
            }
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let m = recentMarker {
                    Label {
                        Text("\(m.kind.label)の印を付けました  \(m.at.hhmmss)")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.marker(m.kind))
                    }
                    .font(.footnote).foregroundStyle(Palette.ink)
                    .transition(.opacity)
                } else {
                    Text("Omi のボタンでも付けられます。3 秒以上押し続けると電源が切れます。")
                        .font(.footnote).foregroundStyle(Palette.inkSoft)
                }
            }
            // 案内 (2 行) と確認 (1 行) が入れ替わっても下が跳ねないように
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            .animation(.easeOut(duration: 0.2), value: recentMarker?.id)
        }
    }

    private func markerButton(_ kind: Marker.Kind) -> some View {
        Button {
            model.addMarker(kind)
        } label: {
            VStack(spacing: 6) {
                MarkerBadge(kind: kind, size: 40, bounce: bounceCount(kind))
                Text(kind.label).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(kind.gesture).font(.caption2).foregroundStyle(Palette.inkSoft)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: bounceCount(kind))
        .accessibilityLabel("\(kind.label)の印を付ける")
        .accessibilityHint(kind.meaning)
    }

    /// 種類ごとの印の数 (付けるたびにバッジを弾ませる)
    private func bounceCount(_ kind: Marker.Kind) -> Int {
        model.markers.filter { $0.kind == kind }.count
    }

    // MARK: - 接続

    private var connectPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Omi をつなぐと、話した時間がこの文字盤に記録されていきます。")
                .font(.body).foregroundStyle(Palette.ink)
            Button("Omi を探す") { showDevice = true }
                .buttonStyle(InkButtonStyle(prominent: true))
        }
    }

    // MARK: - 最近の会話

    @ViewBuilder private var recent: some View {
        let latest = Array(today.conversations.suffix(3).reversed())
        if !latest.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionCaption(text: "さっきの会話").padding(.bottom, 4)
                ForEach(latest) { c in
                    NavigationLink(value: c.id) { ConversationRow(conversation: c) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var processingNote: some View {
        let lines = [
            model.transcribingID != nil ? "文字起こし中" : nil,
            model.pendingTranscriptions > 0 ? "文字起こし待ち \(model.pendingTranscriptions) 件" : nil,
            model.diarizingID != nil ? "話者を聞き分けています" : nil,
        ].compactMap { $0 }
        if !lines.isEmpty || model.lastError != nil {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { Text($0) }
                if let e = model.lastError { Text(e).foregroundStyle(Palette.shu) }
            }
            .font(.footnote).foregroundStyle(Palette.inkSoft)
        }
    }
}
