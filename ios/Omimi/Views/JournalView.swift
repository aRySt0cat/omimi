import OmiKit
import SwiftUI

/// 記録の見え方の細かさ。ピンチで切り替える。
enum JournalZoom: Int, CaseIterable, Identifiable {
    /// 1 時間ごとにまとめる
    case hours
    /// 会話ごとに 1 行 (冒頭だけ)
    case list
    /// 会話の全文
    case full

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .hours: "時間ごと"
        case .list: "会話ごと"
        case .full: "全文"
        }
    }

    var systemImage: String {
        switch self {
        case .hours: "square.grid.3x1.below.line.grid.1x2"
        case .list: "list.bullet"
        case .full: "text.alignleft"
        }
    }
}

/// ピンチの途中経過。指の動きに合わせて毎フレーム変わるので、
/// 読むのは拡大と目盛りの小さな部品だけにして、一覧全体を描き直さないようにする。
@MainActor @Observable
final class PinchState {
    /// 画面の拡大率 (指に少しだけ付いてくる)
    var scale: CGFloat = 1
    var anchor: UnitPoint = .center
    /// 隣の細かさまでの進み具合 (-1〜1)
    var progress: CGFloat = 0
    var active = false

    /// 最後に細かさが変わったときの指の開き
    @ObservationIgnored var baseMagnification: CGFloat = 1
    @ObservationIgnored var startY: CGFloat = 0
    @ObservationIgnored var lastAt = Date.distantPast
    @ObservationIgnored var viewport: CGSize = .zero
    /// 行の位置 (細かさの種類 → 行 ID → 位置)。切り替えても指の下の会話がずれないように使う。
    @ObservationIgnored var rows: [String: [String: RowFrame]] = [:]

    struct RowFrame {
        var date: Date
        var rect: CGRect
    }

    static let space = "journal-scroll"
}

/// 行の位置を PinchState に知らせる
private struct RowAnchor: ViewModifier {
    let id: String
    let date: Date
    let group: String
    @Environment(PinchState.self) private var pinch: PinchState?

    func body(content: Content) -> some View {
        content
            .id(id)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PinchState.space)) } action: { rect in
                pinch?.rows[group, default: [:]][id] = PinchState.RowFrame(date: date, rect: rect)
            }
            .onDisappear { pinch?.rows[group]?[id] = nil }
    }
}

extension View {
    fileprivate func rowAnchor(_ id: String, date: Date, group: String) -> some View {
        modifier(RowAnchor(id: id, date: date, group: group))
    }
}

/// ピンチに合わせて画面を少し拡大・縮小する (ここだけが毎フレーム描き直される)
private struct PinchScale: ViewModifier {
    let pinch: PinchState

    func body(content: Content) -> some View {
        content.animation(.interactiveSpring(response: 0.24, dampingFraction: 0.82)) {
            $0.scaleEffect(pinch.scale, anchor: pinch.anchor)
        }
    }
}

