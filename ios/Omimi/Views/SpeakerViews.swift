import OmiKit
import SwiftUI

/// 発話を流すボタン (もう一度押すと止める)
struct PlayClipButton: View {
    @Environment(AppModel.self) private var model
    let segmentId: String
    let start: Double
    let end: Double

    private var key: String { "\(segmentId)@\(start)" }

    var body: some View {
        let player = model.clipPlayer
        Button {
            player.toggle(key: key) { [model, segmentId, start, end] in
                try await model.clipData(segmentId: segmentId, start: start, end: end)
            }
        } label: {
            ZStack {
                Circle().fill(player.playingKey == key ? Palette.shu : Palette.ink)
                if player.loadingKey == key {
                    ProgressView().tint(Palette.paper).controlSize(.small)
                } else {
                    Image(systemName: player.playingKey == key ? "stop.fill" : "play.fill")
                        .font(.caption.weight(.bold)).foregroundStyle(Palette.paper)
                }
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.playingKey == key ? "止める" : "発話を再生")
    }
}

// MARK: - 誰が話していますか

struct SpeakerPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let segmentId: String
    let recordingStart: Date
    let group: SpeechGroup
    @State private var scope = Scope.utterance
    @State private var newName = ""

    enum Scope: Hashable { case utterance, recording, voice }

    /// 名前のない声 (以前に自宅サーバが声として区別した「その他」)
    private var unnamedVoice: Bool { group.speakerId != nil && !isNamedSpeaker(group.speaker) }
    private var currentName: String { isNamedSpeaker(group.speaker) ? group.speaker ?? otherSpeakerName : otherSpeakerName }

    /// 選べるのは名前のある人だけ (話した時間の長い順)。名前のない人は「その他」にまとめる
    private var choices: [String] {
        var names = model.people.map(\.name)
        for name in model.voiceLibrary?.learnedNames ?? [] where !names.contains(name) { names.append(name) }
        if let current = group.speaker, isNamedSpeaker(current), !names.contains(current) { names.insert(current, at: 0) }
        return names
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 12) {
                        PlayClipButton(segmentId: segmentId, start: group.start, end: group.end)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(recordingStart.addingTimeInterval(group.start).hhmmss)　いまは「\(currentName)」")
                                .font(.caption).foregroundStyle(Palette.inkSoft)
                            Text(group.text).font(.subheadline).foregroundStyle(Palette.ink).lineLimit(4)
                        }
                    }
                    .padding(14)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Picker("直す範囲", selection: $scope) {
                            Text("この発話だけ").tag(Scope.utterance)
                            Text("この録音").tag(Scope.recording)
                            if unnamedVoice { Text("すべての録音").tag(Scope.voice) }
                        }
                        .pickerStyle(.segmented)
                        Group {
                            switch scope {
                            case .utterance: Text("この発話の話者だけを直します。")
                            case .recording: Text(unnamedVoice ? "この録音のこの声のところを、まとめて直します。"
                                                  : "この録音の「\(currentName)」のところを、まとめて直します。")
                            case .voice: Text("ほかの録音のこの声にも同じ名前が付きます。大事な人のときに使ってください。")
                            }
                        }
                        .font(.caption).foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionCaption(text: "話者")
                        FlowLayout(spacing: 8, lineSpacing: 8) {
                            ForEach(choices, id: \.self) { name in
                                Button { choose(.newName(name)) } label: {
                                    HStack(spacing: 6) {
                                        Circle().fill(Palette.speaker(id: nil, name: name)).frame(width: 9, height: 9)
                                        Text(name).font(.subheadline.weight(isCurrent(name) ? .bold : .regular))
                                    }
                                    .foregroundStyle(Palette.ink)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Palette.surface, in: Capsule())
                                    .overlay(Capsule().strokeBorder(isCurrent(name) ? Palette.ink : Palette.line,
                                                                    lineWidth: isCurrent(name) ? 1.5 : 1))
                                }
                                .buttonStyle(.plain)
                            }
                            // 店員・アナウンスなど、名前を付けない人
                            Button { choose(.unknown) } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(Palette.inkSoft.opacity(0.6)).frame(width: 9, height: 9)
                                    Text(otherSpeakerName).font(.subheadline.weight(isNamedSpeaker(group.speaker) ? .regular : .bold))
                                }
                                .foregroundStyle(Palette.ink)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Palette.surface, in: Capsule())
                                .overlay(Capsule().strokeBorder(isNamedSpeaker(group.speaker) ? Palette.line : Palette.ink,
                                                                lineWidth: isNamedSpeaker(group.speaker) ? 1 : 1.5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("店員やアナウンスなど、名前を付けない人にする")
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionCaption(text: "新しい人")
                        HStack(spacing: 8) {
                            TextField("名前", text: $newName)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(Palette.surface, in: Capsule())
                                .submitLabel(.done)
                                .onSubmit(submitName)
                            Button("この名前にする", action: submitName)
                                .buttonStyle(InkButtonStyle(prominent: true))
                                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    Text("名前を付けるのは大事な人だけで十分です。店員やアナウンスなどは「\(otherSpeakerName)」のままにしてください。直した話者で、この iPhone がその人の声を学習します。")
                        .font(.caption).foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .paperBackground()
            .navigationTitle("誰が話していますか")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .task { await model.refreshPeople() }
            .onDisappear { model.clipPlayer.stop() }
        }
        .presentationDetents([.medium, .large])
    }

    private func submitName() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if name == otherSpeakerName {
            choose(.unknown)
        } else {
            choose(.newName(name))
        }
    }

    private func isCurrent(_ name: String) -> Bool { group.speaker == name }

    /// 録音の中のその人すべて (ID がなく名前だけの人は名前で)
    static func recordingScope(_ group: SpeechGroup) -> SpeakerEdit.Scope {
        if let id = group.speakerId { return .speaker(from: id) }
        if let name = group.speaker, isNamedSpeaker(name) { return .named(name) }
        if let label = group.pieces.first?.speakerLabel { return .label(label) }
        return .speaker(from: nil)
    }

    private func choose(_ target: SpeakerTarget) {
        let edit: SpeakerEdit.Scope = switch scope {
        case .utterance: .range(start: group.start, end: group.end)
        case .recording: Self.recordingScope(group)
        case .voice: group.speakerId.map { .voice(id: $0) } ?? Self.recordingScope(group)
        }
        model.assignSpeaker(segmentId: segmentId, scope: edit, target: target)
        dismiss()
    }
}

