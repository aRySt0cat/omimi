import OmiKit
import SwiftUI

/// 会話とまとめを言葉で探す。ひらがな・カタカナ・全角・半角の違いは気にしなくてよい。かなは読みでも探す。
/// 言語・日付・時間帯・話者で絞り込める (言葉がなくても、条件だけで探せる)
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var scope = Scope.all
    @State private var filter = SearchFilter()
    @State private var showFilter = false
    @State private var result: Found?
    @State private var searching = false
    @AppStorage("recentSearches") private var recentRaw = ""

    enum Scope: Hashable { case all, conversations, notes }

    /// 会話を開く (その発話へ移り、言葉を強調する)
    struct Route: Hashable {
        var segmentId: String
        var start: Double
        var forms: [String]
    }

    struct Found {
        var query: TextSearch.Query
        /// 言葉なしで、条件だけで探した
        var browsing: Bool
        var hits: [TextSearch.Hit]
        var total: Int
        var notes: [TextSearch.NoteHit]
    }

    private struct Key: Hashable {
        var text: String
        var scope: Scope
        var filter: SearchFilter
        var segments: Int
        var notes: Int
    }

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }
    private var hasWords: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            List {
                if filter.isActive { chips }
                if !hasWords && !filter.isActive {
                    idle
                } else if let result {
                    results(result)
                } else if searching {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .paperBackground()
            .listRowBackground(Palette.surface)
            .navigationTitle("検索")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $text, prompt: "会話とまとめを探す")
            .searchScopes($scope) {
                Text("すべて").tag(Scope.all)
                Text("会話").tag(Scope.conversations)
                Text("まとめ").tag(Scope.notes)
            }
            .onSubmit(of: .search) { remember(text) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFilter = true
                    } label: {
                        Label("絞り込み", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityValue(filter.isActive ? filter.chips.map(\.label).joined(separator: "、") : "なし")
                }
            }
            .sheet(isPresented: $showFilter) {
                SearchFilterSheet(filter: $filter, people: model.people.map(\.name))
            }
            .task(id: Key(text: text, scope: scope, filter: filter, segments: model.segments.count, notes: model.notes.count)) {
                await run()
            }
            .task { await model.refreshPeople() }
            .navigationDestination(for: Route.self) { r in
                ConversationView(id: r.segmentId, focus: r.start, highlight: r.forms)
            }
            .navigationDestination(for: NoteLink.self) { NoteView(name: $0.name) }
        }
    }

    // MARK: - 探す前

    @ViewBuilder private var idle: some View {
        if !recent.isEmpty {
            Section {
                ForEach(recent, id: \.self) { word in
                    Button {
                        text = word
                    } label: {
                        Label(word, systemImage: "clock.arrow.circlepath").foregroundStyle(Palette.ink)
                    }
                }
                .onDelete { offsets in
                    var list = recent
                    list.remove(atOffsets: offsets)
                    recentRaw = list.joined(separator: "\n")
                }
            } header: {
                Text("最近探した言葉")
            }
        }
        Section {
            quick("今日の会話", systemImage: "sun.max") { $0.period = .today }
            quick("昨日の会話", systemImage: "calendar") { $0.period = .yesterday }
            quick("英語の発話", systemImage: "character.bubble") { $0.language = .en }
            Button {
                showFilter = true
            } label: {
                Label("条件を選ぶ", systemImage: "line.3.horizontal.decrease.circle").foregroundStyle(Palette.ink)
            }
        } header: {
            Text("条件で探す")
        }
        Section {
            Text("会話の文字起こしと、AI のまとめから探します。ひらがな・カタカナ・全角・半角の違いは気にしなくて構いません。かなで入れると、漢字の言葉も読みで探します (例: 「みつもり」で「見積もり」)。空白で区切ると、すべての言葉を含むものを探します。右上の絞り込みで、言語・日付・時間帯・話者を選べます。言葉を入れずに、条件だけでも探せます。")
                .font(.footnote).foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func quick(_ title: String, systemImage: String, _ apply: @escaping (inout SearchFilter) -> Void) -> some View {
        Button {
            apply(&filter)
        } label: {
            Label(title, systemImage: systemImage).foregroundStyle(Palette.ink)
        }
    }

    /// いまの条件。タップで外す
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filter.chips) { chip in
                    Button {
                        withAnimation(.snappy) { filter.clear(chip.kind) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: chip.systemImage).font(.caption)
                            Text(chip.label)
                            Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(Palette.inkSoft)
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Palette.ai.opacity(0.12)))
                        .overlay(Capsule().strokeBorder(Palette.ai.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(chip.label)、条件を外す")
                }
                if filter.chips.count > 1 {
                    Button("すべて外す") { withAnimation(.snappy) { filter = SearchFilter() } }
                        .font(.footnote).foregroundStyle(Palette.inkSoft)
                        .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    // MARK: - 結果

    @ViewBuilder private func results(_ r: Found) -> some View {
        let showNotes = scope != .conversations && filter.fitsNotes
        let showTalk = scope != .notes
        if (!showNotes || r.notes.isEmpty) && (!showTalk || r.hits.isEmpty) {
            Group {
                if scope == .notes && !filter.fitsNotes {
                    ContentUnavailableView("まとめは日付でだけ絞れます", systemImage: "doc.text.magnifyingglass",
                                           description: Text("言語・時間帯・話者の条件を外すか、「会話」から探してください。"))
                } else if r.browsing {
                    ContentUnavailableView("条件に合う発話はありません", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("条件を変えるか、外してみてください。"))
                } else {
                    ContentUnavailableView.search(text: text)
                }
            }
            .listRowBackground(Color.clear)
        }
        if showNotes && !r.notes.isEmpty {
            Section {
                ForEach(r.notes) { n in
                    NavigationLink(value: NoteLink(name: n.name)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(n.title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                            Text(highlighted(n.snippet, r.query.allForms)).font(.footnote).foregroundStyle(Palette.inkSoft).lineLimit(3)
                        }
                    }
                }
            } header: {
                Text("まとめ \(r.notes.count) 件")
            }
        }
        if showTalk && !r.hits.isEmpty {
            let days = Dictionary(grouping: r.hits) { AppModel.dayFormatter.string(from: $0.at) }
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                Section {
                    ForEach(days[day]!) { hit in
                        NavigationLink(value: Route(segmentId: hit.segmentId, start: hit.start, forms: r.query.allForms)) {
                            HitRow(hit: hit, forms: r.query.allForms)
                        }
                    }
                } header: {
                    Text("\(AINotes.dayTitle(day))　\(days[day]!.count) 件")
                }
            }
            if r.total > r.hits.count {
                Text("ほか \(r.total - r.hits.count) 件 (新しいものから \(r.hits.count) 件を出しています。言葉や条件を足すと絞り込めます)")
                    .font(.footnote).foregroundStyle(Palette.inkSoft)
            }
        }
    }

    private func run() async {
        let words = text.trimmingCharacters(in: .whitespaces)
        let filter = self.filter.make()
        guard !words.isEmpty || filter.isActive else {
            result = nil
            return
        }
        // 打っている間は少し待つ
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        let query = TextSearch.query(words, vocabulary: model.vocabulary)
        let segments = model.store.all(), corrector = model.vocabularyCorrector
        let notes = model.notes.compactMap { n in model.noteText(n.name).map { (summary: n, text: $0) } }
        let found = await Task.detached(priority: .userInitiated) {
            let talk = TextSearch.search(query, segments: segments, corrector: corrector, filter: filter)
            let notes = TextSearch.searchNotes(query, notes: notes, interval: filter.interval, timeZone: filter.timeZone)
            return Found(query: query, browsing: words.isEmpty, hits: talk.hits, total: talk.total, notes: notes)
        }.value
        guard !Task.isCancelled else { return }
        result = found
    }

    private func remember(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        recentRaw = ([w] + recent.filter { $0 != w }).prefix(10).joined(separator: "\n")
    }
}

/// 見つかった発話
private struct HitRow: View {
    let hit: TextSearch.Hit
    let forms: [String]

    var body: some View {
        let color = Palette.speaker(id: hit.speakerId, name: hit.speaker)
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(isNamedSpeaker(hit.speaker) ? hit.speaker ?? otherSpeakerName : otherSpeakerName)
                        .font(.caption.weight(.bold)).foregroundStyle(color)
                    Text(hit.at.hhmmss).font(.caption.monospacedDigit()).foregroundStyle(Palette.inkSoft)
                    if hit.byReading { tag("読みで一致") }
                    if hit.language == "en" { tag("英語") }
                }
                Text(highlighted(hit.text, forms)).font(.subheadline).foregroundStyle(Palette.ink).lineLimit(4)
            }
        }
        .padding(.vertical, 2)
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(Palette.inkSoft)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Palette.line))
    }
}
