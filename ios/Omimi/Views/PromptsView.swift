import OmiKit
import SwiftUI

/// 「AI で整理」の指示の一覧。いくつも作って、整理するときに選ぶ
struct PromptsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: AIPrompt?

    var body: some View {
        List {
            Section {
                ForEach(model.prompts) { p in
                    Button { editing = p } label: { row(p) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            if model.prompts.count > 1 {
                                Button("削除", role: .destructive) { model.deletePrompt(p.id) }
                            }
                            Button("複製") { editing = model.duplicatePrompt(p.id) }.tint(Palette.ai)
                        }
                }
                .onMove { model.movePrompts(from: $0, to: $1) }
            } footer: {
                Text("整理するときに、ここから指示を選びます。タップすると書き換えられます。左にスワイプで複製・削除、右上の「編集」で並べ替えます。")
            }
            if !model.removedBuiltInPrompts.isEmpty {
                Section("消した既定の指示") {
                    ForEach(model.removedBuiltInPrompts) { p in
                        Button("「\(p.name)」を戻す") { model.restorePrompt(p.id) }
                    }
                }
            }
        }
        .paperBackground()
        .listRowBackground(Palette.surface)
        .navigationTitle("AI への指示")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = Self.blank } label: { Image(systemName: "plus") }.accessibilityLabel("指示を作る")
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .sheet(item: $editing) { PromptEditor(prompt: $0) }
    }

    static var blank: AIPrompt {
        AIPrompt(name: "新しい指示", body: """
        # {{day_title}} {{range}}

        最初に `guide.md` を読み、添付の読み方と取り扱いの注意に従ってください。
        `{{timeline}}` の会話をもとに、`{{note}}` を書いてください。

        - (ここに、まとめ方・書式・言葉づかいなどを書く)
        - 推測で事実を足さないでください。
        """, output: .note, updatesTodo: false, attachPrevious: false)
    }

    private func row(_ p: AIPrompt) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: p.id == model.selectedPrompt?.id ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(p.id == model.selectedPrompt?.id ? Palette.ai : Palette.line)
                .onTapGesture { model.selectPrompt(p.id) }
                .accessibilityLabel(p.id == model.selectedPrompt?.id ? "使う指示" : "この指示を使う")
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(summary(p)).font(.caption).foregroundStyle(Palette.inkSoft)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkSoft)
        }
        .contentShape(Rectangle())
    }

    private func summary(_ p: AIPrompt) -> String {
        var parts = [p.output == .dayNote ? "その日のまとめ" : "ノート"]
        if let r = p.defaultRange { parts.append(r.label) }
        if p.updatesTodo { parts.append("やることを更新") }
        if p.attachPrevious { parts.append("前の日のまとめを添付") }
        return parts.joined(separator: "・")
    }
}

/// 指示を書き換える
struct PromptEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var prompt: AIPrompt
    @State private var useRange: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var confirmRestore = false

    init(prompt: AIPrompt) {
        _prompt = State(initialValue: prompt)
        _useRange = State(initialValue: prompt.defaultRange != nil)
        _start = State(initialValue: AICard.time(prompt.defaultRange?.start ?? 10 * 60))
        _end = State(initialValue: AICard.time(prompt.defaultRange?.end ?? 11 * 60))
    }

    private var isNew: Bool { !model.prompts.contains { $0.id == prompt.id } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名前 (例: 週次の定例)", text: $prompt.name)
                } header: {
                    Text("名前")
                }
                Section {
                    Picker("書くもの", selection: $prompt.output) {
                        Text("その日のまとめ").tag(AIPrompt.Output.dayNote)
                        Text("別のノート").tag(AIPrompt.Output.note)
                    }
                    Toggle("やること (todo) も書き直す", isOn: $prompt.updatesTodo)
                    Toggle("前の日のまとめを添付する", isOn: $prompt.attachPrevious)
                    Toggle("いつもの時間帯を決めておく", isOn: $useRange)
                    if useRange {
                        HStack {
                            DatePicker("から", selection: $start, displayedComponents: .hourAndMinute)
                            DatePicker("まで", selection: $end, displayedComponents: .hourAndMinute)
                        }
                    }
                } header: {
                    Text("書き方")
                } footer: {
                    Text(prompt.output == .dayNote
                         ? "その日のまとめは「記録」のその日の下にも出ます。同じ日にもう一度整理すると書き直します。"
                         : "ノートは「日付 時間帯 名前」で保存します。同じ日・時間帯でもう一度整理すると書き直します。時間帯は整理するときにも変えられます。")
                }
                Section {
                    TextEditor(text: $prompt.body)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 320)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("指示")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("次の言葉は、整理するときに置き換わります。")
                        ForEach(AIPrompts.placeholders, id: \.0) { key, meaning in
                            Text("\(key)  \(meaning)").font(.caption.monospaced())
                        }
                        Text("書いたものの形 (まとめの全文の区切り方) はアプリが付け足すので、指示に書かなくて構いません。")
                    }
                }
                Section {
                    if prompt.builtIn != nil {
                        Button("元の文面に戻す") { confirmRestore = true }
                    }
                    if !isNew && model.prompts.count > 1 {
                        Button("この指示を削除", role: .destructive) {
                            model.deletePrompt(prompt.id)
                            dismiss()
                        }
                    }
                }
            }
            .paperBackground()
            .navigationTitle(isNew ? "指示を作る" : "指示を書き換える")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(prompt.name.trimmingCharacters(in: .whitespaces).isEmpty || prompt.body.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("元の文面に戻します", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("元に戻す", role: .destructive) {
                    if let id = prompt.builtIn {
                        model.restorePrompt(id)
                        dismiss()
                    }
                }
            } message: {
                Text("書き換えた内容は消えます。")
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        var p = prompt
        p.name = p.name.trimmingCharacters(in: .whitespaces)
        p.defaultRange = useRange ? TimeRange(start: AICard.minutes(start), end: AICard.minutes(end)) : nil
        if p.defaultRange?.isValid == false { p.defaultRange = nil }
        let created = isNew
        model.savePrompt(p)
        if created { model.selectPrompt(p.id) }
        dismiss()
    }
}
