import OmiKit
import SwiftUI

/// 紙の地 (画面の背景)
struct PaperBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Palette.paper.ignoresSafeArea())
    }
}

extension View {
    func paperBackground() -> some View { modifier(PaperBackground()) }
}

/// 見出し (明朝)
struct JournalHeading: View {
    let text: String
    var size: CGFloat = 28

    var body: some View {
        Text(text).font(Typeface.mincho(size)).foregroundStyle(Palette.ink)
    }
}

/// 小見出し: 画面内の区切り。飾りの記号やラベルは付けない。
struct SectionCaption: View {
    let text: String

    var body: some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 状態を表す点。録音中は脈打つ。
struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var on = false

    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
            .overlay(Circle().stroke(color.opacity(0.35), lineWidth: pulsing && on ? 8 : 0).scaleEffect(pulsing && on ? 1.6 : 1))
            .animation(pulsing ? .easeOut(duration: 1.1).repeatForever(autoreverses: false) : .default, value: on)
            .onAppear { on = true }
    }
}

/// 話者の名前と時間
struct SpeakerChip: View {
    let share: SpeakerShare
    var showDuration = true

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(share.color).frame(width: 8, height: 8)
            Text(share.displayName).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
            if showDuration {
                Text(spokenDuration(share.seconds)).font(.subheadline.monospacedDigit()).foregroundStyle(Palette.inkSoft)
            }
        }
    }
}

/// 話者ごとの発話の割合を 1 本の帯で表す
struct ShareBar: View {
    let shares: [SpeakerShare]

    var body: some View {
        GeometryReader { geo in
            let total = max(shares.reduce(0) { $0 + $1.seconds }, 0.001)
            HStack(spacing: 2) {
                ForEach(shares) { s in
                    RoundedRectangle(cornerRadius: 2).fill(s.color)
                        .frame(width: max(4, (geo.size.width - CGFloat(shares.count - 1) * 2) * s.seconds / total))
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

extension Marker.Kind {
    /// 印の図案 (SF Symbols)
    var systemImage: String {
        switch self {
        case .highlight: "sparkle"
        case .split: "scissors"
        case .memo: "pencil.line"
        }
    }

    /// Omi のボタン操作
    var gesture: String {
        switch self {
        case .highlight: "1 回押し"
        case .split: "2 回押し"
        case .memo: "長押し"
        }
    }

    /// 印の意味 (一言)
    var meaning: String {
        switch self {
        case .highlight: "ここは大事"
        case .split: "話題の切れ目"
        case .memo: "このあとの話は自分宛て"
        }
    }
}

/// 印のバッジ: 色を薄く敷いた丸に図案。
struct MarkerBadge: View {
    let kind: Marker.Kind
    var size: CGFloat = 24
    /// 値が変わると図案が弾む (付けたことを知らせる)
    var bounce: Int = 0

    var body: some View {
        let color = Palette.marker(kind)
        Image(systemName: kind.systemImage)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(color)
            .symbolEffect(.bounce, value: bounce)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }
}

/// 印のバッジと名前
struct MarkerLabel: View {
    let kind: Marker.Kind
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: 8) {
            MarkerBadge(kind: kind, size: size)
            Text(kind.label).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.marker(kind))
        }
        .accessibilityElement(children: .combine)
    }
}

/// 言語の小さな札 (主言語以外のときだけ出す)
struct LanguageTag: View {
    let code: String

    var body: some View {
        Text(code.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(Palette.ai)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Palette.ai.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// 横に並べ、はみ出したら折り返す
struct FlowLayout: Layout {
    var spacing: CGFloat = 14
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, s.height)
        }
        return CGSize(width: maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }
}

/// 押せるものの見た目: 藍の文字、押すと少し沈む
struct InkButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Palette.paper : Palette.ai)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(prominent ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(Palette.ai.opacity(0.1)), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
