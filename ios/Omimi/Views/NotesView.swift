import OmiKit
import SwiftUI

/// 「まとめ」: AI (ChatGPT) に頼んで書いたまとめとノート
struct NotesView: View {
    @Environment(AppModel.self) private var model
    @State private var welcomeShown = false
    @State private var showWelcome = false
    @State private var deleting: NoteSummary?

    private var dayNotes: [NoteSummary] { model.notes.filter(\.isDay) }
    private var otherNotes: [NoteSummary] { model.notes.filter { !$0.isDay } }
    private var needsWelcome: Bool { model.aiAccount.map { $0.connected && !$0.welcomed } ?? false }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    AICard()
                    if model.notes.isEmpty {
                        emptyState
                    } else {
                        if !dayNotes.isEmpty { noteSection("日のまとめ", dayNotes) }
                        if !otherNotes.isEmpty { noteSection("ノート", otherNotes) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .paperBackground()
            .navigationTitle("まとめ")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: NoteLink.self) { NoteView(name: $0.name) }
            .refreshable { await model.refreshAI() }
            .task { await model.refreshAI() }
            .onChange(of: needsWelcome) { _, welcome in
                // はじめて接続したときに一度だけ案内を出す
                if welcome && !welcomeShown { showWelcome = true }
            }
            .sheet(isPresented: $showWelcome, onDismiss: {
                welcomeShown = true
                Task { await model.dismissAIWelcome() }
            }) {
                AIWelcomeSheet(usageURL: ChatGPTEndpoints.usage.absoluteString)
            }
            .confirmationDialog("「\(deleting?.title ?? "")」を削除します", isPresented: Binding(get: { deleting != nil },
                                                                                       set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    if let n = deleting { model.deleteNote(n.name) }
                    deleting = nil
                }
            }
        }
    }

    private func noteSection(_ title: String, _ notes: [NoteSummary]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionCaption(text: title).padding(.bottom, 4)
            ForEach(notes) { note in
                NavigationLink(value: NoteLink(name: note.name)) { NoteRow(note: note) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let text = model.noteText(note.name) {
                            ShareLink(item: text, subject: Text(note.title)) { Label("共有", systemImage: "square.and.arrow.up") }
                        }
                        Button("削除", systemImage: "trash", role: .destructive) { deleting = note }
                    }
                if note.id != notes.last?.id {
                    Rectangle().fill(Palette.line).frame(height: 1)
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            JournalHeading(text: "まだまとめがありません", size: 20)
            Text("上の「AI で整理」で ChatGPT に頼むと、その日の会話のまとめがここにできます。指示はいくつでも作って付け替えられます。")
                .font(.subheadline).foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// まとめへの移動先 (会話の ID と区別する)
struct NoteLink: Hashable {
    let name: String
}

private struct NoteRow: View {
    let note: NoteSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if note.isDay, let date = note.date {
                    Text(dayTitle(date)).font(Typeface.mincho(17)).foregroundStyle(Palette.ink)
                } else {
                    Text(note.title).font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                }
                if let summary = note.summary {
                    Text(summary).font(.subheadline).foregroundStyle(Palette.inkSoft).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkSoft)
                .padding(.top, 4)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

// MARK: - まとめを読む

struct NoteView: View {
    @Environment(AppModel.self) private var model
    let name: String
    @State private var openConversation: String?
    @State private var openNote: String?
    @State private var missingConversation = false

    private var summary: NoteSummary? { model.notes.first { $0.name == name } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let text = model.noteText(name) {
                    MarkdownView(source: text)
                    if let summary {
                        Text("AI が \(summary.updatedAt.relativeClock) に書きました")
                            .font(.caption).foregroundStyle(Palette.inkSoft)
                            .padding(.top, 28)
                    }
                } else {
                    Text("このまとめは見つかりません。削除された可能性があります。")
                        .foregroundStyle(Palette.inkSoft)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .paperBackground()
        .navigationTitle(summary?.isDay == true ? "まとめ" : (summary?.title ?? "まとめ"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.openURL, OpenURLAction(handler: open))
        .navigationDestination(item: $openConversation) { ConversationView(id: $0) }
        .navigationDestination(item: $openNote) { NoteView(name: $0) }
        .toolbar {
            if let text = model.noteText(name) {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: text, subject: Text(summary?.title ?? "まとめ")) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("共有")
                }
            }
        }
        .alert("この会話は iPhone にありません", isPresented: $missingConversation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("削除された録音です。")
        }
    }

    /// まとめの中のリンク: 会話 (omimi://segment/<id>) と、ほかのノート (todo.md など) はアプリの中で開く
    private func open(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == "omimi" {
            if url.host() == "segment", let id = url.pathComponents.last, id != "/" {
                if model.segments.contains(where: { $0.id == id }) {
                    openConversation = id
                } else {
                    missingConversation = true
                }
            }
            return .handled
        }
        if url.scheme == nil {
            let target = url.relativeString.replacingOccurrences(of: "./", with: "").removingPercentEncoding ?? url.relativeString
            if model.notes.contains(where: { $0.name == target }) {
                openNote = target
            }
            return .handled
        }
        return .systemAction
    }
}

// MARK: - Markdown の表示

struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(source: String) {
        blocks = Markdown.parse(source)
    }

    init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks.indices, id: \.self) { i in
                block(blocks[i], first: i == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func block(_ block: MarkdownBlock, first: Bool) -> some View {
        switch block {
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(level == 1 ? Typeface.mincho(26) : level == 2 ? Typeface.mincho(19) : .headline)
                .foregroundStyle(Palette.ink)
                .padding(.top, first || level == 1 ? 0 : 16)
                .fixedSize(horizontal: false, vertical: true)
        case let .paragraph(text):
            Text(Self.inline(text)).font(.body).foregroundStyle(Palette.ink).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        case let .quote(inner):
            HStack(alignment: .top, spacing: 12) {
                Capsule().fill(Palette.yamabuki).frame(width: 3)
                MarkdownView(blocks: inner)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .list(ordered, items):
            MarkdownList(ordered: ordered, items: items)
        case let .code(code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.footnote, design: .monospaced)).foregroundStyle(Palette.ink).padding(12)
            }
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case let .table(header, rows):
            // 画面の幅に収めて折り返す (横に流すと折り返した行の高さが合わない)
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(header.indices, id: \.self) { c in
                        Text(Self.inline(header[c])).font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkSoft)
                    }
                }
                Rectangle().fill(Palette.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { c in
                            Text(Self.inline(rows[r][c])).font(.subheadline).foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        case .rule:
            Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 8)
        }
    }

    /// 行の中の書式 (太字・斜体・コード・リンク)。会話へのリンクは小さな札のように見せる。
    static func inline(_ text: String) -> AttributedString {
        var a = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let links = a.runs.compactMap { run in run.link.map { (run.range, $0) } }
        for (range, url) in links {
            a[range].foregroundColor = Palette.ai
            if url.scheme == "omimi" {
                a[range].backgroundColor = Palette.ai.opacity(0.12)
                a[range].font = .body.monospacedDigit()
            }
        }
        let codes = a.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }.map(\.range)
        for range in codes {
            a[range].font = .system(.subheadline, design: .monospaced)
            a[range].backgroundColor = Palette.ink.opacity(0.06)
        }
        return a
    }
}

private struct MarkdownList: View {
    let ordered: Bool
    let items: [MarkdownListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(i, item)
                        Text(MarkdownView.inline(item.text))
                            .font(.body)
                            .foregroundStyle(item.checked == true ? Palette.inkSoft : Palette.ink)
                            .strikethrough(item.checked == true, color: Palette.inkSoft)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !item.children.isEmpty {
                        MarkdownList(ordered: false, items: item.children).padding(.leading, 22)
                    }
                }
            }
        }
    }

    @ViewBuilder private func marker(_ i: Int, _ item: MarkdownListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Palette.marker(.memo) : Palette.inkSoft)
                .accessibilityLabel(checked ? "済み" : "未完了")
        } else if ordered {
            Text("\(i + 1).").font(.body.monospacedDigit()).foregroundStyle(Palette.inkSoft).frame(minWidth: 18, alignment: .trailing)
        } else {
            Text("•").font(.body).foregroundStyle(Palette.inkSoft).frame(width: 12)
        }
    }
}

