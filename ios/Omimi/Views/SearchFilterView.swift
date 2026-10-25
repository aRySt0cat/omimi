import OmiKit
import SwiftUI

/// 検索の絞り込み (画面で選んだまま持つ。日付は「今日」のまま持ち、探すときに日付の範囲にする)
struct SearchFilter: Hashable {
    enum Language: String, CaseIterable, Identifiable {
        case all = "すべて", ja = "日本語", en = "英語"
        var id: String { rawValue }
        var code: String? {
            switch self {
            case .all: nil
            case .ja: "ja"
            case .en: "en"
            }
        }
    }

    enum Period: String, CaseIterable, Identifiable {
        case all = "すべて", today = "今日", yesterday = "昨日", week = "直近 7 日", month = "直近 30 日", custom = "期間を選ぶ"
        var id: String { rawValue }
    }

    enum TimeOfDay: String, CaseIterable, Identifiable {
        case all = "すべて", morning = "朝", daytime = "日中", evening = "夜", lateNight = "深夜", custom = "時間を選ぶ"
        var id: String { rawValue }

        /// 0:00 からの分
        var minutes: (start: Int, end: Int)? {
            switch self {
            case .morning: (5 * 60, 10 * 60)
            case .daytime: (10 * 60, 18 * 60)
            case .evening: (18 * 60, 24 * 60)
            case .lateNight: (0, 5 * 60)
            case .all, .custom: nil
            }
        }

        var title: String {
            minutes.map { "\(rawValue) \(TimeRange(start: $0.start, end: $0.end).label)" } ?? rawValue
        }
    }

    enum Kind: Hashable { case language, period, time, speaker }

    struct Chip: Identifiable {
        let kind: Kind
        let label: String
        let systemImage: String
        var id: Kind { kind }
    }

    var language = Language.all
    var period = Period.all
    var from = Calendar.current.startOfDay(for: Date())
    var to = Calendar.current.startOfDay(for: Date())
    var time = TimeOfDay.all
    var timeStart = 9 * 60
    var timeEnd = 12 * 60
    var speaker: String?

    var isActive: Bool { language != .all || period != .all || minutes != nil || speaker != nil }
    /// まとめにも当てはめられる条件だけか (まとめは日付でだけ絞れる)
    var fitsNotes: Bool { language == .all && minutes == nil && speaker == nil }

    /// 時間帯 (0:00 からの分)。終わりが始まりより前なら日をまたぐ
    var minutes: (start: Int, end: Int)? {
        guard time == .custom else { return time.minutes }
        return timeStart == timeEnd ? nil : (timeStart, timeEnd)
    }

    func interval(now: Date = Date()) -> DateInterval? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }
        switch period {
        case .all: return nil
        case .today: return DateInterval(start: today, end: day(1))
        case .yesterday: return DateInterval(start: day(-1), end: today)
        case .week: return DateInterval(start: day(-6), end: day(1))
        case .month: return DateInterval(start: day(-29), end: day(1))
        case .custom:
            let a = cal.startOfDay(for: min(from, to)), b = cal.startOfDay(for: max(from, to))
            return DateInterval(start: a, end: cal.date(byAdding: .day, value: 1, to: b)!)
        }
    }

    func make(now: Date = Date()) -> TextSearch.Filter {
        let m = minutes
        return TextSearch.Filter(language: language.code, interval: interval(now: now), timeStart: m?.start, timeEnd: m?.end, speaker: speaker)
    }

    var chips: [Chip] {
        var list: [Chip] = []
        if language != .all { list.append(Chip(kind: .language, label: language.rawValue, systemImage: "character.bubble")) }
        if period != .all { list.append(Chip(kind: .period, label: periodLabel, systemImage: "calendar")) }
        if let m = minutes {
            let range = TimeRange(start: m.start, end: m.end).label
            list.append(Chip(kind: .time, label: time == .custom ? range : "\(time.rawValue) \(range)", systemImage: "clock"))
        }
        if let speaker { list.append(Chip(kind: .speaker, label: speaker, systemImage: "person.fill")) }
        return list
    }

    mutating func clear(_ kind: Kind) {
        switch kind {
        case .language: language = .all
        case .period: period = .all
        case .time: time = .all
        case .speaker: speaker = nil
        }
    }

    private var periodLabel: String {
        guard period == .custom else { return period.rawValue }
        let a = min(from, to), b = max(from, to)
        let style = Date.FormatStyle(locale: Locale(identifier: "ja_JP")).month().day()
        if Calendar.current.isDate(a, inSameDayAs: b) { return a.formatted(style) }
        return "\(a.formatted(style))〜\(b.formatted(style))"
    }
}

/// 絞り込みを選ぶ
struct SearchFilterSheet: View {
    @Binding var filter: SearchFilter
    let people: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("言語", selection: $filter.language) {
                        ForEach(SearchFilter.Language.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: {
                    Text("言語")
                } footer: {
                    Text("言語の分からない発話は、日本語として扱います。")
                }

                Section("日付") {
                    Picker("日付", selection: $filter.period) {
                        ForEach(SearchFilter.Period.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if filter.period == .custom {
                        DatePicker("から", selection: $filter.from, in: ...Date(), displayedComponents: .date)
                        DatePicker("まで", selection: $filter.to, in: ...Date(), displayedComponents: .date)
                    }
                }

                Section {
                    Picker("時間帯", selection: $filter.time) {
                        ForEach(SearchFilter.TimeOfDay.allCases) { Text($0.title).tag($0) }
                    }
                    if filter.time == .custom {
                        DatePicker("から", selection: clock(\.timeStart), displayedComponents: .hourAndMinute)
                        DatePicker("まで", selection: clock(\.timeEnd), displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("時間帯")
                } footer: {
                    if filter.time == .custom {
                        Text("終わりを始まりより前にすると、日をまたぐ時間帯になります (例: 22:00〜2:00)。")
                    }
                }

                Section {
                    if people.isEmpty {
                        Text("名前の付いた人はまだいません").foregroundStyle(Palette.inkSoft)
                    } else {
                        Picker("話者", selection: $filter.speaker) {
                            Text("すべての人").tag(String?.none)
                            ForEach(people, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                    }
                } header: {
                    Text("話者")
                } footer: {
                    Text("まとめは日付でだけ絞り込めます。言語・時間帯・話者を選ぶと、会話だけを探します。")
                }
            }
            .paperBackground()
            .navigationTitle("絞り込み")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("すべて外す") { filter = SearchFilter() }
                        .disabled(!filter.isActive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// 0:00 からの分を、時刻を選ぶ部品に
    private func clock(_ key: WritableKeyPath<SearchFilter, Int>) -> Binding<Date> {
        Binding(get: { AICard.time(filter[keyPath: key]) }, set: { filter[keyPath: key] = AICard.minutes($0) })
    }
}