/// 「記録」: 日を選び、その日の会話を朝から夜へ時間軸に沿って読む。
/// ピンチアウトで細かく (時間ごと → 会話ごと → 全文)、ピンチインでまとめて見る。
struct JournalView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Date?
    @State private var pendingDelete: [String] = []
    @State private var confirmDelete = false
    @AppStorage("journalZoom") private var zoomRaw = JournalZoom.list.rawValue
    /// 個別に開いた会話・時間帯
    @State private var unfolded: Set<String> = []
    @State private var path: [String] = []
    @State private var pinch = PinchState()
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    /// 細かくする向き (+1) か、まとめる向き (-1) か。切り替えの動きの向きに使う。
    @State private var zoomDirection = 1

    private var zoom: JournalZoom { JournalZoom(rawValue: zoomRaw) ?? .list }
    private var days: [DayDigest] { model.days }
    private var current: DayDigest? { days.first { $0.day == selected } ?? days.first }

    /// 指の開きがこの倍率に届くたびに、細かさが 1 段変わる
    private let levelStep: CGFloat = 1.3

    /// ピンチの指が行の上で離れても、会話が開かないようにする
    private var guardedPath: Binding<[String]> {
        Binding(
            get: { path },
            set: { new in
                if new.count > path.count, Date().timeIntervalSince(pinch.lastAt) < 0.5 { return }
                path = new
            }
        )
    }

    private var guardedUnfolded: Binding<Set<String>> {
        Binding(
            get: { unfolded },
            set: { new in
                if Date().timeIntervalSince(pinch.lastAt) < 0.5 { return }
                unfolded = new
            }
        )
    }

    var body: some View {
        NavigationStack(path: guardedPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if days.count > 1 {
                        DayStrip(days: days, selected: current?.day) { selected = $0; unfolded.removeAll() }
                    }
                    if let day = current {
                        dayHeader(day)
                        if let note = model.note(for: day.day) {
                            NavigationLink(value: "note:" + note.name) { DayNoteCard(note: note) }
                                .buttonStyle(.plain)
                        }
                        // 時間ごと ↔ 会話ごとは、ズームするように入れ替える (会話ごと ↔ 全文は同じ行が伸び縮みする)
                        ZStack(alignment: .topLeading) {
                            switch zoom {
                            case .hours:
                                HourOverview(day: day, unfolded: guardedUnfolded)
                                    .transition(levelTransition)
                            case .list, .full:
                                Timeline(day: day, zoom: zoom, unfolded: guardedUnfolded)
                                    .transition(levelTransition)
                            }
                        }
                        silentBlock(day)
                    } else {
                        empty
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.immediately)
            .scrollPosition($scrollPosition)
            .coordinateSpace(.named(PinchState.space))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { pinch.viewport = $0 }
            .modifier(PinchScale(pinch: pinch))
            .simultaneousGesture(pinchGesture)
            .overlay(alignment: .top) { PinchGauge(zoom: zoom).padding(.top, 8) }
            .sensoryFeedback(.selection, trigger: zoomRaw)
            .environment(pinch)
            .paperBackground()
            .navigationTitle("記録")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { value in
                // 「note:」で始まるものは AI のまとめ、それ以外は会話の ID
                if value.hasPrefix("note:") {
                    NoteView(name: String(value.dropFirst(5)))
                } else {
                    ConversationView(id: value)
                }
            }
            .refreshable { model.refreshSegments() }
            .confirmationDialog("物音だけの録音 \(pendingDelete.count) 件を削除します", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("削除", role: .destructive) { model.deleteSegments(pendingDelete) }
            } message: {
                Text("Omi は物音でもマイクが起きるため、話し声のない録音ができます。削除すると戻せません。")
            }
        }
    }

    /// 切り替えボタンから
    private func setZoom(_ z: JournalZoom) {
        guard z != zoom else { return }
        let direction = z.rawValue > zoom.rawValue ? 1 : -1
        if direction == zoomDirection {
            changeZoom(to: z, anchorY: nil)
        } else {
            // 消える側の動きは前の描画で決まるので、向きを先に反映してから切り替える
            zoomDirection = direction
            Task { @MainActor in changeZoom(to: z, anchorY: nil) }
        }
    }

    private func changeZoom(to z: JournalZoom, anchorY: CGFloat?) {
        let target = anchorY.flatMap { y in current.flatMap { anchorTarget(y: y, to: z, day: $0) } }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            zoomRaw = z.rawValue
            unfolded.removeAll()
            if let target { scrollPosition.scrollTo(id: target.id, anchor: target.anchor) }
        }
    }

    /// 細かさが変わっていく途中も画面が指に付いてくるようにする。
    /// 指の開きが levelStep 倍になるたびに、離すのを待たずに 1 段切り替える。
    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let p = pinch
                p.lastAt = Date()
                if !p.active {
                    p.baseMagnification = 1
                    p.anchor = value.startAnchor
                    p.startY = value.startLocation.y
                    withAnimation(.snappy(duration: 0.2)) { p.active = true }
                }
                var ratio = value.magnification / p.baseMagnification
                if ratio >= levelStep, let next = JournalZoom(rawValue: zoom.rawValue + 1) {
                    changeZoom(to: next, anchorY: p.startY)
                    p.baseMagnification = value.magnification
                    ratio = 1
                } else if ratio <= 1 / levelStep, let prev = JournalZoom(rawValue: zoom.rawValue - 1) {
                    changeZoom(to: prev, anchorY: p.startY)
                    p.baseMagnification = value.magnification
                    ratio = 1
                }
                let t = log(ratio) / log(levelStep)
                // 端 (時間ごとより粗く・全文より細かく) では少しだけ逆らう
                let canMove = t >= 0 ? JournalZoom(rawValue: zoom.rawValue + 1) != nil : JournalZoom(rawValue: zoom.rawValue - 1) != nil
                p.progress = canMove ? t : t * 0.12
                p.scale = 1 + (ratio - 1) * (canMove ? 0.3 : 0.06)
                let direction = t > 0.02 ? 1 : t < -0.02 ? -1 : zoomDirection
                if direction != zoomDirection { zoomDirection = direction }
            }
            .onEnded { _ in
                let p = pinch
                p.lastAt = Date()
                p.scale = 1
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    p.progress = 0
                    p.active = false
                }
            }
    }

    /// 時間ごと ↔ 会話ごと の入れ替え。細かくするときは奥から手前へ、まとめるときは手前から奥へ。
    private var levelTransition: AnyTransition {
        let inward = zoomDirection > 0
        return .asymmetric(
            insertion: .scale(scale: inward ? 0.94 : 1.06, anchor: .top).combined(with: .opacity),
            removal: .scale(scale: inward ? 1.06 : 0.94, anchor: .top).combined(with: .opacity)
        )
    }

    /// 指の下にあった会話 (時間帯) が、切り替えたあとも同じあたりに来るようにする
    private func anchorTarget(y: CGFloat, to newZoom: JournalZoom, day: DayDigest) -> (id: String, anchor: UnitPoint)? {
        let rows = pinch.rows[zoom == .hours ? "hours" : "timeline"] ?? [:]
        guard pinch.viewport.height > 0, !rows.isEmpty else { return nil }
        func distance(_ r: CGRect) -> CGFloat { r.minY...r.maxY ~= y ? 0 : min(abs(r.minY - y), abs(r.maxY - y)) }
        guard let hit = rows.min(by: { distance($0.value.rect) < distance($1.value.rect) }),
              distance(hit.value.rect) < 60 else { return nil }
        let date = hit.value.date
        let id: String?
        if newZoom == .hours {
            let cal = Calendar.current
            let hours = Set(day.conversations.map { cal.component(.hour, from: $0.start) } + day.markers.map { cal.component(.hour, from: $0.at) })
            let h = cal.component(.hour, from: date)
            id = (hours.filter { $0 <= h }.max() ?? hours.min()).map { "h\($0)" }
        } else if zoom == .hours {
            id = (day.timeline.last { $0.date <= date } ?? day.timeline.first)?.id
        } else {
            id = hit.key
        }
        guard let id else { return nil }
        return (id, UnitPoint(x: 0.5, y: min(max(y / pinch.viewport.height, 0.05), 0.95)))
    }

    private func dayHeader(_ day: DayDigest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            JournalHeading(text: day.day.journalTitle, size: 26)
            HStack(alignment: .bottom, spacing: 18) {
                stat("会話", "\(day.conversations.count) 件")
                stat("話した時間", spokenDuration(day.talkSeconds))
                if !day.markers.isEmpty { stat("印", "\(day.markers.count)") }
                Spacer(minLength: 8)
                ZoomControl(zoom: zoom) { setZoom($0) }
            }
            if !day.speakers.isEmpty {
                FlowLayout { ForEach(day.speakers) { SpeakerChip(share: $0) } }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(Typeface.mincho(20, bold: false, relativeTo: .title3)).foregroundStyle(Palette.ink)
                .lineLimit(1).fixedSize()
            Text(label).font(.caption).foregroundStyle(Palette.inkSoft).lineLimit(1).fixedSize()
        }
    }

    @ViewBuilder private func silentBlock(_ day: DayDigest) -> some View {
        let removable = day.silent.filter { $0.state == .closed }
        if !removable.isEmpty {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "speaker.slash").foregroundStyle(Palette.inkSoft)
                VStack(alignment: .leading, spacing: 2) {
                    Text("物音だけの録音 \(removable.count) 件").font(.subheadline).foregroundStyle(Palette.ink)
                    Text("合計 \(spokenDuration(removable.reduce(0) { $0 + $1.durationSeconds }))。話し声は見つかりませんでした。")
                        .font(.footnote).foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("削除") {
                    pendingDelete = removable.map(\.id)
                    confirmDelete = true
                }
                .buttonStyle(InkButtonStyle())
                .fixedSize()
            }
            .padding(.top, 8)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            JournalHeading(text: "まだ記録がありません", size: 22)
            Text("Omi をつないで話すと、会話がここに日ごとに並びます。").foregroundStyle(Palette.inkSoft)
        }
        .padding(.top, 40)
    }
}