// MARK: - 話者の一覧

struct SpeakersView: View {
    @Environment(AppModel.self) private var model
    @State private var loading = true

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.voiceLibraryDescription).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text(model.speakerTrainingPending ? "直した内容で、まもなく学習し直します。"
                         : "会話の中の話者名をタップして名前を付けたり直したりすると、この iPhone がその人の声を学習し、次からの録音で名前を当てます。人が直した発話は重く使います。")
                        .font(.footnote).foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("学習し直す") { model.retrainVoices() }
                        .buttonStyle(InkButtonStyle())
                        .padding(.top, 4)
                }
                .padding(.vertical, 6)
            }
            if !model.people.isEmpty {
                Section {
                    ForEach(model.people) { row($0) }
                } header: {
                    Text("名前のある人")
                } footer: {
                    Text("名前を付けるのは大事な人だけで十分です。そのほかの声 (店員・アナウンスなど) は「\(otherSpeakerName)」にまとめています。")
                }
            } else if !loading {
                Text("まだ名前のある人がいません。会話の中の「\(otherSpeakerName)」をタップすると、名前を付けられます。")
                    .foregroundStyle(Palette.inkSoft)
            }
        }
        .paperBackground()
        .listRowBackground(Palette.surface)
        .navigationTitle("話者")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refreshPeople() }
        .task {
            await model.refreshPeople()
            loading = false
        }
    }

    private func row(_ p: Person) -> some View {
        NavigationLink {
            SpeakerDetailView(name: p.name)
        } label: {
            HStack(spacing: 12) {
                Circle().fill(Palette.speaker(id: nil, name: p.name)).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).foregroundStyle(Palette.ink)
                    Text("\(spokenDuration(p.seconds))　発話 \(p.utterances)\(p.confirmed > 0 ? "　確認済み \(p.confirmed)" : "")\(p.learned ? "" : "　未学習")")
                        .font(.caption).foregroundStyle(Palette.inkSoft)
                }
                Spacer(minLength: 4)
                if p.suspicious > 0 {
                    Text("\(p.suspicious)").font(.caption.weight(.bold)).foregroundStyle(Palette.shu)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Palette.shu.opacity(0.12), in: Capsule())
                        .accessibilityLabel("確認したい発話 \(p.suspicious) 件")
                }
            }
        }
    }
}

// MARK: - 話者の発話の確認