/// その日のまとめの札 (「記録」の日付の下に出す)
struct DayNoteCard: View {
    let note: NoteSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Label("AI のまとめ", systemImage: "sparkles")
                    .font(.caption.weight(.semibold)).foregroundStyle(Palette.ai)
                Text(note.summary ?? note.title)
                    .font(.subheadline).foregroundStyle(Palette.ink).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkSoft)
                .padding(.top, 2)
        }
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// `2026-10-10` → 「10月10日 (土)」
func dayTitle(_ iso: String) -> String {
    let parts = iso.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
          let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    else { return iso }
    let weekday = "日月火水木金土".map(String.init)[Calendar(identifier: .gregorian).component(.weekday, from: date) - 1]
    return "\(parts[1])月\(parts[2])日 (\(weekday))"
}

extension Date {
    /// 「19:11」(今日) / 「昨日 19:11」/ 「10/8 19:11」
    var relativeClock: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return hhmm }
        if cal.isDateInYesterday(self) { return "昨日 \(hhmm)" }
        return "\(cal.component(.month, from: self))/\(cal.component(.day, from: self)) \(hhmm)"
    }
}

// MARK: - AI で整理 (Sign in with ChatGPT)

/// ChatGPT のロゴ入りのボタンの中身
private struct ChatGPTMark: View {
    var size: CGFloat = 18
    var body: some View {
        Image("ChatGPTLogo").resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// この iPhone から ChatGPT に頼んで、その日 (時間帯) の会話をまとめる。指示は選んで付け替える
struct AICard: View {
    @Environment(AppModel.self) private var model
    @State private var day: String?
    @State private var useRange = false
    @State private var start = AICard.time(10 * 60)
    @State private var end = AICard.time(11 * 60)
    @State private var preview: AIRequest?
    @State private var request: AIRequest?
    @State private var confirmDisconnect = false

    private var selectedDay: String { day ?? model.aiJob.day ?? model.aiDefaultDay }

    /// 送る内容を作り直すきっかけ (指示・日・時間帯・録音が変わったとき)
    private struct RequestKey: Hashable {
        var prompt: AIPrompt?
        var day: String
        var range: TimeRange?
        var segments: Int
        var notes: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI で整理").font(Typeface.mincho(18)).foregroundStyle(Palette.ink)
                Spacer()
                NavigationLink {
                    PromptsView()
                } label: {
                    Label("指示", systemImage: "text.badge.star").font(.subheadline)
                }
                .tint(Palette.ai)
            }
            if let account = model.aiAccount, account.connected {
                connected(account)
            } else {
                signIn
            }
            if let message = model.aiMessage {
                Text(message).font(.footnote).foregroundStyle(Palette.shu).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .confirmationDialog("ChatGPT との接続を解除します", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("接続を解除", role: .destructive) { Task { await model.disconnectChatGPT() } }
        } message: {
            Text("もう一度使うときは「ChatGPT で続ける」から接続します。")
        }
        .sheet(item: Binding(get: { preview.map(PreviewItem.init) }, set: { if $0 == nil { preview = nil } })) { AIPreviewSheet(request: $0.request) }
        .onAppear { applyDefaultRange(model.selectedPrompt) }
        .task(id: RequestKey(prompt: model.selectedPrompt, day: selectedDay, range: range, segments: model.segments.count,
                             notes: model.notes.count)) {
            request = model.selectedPrompt.flatMap { model.aiRequest(prompt: $0, day: selectedDay, range: range) }
        }
        .onChange(of: model.selectedPrompt?.id) { applyDefaultRange(model.selectedPrompt) }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("この iPhone から ChatGPT に頼んで、その日の会話をまとめます。")
                .font(.subheadline).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await model.connectChatGPT() }
            } label: {
                HStack(spacing: 10) {
                    if model.connectingChatGPT { ProgressView().tint(.white).controlSize(.small) } else { ChatGPTMark() }
                    Text("ChatGPT で続ける").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Color.black, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.connectingChatGPT)
            Text("ChatGPT Plus または Pro が必要です。整理するときに、選んだ日の文字起こしがこの iPhone から OpenAI に送られます。接続の情報はこの iPhone (キーチェーン) にだけ保存します。")
                .font(.caption).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var range: TimeRange? {
        guard useRange else { return nil }
        let r = TimeRange(start: Self.minutes(start), end: Self.minutes(end))
        return r.isValid ? r : nil
    }

    @ViewBuilder private func connected(_ account: ChatGPTCredentials) -> some View {
        let job = model.aiJob
        let running = job.state == .running
        let defaultDay = model.aiDefaultDay
        let days = model.aiDays.contains(defaultDay) ? model.aiDays : [defaultDay] + model.aiDays
        let prompt = model.selectedPrompt
        HStack(spacing: 8) {
            ChatGPTMark(size: 15).foregroundStyle(Palette.ink)
            Text("ChatGPT プランを使用中").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink)
            Link("使用量を管理", destination: ChatGPTEndpoints.usage).font(.footnote)
        }
        if let email = account.email { Text(email).font(.caption).foregroundStyle(Palette.inkSoft) }

        VStack(alignment: .leading, spacing: 10) {
            Menu {
                Picker("指示", selection: Binding(get: { prompt?.id ?? "" }, set: { model.selectPrompt($0) })) {
                    ForEach(model.prompts) { Text($0.name).tag($0.id) }
                }
            } label: {
                Label(prompt?.name ?? "指示を選ぶ", systemImage: "text.quote").font(.subheadline.weight(.semibold))
            }
            HStack(spacing: 10) {
                Menu {
                    Picker("整理する日", selection: Binding(get: { selectedDay }, set: { day = $0 })) {
                        ForEach(days, id: \.self) { Text(AINotes.dayTitle($0)).tag($0) }
                    }
                } label: {
                    Label(AINotes.dayTitle(selectedDay), systemImage: "calendar").font(.subheadline)
                }
                if !model.aiModels.isEmpty {
                    Menu {
                        Picker("モデル", selection: Binding(get: { model.aiModelSlug ?? "" }, set: { model.setAIModel($0) })) {
                            ForEach(model.aiModels) { Text($0.displayName).tag($0.slug) }
                        }
                    } label: {
                        Label(model.aiModels.first { $0.slug == model.aiModelSlug }?.displayName ?? model.aiModels[0].displayName,
                              systemImage: "cpu").font(.subheadline)
                    }
                }
            }
            Toggle("時間帯を決める", isOn: $useRange).font(.subheadline)
            if useRange {
                HStack(spacing: 8) {
                    DatePicker("から", selection: $start, displayedComponents: .hourAndMinute).labelsHidden()
                    Text("〜").foregroundStyle(Palette.inkSoft)
                    DatePicker("まで", selection: $end, displayedComponents: .hourAndMinute).labelsHidden()
                }
                if range == nil {
                    Text("終わりの時刻は、始まりより後にしてください").font(.caption).foregroundStyle(Palette.shu)
                }
            }
        }
        .tint(Palette.ai)

        if let prompt {
            HStack(spacing: 8) {
                Text(request.map { "会話 \($0.timelineChars.formatted()) 文字を送ります" } ?? (useRange ? "この時間帯の記録がありません" : "この日の記録がありません"))
                    .font(.caption).foregroundStyle(Palette.inkSoft)
                if let request {
                    Button("送る内容を見る") { preview = request }.font(.caption)
                }
            }
            Text(outputNote(prompt, day: selectedDay)).font(.caption).foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Button(running ? "整理しています…" : "AI で整理する") {
                Task { await model.runAI(prompt: prompt, day: selectedDay, range: range) }
            }
            .buttonStyle(InkButtonStyle(prominent: true))
            .disabled(running || request == nil || (useRange && range == nil))
        }
        if running {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(job.phase ?? "整理しています")\(job.chars > 0 ? "… \(job.chars.formatted()) 文字" : "…")")
                    .font(.footnote).foregroundStyle(Palette.inkSoft)
            }
            Text("書き終わるまで、このアプリを開いたままにしてください。").font(.caption).foregroundStyle(Palette.inkSoft)
        } else if job.state == .done, let name = job.noteName {
            NavigationLink(value: NoteLink(name: name)) {
                Label("「\(job.promptName ?? "まとめ")」を書きました", systemImage: "checkmark.circle.fill").font(.footnote)
            }
            .tint(Palette.marker(.memo))
        } else if job.state == .failed {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.message ?? "整理できませんでした").font(.footnote).foregroundStyle(Palette.shu)
                    .fixedSize(horizontal: false, vertical: true)
                if job.code == "subscription_sharing_usage_limit_exceeded" {
                    Link("使用量を管理", destination: ChatGPTEndpoints.usage).font(.footnote)
                }
            }
        }
        Text("選んだ日 (時間帯) の文字起こしが、この iPhone から OpenAI に送られ、ChatGPT のプランが使われます。")
            .font(.caption).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
        Button("接続を解除") { confirmDisconnect = true }
            .font(.caption).foregroundStyle(Palette.inkSoft).disabled(running)
    }

    private func outputNote(_ prompt: AIPrompt, day: String) -> String {
        let place = prompt.output == .dayNote ? "その日のまとめ (\(AINotes.dayTitle(day)))" : "ノート「\(prompt.noteName(day: day, range: range).dropLast(3))」"
        return "\(place) に書きます" + (prompt.updatesTodo ? "。やることも書き直します" : "")
    }

    private func applyDefaultRange(_ prompt: AIPrompt?) {
        if let r = prompt?.defaultRange {
            useRange = true
            start = Self.time(r.start)
            end = Self.time(r.end)
        } else {
            useRange = false
        }
    }

    static func time(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: min(minutes / 60, 23), minute: minutes >= 1440 ? 59 : minutes % 60, second: 0, of: Date()) ?? Date()
    }

    static func minutes(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private struct PreviewItem: Identifiable {
        let request: AIRequest
        var id: String { request.noteName + String(request.materials.count) }
    }
}