/// 細かさの目盛り。選択の印はピンチの進み具合に合わせて隣へ滑っていく。
struct ZoomTrack: View {
    static let cell = CGSize(width: 34, height: 28)
    static let gap: CGFloat = 2
    /// 0 = 時間ごと, 1 = 会話ごと, 2 = 全文 (途中の値も取る)
    let position: CGFloat

    var body: some View {
        let clamped = min(max(position, 0), CGFloat(JournalZoom.allCases.count - 1))
        let icons = HStack(spacing: Self.gap) {
            ForEach(JournalZoom.allCases) { z in
                Image(systemName: z.systemImage)
                    .font(.footnote.weight(.semibold))
                    .frame(width: Self.cell.width, height: Self.cell.height)
            }
        }
        let pill = Capsule()
            .frame(width: Self.cell.width, height: Self.cell.height)
            .offset(x: clamped * (Self.cell.width + Self.gap))
        ZStack(alignment: .leading) {
            icons.foregroundStyle(Palette.inkSoft)
            pill.foregroundStyle(Palette.ink)
            icons.foregroundStyle(Palette.paper).mask(alignment: .leading) { pill }
        }
        .padding(2)
        .background(Palette.surface, in: Capsule())
        .accessibilityHidden(true)
    }
}

/// 細かさの切り替え (ピンチと同じことをボタンでも)
struct ZoomControl: View {
    let zoom: JournalZoom
    let onSelect: (JournalZoom) -> Void
    @Environment(PinchState.self) private var pinch: PinchState?

