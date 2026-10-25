import OmiKit
import SwiftUI

/// 用語集: 人名・専門用語など、文字起こしでよく間違う語 (iPhone に保存する)
struct VocabularyView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Editing?
    @State private var error: String?

    struct Editing: Identifiable {
        var entry: VocabularyEntry?
        var id: Int { entry?.id ?? -1 }
    }

    var body: some View {
        List {
            Section {
                Text("人名や専門用語など、文字起こしでよく間違う語を登録します。iPhone の文字起こしでヒントとして使い、「よく間違う表記」は表示と書き出しで正しい表記に直します。AI がまとめるときにも参考にします。")
                    .font(.footnote).foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).font(.footnote).foregroundStyle(Palette.shu) }
            }
            Section {
                ForEach(model.vocabulary) { e in
                    Button { editing = Editing(entry: e) } label: { row(e) }
                        .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    offsets.map { model.vocabulary[$0].id }.forEach(model.deleteVocabulary)
                }
                if model.vocabulary.isEmpty {
                    Text("まだ登録した用語はありません").foregroundStyle(Palette.inkSoft)
                }
            }
        }
        .paperBackground()
        .listRowBackground(Palette.surface)
        .navigationTitle("用語集")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = Editing(entry: nil) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("用語を追加")
            }
        }
        .sheet(item: $editing) { VocabularyEditor(entry: $0.entry) }
    }

    private func row(_ e: VocabularyEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(e.term).font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
                if let reading = e.reading { Text(reading).font(.caption).foregroundStyle(Palette.inkSoft) }
            }
            if !e.aliases.isEmpty {
                Text("よく間違う表記: " + e.aliases.joined(separator: "、")).font(.caption).foregroundStyle(Palette.inkSoft)
            }
            if let note = e.note { Text(note).font(.caption).foregroundStyle(Palette.inkSoft).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct VocabularyEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: VocabularyEntry?
    @State private var term = ""
    @State private var reading = ""
    @State private var aliases = ""
    @State private var note = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("正しい表記 (例: 下河内)", text: $term)
                    TextField("読み (例: しもがうち)", text: $reading)
                } footer: {
                    Text("読みがあると、AI が聞き間違いに気づきやすくなります。")
                }
                Section {
                    TextField("例: 霜河内、下川内", text: $aliases, axis: .vertical)
                } header: {
                    Text("よく間違う表記")
                } footer: {
                    Text("「、」で区切ります。表示するときに正しい表記に直します (2 文字以上のもの)。")
                }
                Section {
                    TextField("例: 会社の同僚。開発チーム", text: $note, axis: .vertical)
                } header: {
                    Text("説明")
                } footer: {
                    Text("AI がまとめるときに参考にします。")
                }
                if let error { Text(error).foregroundStyle(Palette.shu) }
            }
            .paperBackground()
            .navigationTitle(entry == nil ? "用語を追加" : "用語を直す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).disabled(term.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
            .onAppear {
                guard let entry else { return }
                term = entry.term
                reading = entry.reading ?? ""
                aliases = entry.aliases.joined(separator: "、")
                note = entry.note ?? ""
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        let trim = { (s: String) -> String? in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        guard let t = trim(term) else { return }
        do {
            try model.saveVocabulary(id: entry?.id, VocabularyInput(
                term: t, reading: trim(reading), aliases: VocabularyInput.splitAliases(aliases), note: trim(note)))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