/// ChatGPT に送る内容 (指示と添付) を確かめる
struct AIPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: AIRequest
    @State private var part = 0
    private static let limit = 30_000

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("中身", selection: $part) {
                    Text("指示").tag(0)
                    Text("添付").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()
                ScrollView {
                    let text = part == 0 ? request.instructions : request.materials
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text.count > Self.limit ? String(text.prefix(Self.limit)) : text)
                            .font(.footnote.monospaced()).foregroundStyle(Palette.ink)
                            .textSelection(.enabled)
                        if text.count > Self.limit {
                            Text("ほか \((text.count - Self.limit).formatted()) 文字").font(.caption).foregroundStyle(Palette.inkSoft)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 32)
                }
            }
            .paperBackground()
            .navigationTitle("送る内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}

/// はじめて接続したときに一度だけ出す案内
private struct AIWelcomeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let usageURL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ChatGPTMark(size: 28).foregroundStyle(Palette.ink)
            Text("ChatGPT のプランを使っています").font(Typeface.mincho(22)).foregroundStyle(Palette.ink)
            Text("AI で整理するときは、あなたの ChatGPT のプランが使われます。使用量は ChatGPT の設定で確かめたり、変えたりできます。整理する日の文字起こしは OpenAI に送られます。")
                .font(.subheadline).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let usageURL, let url = URL(string: usageURL) {
                    Link("使用量を管理", destination: url).buttonStyle(InkButtonStyle())
                }
                Spacer()
                Button("わかりました") { dismiss() }.buttonStyle(InkButtonStyle(prominent: true))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .presentationDetents([.medium])
        .presentationBackground(Palette.paper)
    }
}