    var body: some View {
        ZoomTrack(position: CGFloat(zoom.rawValue) + (pinch?.progress ?? 0))
            .overlay {
                HStack(spacing: ZoomTrack.gap) {
                    ForEach(JournalZoom.allCases) { z in
                        Button { onSelect(z) } label: {
                            Color.clear
                                .frame(width: ZoomTrack.cell.width, height: ZoomTrack.cell.height)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(z.label)
                        .accessibilityAddTraits(z == zoom ? .isSelected : [])
                    }
                }
                .padding(2)
            }
    }
}

/// ピンチしている間だけ上に浮かぶ目盛り (切り替えボタンが画面の外にあっても進み具合が見える)
private struct PinchGauge: View {
    let zoom: JournalZoom
    @Environment(PinchState.self) private var pinch

    var body: some View {
        if pinch.active {
            HStack(spacing: 10) {
                ZoomTrack(position: CGFloat(zoom.rawValue) + pinch.progress)
                Text(zoom.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.opacity)
                    .animation(.snappy(duration: 0.2), value: zoom)
            }
            .padding(.leading, 4).padding(.trailing, 16).padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: Palette.ink.opacity(0.18), radius: 14, y: 4)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }
}

/// 日付の帯。会話の量を小さな棒で示す。
struct DayStrip: View {
    let days: [DayDigest]
    let selected: Date?
    let onSelect: (Date) -> Void

