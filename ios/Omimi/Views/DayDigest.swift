import Foundation
import OmiKit
import SwiftUI

/// 1 日分の録音と印を、画面で使う形にまとめたもの。
struct SpeakerShare: Identifiable, Hashable {
    var name: String?
    var speakerId: Int?
    var seconds: Double

    var id: String { isNamedSpeaker(name) ? speakerId.map { "id\($0)" } ?? name ?? "other" : "other" }
    var displayName: String { isNamedSpeaker(name) ? name ?? otherSpeakerName : otherSpeakerName }
    var color: Color { Palette.speaker(id: speakerId, name: name) }
}

struct Conversation: Identifiable {
    var meta: SegmentMetadata
    var markers: [Marker]

    var id: String { meta.id }
    var start: Date { meta.startedAt }
    var end: Date { meta.endedAt ?? meta.startedAt.addingTimeInterval(meta.durationSeconds) }
    var transcript: Transcript? { meta.serverTranscript ?? meta.transcript }

    /// 話者ごとの発話時間 (長い順)。名前のない人と話者不明は「その他」1 つにまとめる。話者分離がまだなら空。
    var shares: [SpeakerShare] {
        let pieces = transcript?.pieces ?? []
        guard pieces.contains(where: { $0.speaker != nil || $0.speakerId != nil }) else { return [] }
        var map: [String: SpeakerShare] = [:]
        for p in pieces {
            let named = isNamedSpeaker(p.speaker)
            let s = SpeakerShare(name: named ? p.speaker : otherSpeakerName, speakerId: named ? p.speakerId : nil, seconds: 0)
            map[s.id, default: s].seconds += max(0, p.end - p.start)
        }
        return map.values.sorted { $0.seconds > $1.seconds }
    }

    var dominantColor: Color { shares.first?.color ?? Palette.inkSoft }

    var preview: String {
        (transcript?.pieces ?? []).prefix(3).map(\.text).joined(separator: " ")
    }

    /// 主言語以外 (例: 英語) が含まれるか
    var languages: [String] {
        Array(Set((transcript?.pieces ?? []).compactMap(\.language))).sorted()
    }
}

enum TimelineItem: Identifiable {
    case conversation(Conversation)
    case marker(Marker)
    /// 長く何もなかった時間
    case quiet(from: Date, to: Date)

    var id: String {
        switch self {
        case .conversation(let c): "c-\(c.id)"
        case .marker(let m): "m-\(m.id)"
        case .quiet(let a, _): "q-\(a.timeIntervalSince1970)"
        }
    }

    var date: Date {
        switch self {
        case .conversation(let c): c.start
        case .marker(let m): m.at
        case .quiet(let a, _): a
        }
    }
}

struct DayDigest: Identifiable {
    var day: Date
    var conversations: [Conversation]
    /// 話し声のない録音 (物音だけ)
    var silent: [SegmentMetadata]
    /// どの会話にも入らない印 (マイク休止中に押したもの)
    var looseMarkers: [Marker]

    var id: Date { day }
    var talkSeconds: Double { conversations.reduce(0) { $0 + $1.meta.durationSeconds - ($1.meta.silenceFilledSeconds ?? 0) } }

    var speakers: [SpeakerShare] {
        var map: [String: SpeakerShare] = [:]
        for c in conversations {
            for s in c.shares { map[s.id, default: SpeakerShare(name: s.name, speakerId: s.speakerId, seconds: 0)].seconds += s.seconds }
        }
        return map.values.sorted { $0.seconds > $1.seconds }
    }

    var markers: [Marker] { (conversations.flatMap(\.markers) + looseMarkers).sorted { $0.at < $1.at } }

    /// 朝から夜へ。30 分以上何もない時間は「静かな時間」として 1 行にまとめる。
    var timeline: [TimelineItem] {
        let items = (conversations.map(TimelineItem.conversation) + looseMarkers.map(TimelineItem.marker))
            .sorted { $0.date < $1.date }
        var out: [TimelineItem] = []
        var lastEnd: Date?
        for item in items {
            if let lastEnd, item.date.timeIntervalSince(lastEnd) >= 30 * 60 {
                out.append(.quiet(from: lastEnd, to: item.date))
            }
            out.append(item)
            switch item {
            case .conversation(let c): lastEnd = max(lastEnd ?? c.end, c.end)
            case .marker(let m): lastEnd = max(lastEnd ?? m.at, m.at)
            case .quiet: break
            }
        }
        return out
    }

    static func build(segments: [SegmentMetadata], markers: [Marker], calendar: Calendar = .current) -> [DayDigest] {
        func markersIn(_ m: SegmentMetadata) -> [Marker] {
            let end = m.endedAt ?? m.startedAt.addingTimeInterval(m.durationSeconds)
            return markers.filter { $0.at >= m.startedAt.addingTimeInterval(-2) && $0.at <= end.addingTimeInterval(2) }
        }
        let speech = segments.filter { $0.hasSpeech != false }
        let covered = Set(speech.flatMap { markersIn($0).map(\.id) })
        let segsByDay = Dictionary(grouping: segments) { calendar.startOfDay(for: $0.startedAt) }
        let looseByDay = Dictionary(grouping: markers.filter { !covered.contains($0.id) }) { calendar.startOfDay(for: $0.at) }
        return Set(segsByDay.keys).union(looseByDay.keys).sorted(by: >).map { day in
            let items = segsByDay[day] ?? []
            return DayDigest(
                day: day,
                conversations: items.filter { $0.hasSpeech != false }.sorted { $0.startedAt < $1.startedAt }
                    .map { Conversation(meta: $0, markers: markersIn($0)) },
                silent: items.filter { $0.hasSpeech == false },
                looseMarkers: (looseByDay[day] ?? []).sorted { $0.at < $1.at })
        }
    }
}
