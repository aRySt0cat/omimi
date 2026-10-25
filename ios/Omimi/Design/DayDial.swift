import OmiKit
import SwiftUI

/// 24 時間の文字盤。0 時を真上に、話していた時間帯を話者の色の弧で描き、印を外周に打つ。
struct DayDial: View {
    let day: Date
    let conversations: [Conversation]
    let markers: [Marker]
    /// 録音中のセグメントの開始時刻 (今日だけ)
    var liveSince: Date?
    var isListening = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: isListening ? 0.05 : 30)) { context in
            Canvas { ctx, size in
                draw(in: &ctx, size: size, now: context.date)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    private func angle(_ date: Date) -> Angle {
        let seconds = date.timeIntervalSince(Calendar.current.startOfDay(for: day))
        return .degrees(seconds / 86_400 * 360 - 90)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, now: Date) {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let ring = side * 0.40
        let width = side * 0.075

        // 文字盤の地: 細い線。今日のすでに過ぎた時間は少し濃く。
        var track = Path()
        track.addArc(center: center, radius: ring, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
        ctx.stroke(track, with: .color(Palette.line.opacity(0.6)), lineWidth: width * 0.28)
        if isToday {
            var elapsed = Path()
            elapsed.addArc(center: center, radius: ring, startAngle: .degrees(-90), endAngle: angle(now), clockwise: false)
            ctx.stroke(elapsed, with: .color(Palette.line), lineWidth: width * 0.28)
        }

        // 時刻の目盛り (6 時間ごとに長く)
        for h in 0..<24 {
            let a = Angle.degrees(Double(h) / 24 * 360 - 90)
            let major = h % 6 == 0
            let r0 = ring - width / 2 - (major ? side * 0.03 : side * 0.016)
            let r1 = ring - width / 2 - side * 0.008
            var tick = Path()
            tick.move(to: point(center, r0, a))
            tick.addLine(to: point(center, r1, a))
            ctx.stroke(tick, with: .color(Palette.inkSoft.opacity(major ? 0.7 : 0.35)), lineWidth: major ? 1.5 : 1)
            if major {
                let label = Text("\(h)").font(Typeface.mincho(side * 0.045, bold: false)).foregroundStyle(Palette.inkSoft)
                // 目盛りと重ならないよう内側に離して置く
                ctx.draw(label, at: point(center, ring - width / 2 - side * 0.085, a))
            }
        }

        // 会話の弧 (短い会話も見えるよう最低 1.5°)
        for c in conversations {
            let a0 = angle(c.start)
            var a1 = angle(c.end)
            if a1.degrees - a0.degrees < 1.5 { a1 = .degrees(a0.degrees + 1.5) }
            var arc = Path()
            arc.addArc(center: center, radius: ring, startAngle: a0, endAngle: a1, clockwise: false)
            ctx.stroke(arc, with: .color(c.dominantColor), style: StrokeStyle(lineWidth: width * 0.8, lineCap: .butt))
        }

        // 録音中の弧 (脈打つ)
        if isToday, let liveSince {
            let pulse = isListening ? 0.55 + 0.45 * (0.5 + 0.5 * sin(now.timeIntervalSinceReferenceDate * 4)) : 0.5
            let a0 = angle(liveSince)
            var a1 = angle(now)
            if a1.degrees - a0.degrees < 1.5 { a1 = .degrees(a0.degrees + 1.5) }
            var arc = Path()
            arc.addArc(center: center, radius: ring, startAngle: a0, endAngle: a1, clockwise: false)
            ctx.stroke(arc, with: .color(Palette.shu.opacity(pulse)), style: StrokeStyle(lineWidth: width * 0.8, lineCap: .butt))
        }

        // 印 (外周の点)。近い時刻の印は重ならないよう、まとまりの中心から横に並べる。
        let markRadius = ring + width / 2 + side * 0.03
        let dotSize = side * 0.028
        let separation = Double(dotSize * 1.25 / markRadius) * 180 / .pi
        for group in markerGroups(separation: separation) {
            let mid = group.map { angle($0.at).degrees }.reduce(0, +) / Double(group.count)
            for (i, m) in group.enumerated() {
                let a = Angle.degrees(mid + (Double(i) - Double(group.count - 1) / 2) * separation)
                let p = point(center, markRadius, a)
                let dot = Path(ellipseIn: CGRect(x: p.x - dotSize / 2, y: p.y - dotSize / 2, width: dotSize, height: dotSize))
                ctx.fill(dot, with: .color(Palette.marker(m.kind)))
            }
        }

        // いまの時刻: 弧の太さに収まる短い針と、外側の小さな点
        if isToday {
            let a = angle(now)
            var hand = Path()
            hand.move(to: point(center, ring - width * 0.45, a))
            hand.addLine(to: point(center, ring + width * 0.45, a))
            ctx.stroke(hand, with: .color(Palette.ink), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
    }

    /// 横に並べたときに隣と間隔 (度) が取れないまとまりを、取れるまで合わせていく
    private func markerGroups(separation: Double) -> [[Marker]] {
        var groups = markers.sorted { $0.at < $1.at }.map { [$0] }
        func span(_ g: [Marker]) -> (lo: Double, hi: Double) {
            let mid = g.map { angle($0.at).degrees }.reduce(0, +) / Double(g.count)
            let half = Double(g.count - 1) / 2 * separation
            return (mid - half, mid + half)
        }
        var merged = true
        while merged {
            merged = false
            var i = 0
            while i + 1 < groups.count {
                if span(groups[i + 1]).lo - span(groups[i]).hi < separation {
                    groups[i] += groups.remove(at: i + 1)
                    merged = true
                } else {
                    i += 1
                }
            }
        }
        return groups
    }

    private func point(_ c: CGPoint, _ r: CGFloat, _ a: Angle) -> CGPoint {
        CGPoint(x: c.x + r * cos(a.radians), y: c.y + r * sin(a.radians))
    }

    private var accessibilitySummary: String {
        let total = conversations.reduce(0) { $0 + $1.meta.durationSeconds }
        return "\(day.journalTitle)。会話 \(conversations.count) 件、合計 \(spokenDuration(total))。印 \(markers.count) 個。"
    }
}

/// 受信している音声の強さ (Opus パケットの大きさから推定) を縦棒で表す。
struct VoiceMeter: View {
    let levels: [Double]
    var active: Bool

    var body: some View {
        Canvas { ctx, size in
            let n = max(levels.count, 1)
            let gap: CGFloat = 3
            let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            for (i, level) in levels.enumerated() {
                let h = max(3, size.height * CGFloat(level))
                let rect = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - h) / 2, width: w, height: h)
                let opacity = active ? 0.35 + 0.65 * Double(i) / Double(n) : 0.25
                ctx.fill(Path(roundedRect: rect, cornerRadius: w / 2),
                         with: .color((active ? Palette.shu : Palette.inkSoft).opacity(opacity)))
            }
        }
        .accessibilityHidden(true)
    }
}