    var body: some View {
        let maxTalk = max(days.map(\.talkSeconds).max() ?? 1, 60)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days.reversed()) { d in
                    let isSelected = d.day == selected
                    Button { onSelect(d.day) } label: {
                        VStack(spacing: 4) {
                            Text(d.day.formatted(.dateTime.weekday(.narrow).locale(Locale(identifier: "ja_JP"))))
                                .font(.caption2)
                            Text(d.day.formatted(.dateTime.day()))
                                .font(Typeface.mincho(20, bold: isSelected))
                            Capsule().fill(isSelected ? Palette.paper : Palette.ai)
                                .frame(width: 22 * max(0.15, d.talkSeconds / maxTalk), height: 3)
                        }
                        .frame(width: 46, height: 66)
                        .foregroundStyle(isSelected ? Palette.paper : Palette.ink)
                        .background(isSelected ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(Palette.surface),
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(d.day.journalTitle)、話した時間 \(spokenDuration(d.talkSeconds))")
                }
            }
            .padding(.vertical, 4)
        }
        .defaultScrollAnchor(.trailing)
    }
}

// MARK: - 会話ごと・全文

/// 時間軸: 左に時刻、縦の線に会話・印がぶら下がる
struct Timeline: View {
    let day: DayDigest
    let zoom: JournalZoom
    @Binding var unfolded: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(day.timeline) { item in
                row(item).rowAnchor(item.id, date: item.date, group: "timeline")
            }
        }
    }

    @ViewBuilder private func row(_ item: TimelineItem) -> some View {
        switch item {
        case .conversation(let c):
            let open = zoom == .full || unfolded.contains(c.id)
            SpineRow(time: c.start.hhmm, nodeColor: c.dominantColor) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 4) {
                        NavigationLink(value: c.id) {
                            ConversationRow(conversation: c, compact: true, showPreview: !open)
                        }
                        .buttonStyle(.plain)
                        if zoom == .list {
                            FoldButton(open: open) { toggle(c.id) }
                        }
                    }
                    if open, let t = c.transcript, !t.pieces.isEmpty {
                        TranscriptFlow(pieces: t.pieces, markers: c.markers, start: c.start, compact: true)
                            .padding(.bottom, 16)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        case .marker(let m):
            SpineRow(time: m.at.hhmm, nodeColor: Palette.marker(m.kind), small: true) {
                HStack(spacing: 8) {
                    MarkerLabel(kind: m.kind)
                    Text(m.kind.meaning).font(.caption).foregroundStyle(Palette.inkSoft)
                }
                .padding(.vertical, 6)
            }
        case .quiet(let from, let to):
            QuietRow(seconds: to.timeIntervalSince(from))
        }
    }

    private func toggle(_ id: String) {
        withAnimation(.snappy(duration: 0.25)) {
            if unfolded.contains(id) { unfolded.remove(id) } else { unfolded.insert(id) }
        }
    }
}

/// 開く・たたむ
struct FoldButton: View {
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FoldChevron(open: open)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .accessibilityLabel(open ? "たたむ" : "全文を開く")
    }
}

/// 開閉の向き: たたんでいるときは左向き、開くと下向きに回る
struct FoldChevron: View {
    let open: Bool

    var body: some View {
        Image(systemName: "chevron.left")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Palette.inkSoft)
            .rotationEffect(.degrees(open ? -90 : 0))
            .accessibilityHidden(true)
    }
}

struct SpineRow<Content: View>: View {
    let time: String
    let nodeColor: Color
    var small = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(time).font(.caption.monospacedDigit()).foregroundStyle(Palette.inkSoft)
                .lineLimit(1).fixedSize()
                .frame(width: 42, alignment: .trailing).padding(.top, small ? 10 : 14)
            Circle().fill(nodeColor).frame(width: small ? 8 : 12, height: small ? 8 : 12)
                .overlay(Circle().stroke(Palette.paper, lineWidth: 2))
                .padding(.top, small ? 12 : 15)
                .frame(width: 12)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        // 縦の線は行の高さいっぱいに引く (行どうしで途切れないように背景に置く)
        .background(alignment: .leading) {
            Rectangle().fill(Palette.line).frame(width: 2).padding(.leading, 42 + 12 + 5)
        }
        .contentShape(Rectangle())
    }
}