struct SpeakerDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var filter = "suspicious"
    @State private var items: [PersonUtterance] = []
    @State private var loading = false
    @State private var newName = ""
    @State private var confirmRemove = false
    /// 直した発話 (一覧から消さずに、どう直したかを出す)
    @State private var done: [String: String] = [:]
    @State private var naming: PersonUtterance?
    @State private var otherName = ""

    private var person: Person? { model.people.first { $0.name == name } }
    /// 直す先は名前のある人だけ
    private var others: [String] { model.people.map(\.name).filter { $0 != name } }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Circle().fill(Palette.speaker(id: nil, name: name)).frame(width: 14, height: 14)
                        Text(name).font(Typeface.mincho(24)).foregroundStyle(Palette.ink)
                    }
                    HStack(spacing: 8) {
                        TextField("名前を変える", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(rename)
                        Button("変える", action: rename)
                            .buttonStyle(InkButtonStyle(prominent: true))
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newName == name)
                    }
                    Text(statusText).font(.footnote).foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("名前を外す (「\(otherSpeakerName)」にする)") { confirmRemove = true }
                        .font(.footnote).foregroundStyle(Palette.shu)
                }
                .padding(.vertical, 4)
                Picker("表示", selection: $filter) {
                    Text("確認したい \(person?.suspicious ?? 0)").tag("suspicious")
                    Text("すべて").tag("all")
                    Text("確認済み").tag("confirmed")
                }
                .pickerStyle(.segmented)
            }
            Section {
                if loading && items.isEmpty {
                    ProgressView()
                } else if items.isEmpty {
                    Text(filter == "suspicious" ? "その人らしくない発話は見つかっていません。"
                         : filter == "confirmed" ? "まだ確認した発話はありません。" : "発話がありません。")
                        .foregroundStyle(Palette.inkSoft)
                }
                ForEach(items.prefix(200)) { utteranceRow($0) }
                if items.count > 200 {
                    Text("ほか \(items.count - 200) 件").font(.footnote).foregroundStyle(Palette.inkSoft)
                }
            } footer: {
                if let message = model.clipPlayer.errorMessage { Text(message).foregroundStyle(Palette.shu) }
            }
        }
        .paperBackground()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: filter) { await load() }
        .refreshable { await load() }
        .onAppear { newName = name }
        .onDisappear { model.clipPlayer.stop() }
        .confirmationDialog("「\(name)」の名前を外します", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("名前を外す", role: .destructive) {
                model.renamePerson(name, to: nil)
                dismiss()
            }
        } message: {
            Text("すべての録音で、この人の発話を「\(otherSpeakerName)」にします。")
        }
        .alert("この発話の話者の名前", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("名前", text: $otherName)
            Button("この名前にする") {
                let trimmed = otherName.trimmingCharacters(in: .whitespaces)
                if let u = naming, !trimmed.isEmpty { fix(u, .newName(trimmed), label: "「\(trimmed)」に直しました") }
                otherName = ""
            }
            Button("やめる", role: .cancel) { otherName = "" }
        }
    }

    private var statusText: String {
        guard person?.learned == true else { return "次の学習でこの人の声を覚えます。" }
        return "声を学習済みです。その人らしさが線を下回る発話を「確認したい」に出します。再生して、違っていたら直してください。"
    }

    private func load() async {
        loading = true
        defer { loading = false }
        items = await model.utterances(of: name, filter: filter)
        done = [:]
    }

    private func rename() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != name, isNamedSpeaker(trimmed) else { return }
        model.renamePerson(name, to: trimmed)
        dismiss()
    }

    private func fix(_ u: PersonUtterance, _ target: SpeakerTarget, label: String) {
        model.fixUtterance(u, target: target)
        done[u.id] = label
    }

    private func utteranceRow(_ u: PersonUtterance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                PlayClipButton(segmentId: u.segmentId, start: u.start, end: u.end)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("\(u.at.relativeClock)　\(spokenDuration(u.end - u.start))")
                        if u.manual { Label("確認済み", systemImage: "checkmark").labelStyle(.titleAndIcon) }
                    }
                    .font(.caption).foregroundStyle(Palette.inkSoft)
                    Text(u.text.isEmpty ? "(文字起こしなし)" : u.text)
                        .font(.subheadline).foregroundStyle(u.text.isEmpty ? Palette.inkSoft : Palette.ink)
                        .lineLimit(4)
                    if let score = u.score, let review = u.review {
                        LikenessBar(score: score, threshold: review, low: u.suspicious)
                    }
                }
            }
            if let label = done[u.id] {
                Label(label, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Palette.marker(.memo))
            } else {
                HStack(spacing: 8) {
                    if !u.manual {
                        Button("この人で合っている") { fix(u, .confirm, label: "この人で合っていると記録しました") }
                    }
                    Menu("別の人に直す") {
                        ForEach(others, id: \.self) { other in
                            Button(other) { fix(u, .newName(other), label: "「\(other)」に直しました") }
                        }
                        Button("新しい名前…") { naming = u }
                    }
                    Button(otherSpeakerName) { fix(u, .unknown, label: "「\(otherSpeakerName)」にしました") }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Palette.ai)
            }
        }
        .padding(.vertical, 4)
    }
}

/// その人らしさ (線を下回ると朱)
private struct LikenessBar: View {
    let score: Double
    let threshold: Double
    let low: Bool

    var body: some View {
        let fill = min(1, max(0.04, (score - (threshold - 0.4)) / 0.6))
        HStack(spacing: 8) {
            Text("その人らしさ")
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.line)
                    Capsule().fill(low ? Palette.shu : Palette.marker(.memo)).frame(width: geo.size.width * fill)
                }
            }
            .frame(width: 90, height: 5)
            if low { Text("低い") }
        }
        .font(.caption2).foregroundStyle(Palette.inkSoft)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(low ? "その人らしさ 低い" : "その人らしさ 十分")
    }
}