struct QuietRow: View {
    let seconds: Double

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Color.clear.frame(width: 42, height: 1)
            DottedLine().stroke(Palette.line, style: StrokeStyle(lineWidth: 2, dash: [2, 5])).frame(width: 12, height: 44)
            Text("静かな時間 \(spokenDuration(seconds))").font(.footnote).foregroundStyle(Palette.inkSoft)
        }
    }
}

struct DottedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return p
    }
}

/// 会話の一覧の 1 行: 誰と、何を、どの印があったか
struct ConversationRow: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    var compact = false
    var showPreview = true

    var body: some View {
        let c = conversation
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                if !compact {
                    Text(c.start.hhmm).font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(Palette.ink)
                        .fixedSize()
                }
                Text(spokenDuration(c.meta.durationSeconds - (c.meta.silenceFilledSeconds ?? 0)))
                    .font(.footnote.monospacedDigit()).foregroundStyle(Palette.inkSoft).fixedSize()
                ForEach(c.languages.filter { $0 != "ja" }, id: \.self) { LanguageTag(code: $0) }
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    ForEach(c.markers) { MarkerBadge(kind: $0.kind, size: 18) }
                }
                statusGlyph(c.meta)
            }
            // 全文を開いているときは本文に話者名が出るので省く
            if showPreview && !c.shares.isEmpty {
                FlowLayout(spacing: 10, lineSpacing: 4) {
                    ForEach(c.shares.prefix(4)) { SpeakerChip(share: $0, showDuration: false) }
                }
            }
            if showPreview {
                let preview = model.vocabularyCorrector.correct(c.preview)
                if preview.isEmpty {
                    Text(placeholder(c.meta)).font(.subheadline).foregroundStyle(Palette.inkSoft)
                } else {
                    Text(preview).font(.subheadline).foregroundStyle(Palette.ink.opacity(0.85)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func placeholder(_ m: SegmentMetadata) -> String {
        switch (m.state, m.transcriptionState) {
        case (.recording, _): "録音中"
        case (_, .pending): "文字起こしを待っています"
        case (_, .failed): "文字起こしに失敗しました"
        case (_, .skipped): "端末での文字起こしはオフです"
        default: "言葉は聞き取れませんでした"
        }
    }

    @ViewBuilder private func statusGlyph(_ m: SegmentMetadata) -> some View {
        if m.state == .recording {
            StatusDot(color: Palette.shu, pulsing: true)
        }
    }
}

// MARK: - 時間ごと

/// 1 時間ごとの帯。60 分の目盛りの上に、話していた時間を話者の色で置く。
struct HourOverview: View {
    let day: DayDigest
    @Binding var unfolded: Set<String>

    private struct Bucket: Identifiable {
        var hour: Int
        var conversations: [Conversation]
        var markers: [Marker]
        var id: String { "h\(hour)" }
        var talk: Double { conversations.reduce(0) { $0 + $1.meta.durationSeconds - ($1.meta.silenceFilledSeconds ?? 0) } }
        var firstDate: Date { (conversations.map(\.start) + markers.map(\.at)).min() ?? .distantPast }
    }

    private enum Row: Identifiable {
        case hour(Bucket)
        case quiet(from: Int, to: Int)
        var id: String {
            switch self {
            case .hour(let b): b.id
            case .quiet(let a, let b): "q\(a)-\(b)"
            }
        }
    }

    private var rows: [Row] {
        let cal = Calendar.current
        var buckets: [Int: Bucket] = [:]
        for c in day.conversations {
            let h = cal.component(.hour, from: c.start)
            buckets[h, default: Bucket(hour: h, conversations: [], markers: [])].conversations.append(c)
        }
        for m in day.markers {
            let h = cal.component(.hour, from: m.at)
            buckets[h, default: Bucket(hour: h, conversations: [], markers: [])].markers.append(m)
        }
        var out: [Row] = []
        var last: Int?
        for h in buckets.keys.sorted() {
            if let last, h - last > 1 { out.append(.quiet(from: last + 1, to: h - 1)) }
            out.append(.hour(buckets[h]!))
            last = h
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                switch row {
                case .hour(let b):
                    hourRow(b).rowAnchor(b.id, date: b.firstDate, group: "hours")
                case let .quiet(from, to):
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 42, height: 1)
                        DottedLine().stroke(Palette.line, style: StrokeStyle(lineWidth: 2, dash: [2, 5])).frame(width: 12, height: 36)
                        Text(from == to ? "\(from)時 静か" : "\(from)〜\(to)時 静か").font(.footnote).foregroundStyle(Palette.inkSoft)
                    }
                }
            }
        }
    }

    private func hourRow(_ b: Bucket) -> some View {
        let open = unfolded.contains(b.id)
        let speakers = Dictionary(grouping: b.conversations.flatMap(\.shares), by: \.id).values
            .compactMap { group -> SpeakerShare? in
                guard let first = group.first else { return nil }
                return SpeakerShare(name: first.name, speakerId: first.speakerId, seconds: group.reduce(0) { $0 + $1.seconds })
            }
            .sorted { $0.seconds > $1.seconds }
        return SpineRow(time: "\(b.hour)時", nodeColor: b.conversations.first?.dominantColor ?? Palette.inkSoft) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    guard !b.conversations.isEmpty else { return }
                    withAnimation(.snappy(duration: 0.25)) {
                        if open { unfolded.remove(b.id) } else { unfolded.insert(b.id) }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HourTrack(hour: b.hour, day: day.day, conversations: b.conversations, markers: b.markers)
                            .frame(height: 26)
                        HStack(spacing: 10) {
                            if b.conversations.isEmpty {
                                // マイクが休んでいる間に押した印だけの時間帯
                                Text("印だけ").font(.footnote).foregroundStyle(Palette.inkSoft)
                            } else {
                                Text("会話 \(b.conversations.count) 件").font(.footnote).foregroundStyle(Palette.ink)
                                Text(spokenDuration(b.talk)).font(.footnote.monospacedDigit()).foregroundStyle(Palette.inkSoft)
                            }
                            Spacer(minLength: 4)
                            HStack(spacing: 3) { ForEach(b.markers) { MarkerBadge(kind: $0.kind, size: 18) } }
                            if !b.conversations.isEmpty { FoldChevron(open: open) }
                        }
                        if !speakers.isEmpty {
                            FlowLayout(spacing: 10, lineSpacing: 4) {
                                ForEach(speakers.prefix(4)) { SpeakerChip(share: $0, showDuration: false) }
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(b.conversations.isEmpty ? "" : open ? "たたむ" : "この時間の会話を開く")

                if open {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(b.conversations) { c in
                            NavigationLink(value: c.id) { ConversationRow(conversation: c) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

/// 1 時間 (60 分) の目盛りに、会話の時間帯と印を置く
struct HourTrack: View {
    let hour: Int
    let day: Date
    let conversations: [Conversation]
    let markers: [Marker]

    var body: some View {
        Canvas { ctx, size in
            let start = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
            let x = { (d: Date) -> CGFloat in CGFloat(min(max(d.timeIntervalSince(start) / 3600, 0), 1)) * size.width }
            // 上の段に印、下の段に会話の帯
            let mid = size.height - 8
            // 目盛り (15 分ごと)
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: mid - 1, width: size.width, height: 2), cornerRadius: 1),
                     with: .color(Palette.line))
            for q in 1..<4 {
                let tx = size.width * CGFloat(q) / 4
                ctx.fill(Path(CGRect(x: tx - 0.5, y: mid - 4, width: 1, height: 8)), with: .color(Palette.line))
            }
            for c in conversations {
                let x0 = x(c.start), x1 = max(x(c.end), x0 + 4)
                ctx.fill(Path(roundedRect: CGRect(x: x0, y: mid - 5, width: x1 - x0, height: 10), cornerRadius: 3),
                         with: .color(c.dominantColor))
            }
            for m in markers {
                let mx = x(m.at)
                ctx.fill(Path(ellipseIn: CGRect(x: mx - 3.5, y: 0, width: 7, height: 7)), with: .color(Palette.marker(m.kind)))
            }
        }
        .accessibilityHidden(true)
    }
}
