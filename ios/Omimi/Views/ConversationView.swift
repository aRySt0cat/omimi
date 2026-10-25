import OmiKit
import SwiftUI

/// 会話の詳細: 話者ごとにまとまった発言と、その間に押した印。
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: String
    /// 検索から開いたとき: その発話の先頭 (秒) と、強調する言葉
    var focus: Double?
    var highlight: [String] = []
    @State private var useDevice = false
    @State private var confirmDelete = false
    /// 話者を選んでいる発話
    @State private var picking: SpeechGroup?

    var body: some View {
        if let meta = model.segments.first(where: { $0.id == id }) {
            let conversation = Conversation(meta: meta, markers: model.markers(for: meta))
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(conversation)
                    if meta.serverTranscript != nil && meta.transcript != nil {
                        sourcePicker
                    }
                    transcriptBody(conversation)
                    details(meta)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 48)
            }
            .paperBackground()
            .task {
                guard let focus else { return }
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation { proxy.scrollTo("piece-\(focus)", anchor: .center) }
            }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { actions(meta) } }
            .sheet(item: $picking) { group in
                SpeakerPicker(segmentId: meta.id, recordingStart: meta.startedAt, group: group)
            }
            .confirmationDialog("この録音を削除します", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    model.delete(meta.id)
                    dismiss()
                }
            }
        } else {
            ContentUnavailableView("この録音は削除されました", systemImage: "trash").paperBackground()
        }
    }

    private func transcript(_ meta: SegmentMetadata) -> Transcript? {
        useDevice ? (meta.transcript ?? meta.serverTranscript) : (meta.serverTranscript ?? meta.transcript)
    }

    // MARK: - 見出し

    private func header(_ c: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(c.start.journalTitle).font(.footnote).foregroundStyle(Palette.inkSoft)
            JournalHeading(text: "\(c.start.hhmm) – \(c.end.hhmm)", size: 30)
            if !c.shares.isEmpty {
                ShareBar(shares: c.shares)
                FlowLayout { ForEach(c.shares) { SpeakerChip(share: $0) } }
            }
        }
        .padding(.top, 8)
    }

    private var sourcePicker: some View {
        Picker("文字起こし", selection: $useDevice) {
            Text("Whisper (以前の自宅サーバ)").tag(false)
            Text("iPhone").tag(true)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - 本文

    @ViewBuilder private func transcriptBody(_ c: Conversation) -> some View {
        let meta = c.meta
        if let t = transcript(meta), !t.pieces.isEmpty {
            TranscriptFlow(pieces: t.pieces, markers: c.markers, start: c.start, onPickSpeaker: { picking = $0 },
                           highlight: highlight, focus: focus)
            VStack(alignment: .leading, spacing: 4) {
                Text(engineNote(t))
                Text("話者の名前をタップすると、誰の発話かを直せます")
            }
            .font(.caption).foregroundStyle(Palette.inkSoft)
        } else {
            Text(statusText(meta)).foregroundStyle(Palette.inkSoft)
            if let err = meta.transcriptionError { Text(err).font(.footnote).foregroundStyle(Palette.shu) }
        }
    }

    private func engineNote(_ t: Transcript) -> String {
        t.engine.hasPrefix("apple") ? "iPhone の音声認識で文字起こし" : "以前に自宅サーバの \(t.engine) で文字起こし"
    }

    private func statusText(_ meta: SegmentMetadata) -> String {
        switch meta.transcriptionState {
        case .pending: meta.state == .recording ? "録音中です" : "文字起こしを待っています"
        case .skipped: "端末での文字起こしはオフです"
        case .failed: "文字起こしに失敗しました"
        case .done: "言葉は聞き取れませんでした"
        }
    }

    // MARK: - 操作と情報

    private func actions(_ meta: SegmentMetadata) -> some View {
        Menu {
            if meta.state == .closed {
                Button("iPhone で文字起こしし直す", systemImage: "text.badge.plus") { model.transcription.retranscribe(meta.id) }
            }
            Divider()
            Button("削除", systemImage: "trash", role: .destructive) { confirmDelete = true }
                .disabled(meta.state == .recording)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func details(_ meta: SegmentMetadata) -> some View {
        DisclosureGroup("録音の情報") {
            VStack(alignment: .leading, spacing: 6) {
                info("長さ", formatDuration(meta.durationSeconds))
                if let s = meta.silenceFilledSeconds, s > 0 { info("うちマイク休止", formatDuration(s)) }
                if meta.concealedFrames > 0 { info("通信の欠け", "\(meta.concealedFrames) フレームを補完") }
            }
            .padding(.top, 8)
        }
        .font(.subheadline)
        .tint(Palette.inkSoft)
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Palette.inkSoft)
            Spacer()
            Text(value).foregroundStyle(Palette.ink)
        }
        .font(.footnote)
    }
}

/// 同じ人の続けての発言 (話者を選ぶ単位)
struct SpeechGroup: Identifiable {
    let speaker: String?
    let speakerId: Int?
    let pieces: [TranscriptPiece]
    var id: Double { start }
    var start: Double { pieces.first?.start ?? 0 }
    var end: Double { pieces.last?.end ?? 0 }
    var text: String { pieces.map(\.text).joined(separator: " ") }
    var manual: Bool { pieces.contains { $0.speakerManual == true } }
}

/// 1 人の続けての発言。左に話者の色の線。
struct SpeechBlock: View {
    let speaker: String?
    let speakerId: Int?
    let pieces: [TranscriptPiece]
    let start: Date
    var compact = false
    /// 話者分離が済んでいるか (済んでいなければ「話者不明」、済んでいれば名前のない人は「その他」)
    var diarized = true
    /// 話者名をタップしたとき (話者を選ぶ)
    var onPick: (() -> Void)?
    /// 検索した言葉 (文の中で強調する) と、検索で開いた発話の先頭
    var highlight: [String] = []
    var focus: Double?

    private var label: String {
        isNamedSpeaker(speaker) ? speaker ?? otherSpeakerName : (diarized ? otherSpeakerName : "話者不明")
    }

    var body: some View {
        let color = Palette.speaker(id: speakerId, name: speaker)
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let onPick {
                        Button(action: onPick) {
                            HStack(spacing: 4) {
                                Text(label).font(.footnote.weight(.bold))
                                if pieces.contains(where: { $0.speakerManual == true }) {
                                    Image(systemName: "checkmark").font(.caption2.weight(.bold))
                                        .accessibilityLabel("指定済み")
                                }
                                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).opacity(0.6)
                            }
                            .foregroundStyle(color)
                            .padding(.vertical, 6).padding(.trailing, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, -6)
                        .accessibilityHint("誰の発話かを直す")
                    } else {
                        Text(label).font(.footnote.weight(.bold)).foregroundStyle(color)
                    }
                    Text(start.addingTimeInterval(pieces[0].start).hhmmss)
                        .font(.caption.monospacedDigit()).foregroundStyle(Palette.inkSoft)
                    ForEach(Array(Set(pieces.compactMap(\.language).filter { $0 != "ja" })).sorted(), id: \.self) {
                        LanguageTag(code: $0)
                    }
                }
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, p in
                    Text(highlighted(p.text, highlight)).font(compact ? .subheadline : .body).foregroundStyle(Palette.ink)
                        .lineSpacing(compact ? 2 : 4)
                        .padding(.horizontal, p.start == focus ? 6 : 0)
                        .padding(.vertical, p.start == focus ? 3 : 0)
                        .background(p.start == focus ? Palette.yamabuki.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .id("piece-\(p.start)")
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 文字起こしの本文: 同じ人の続く発言をまとめ、印を時刻の位置に挟む。
struct TranscriptFlow: View {
    @Environment(AppModel.self) private var model
    let pieces: [TranscriptPiece]
    let markers: [Marker]
    let start: Date
    var compact = false
    /// 話者名をタップして話者を選ぶ (会話の画面だけ)
    var onPickSpeaker: ((SpeechGroup) -> Void)?
    /// 検索した言葉と、検索で開いた発話の先頭
    var highlight: [String] = []
    var focus: Double?

    private enum Line: Identifiable {
        case speech(speaker: String?, speakerId: Int?, pieces: [TranscriptPiece])
        case marker(Marker)

        var id: String {
            switch self {
            case .speech(_, _, let p): "s\(p.first?.start ?? 0)"
            case .marker(let m): m.id
            }
        }
    }

    private var diarized: Bool { pieces.contains { $0.speaker != nil || $0.speakerId != nil } }

    private var lines: [Line] {
        // 用語集の「よく間違う表記」を正しい表記に直して見せる (保存してある文字起こしは変えない)
        let corrector = model.vocabularyCorrector
        let pieces = corrector.isEmpty ? self.pieces : self.pieces.map { p in
            var q = p
            q.text = corrector.correct(p.text)
            return q
        }
        var events: [(Double, Line)] = markers.map { ($0.at.timeIntervalSince(start), .marker($0)) }
        var group: [TranscriptPiece] = []
        func flush() {
            if let first = group.first {
                events.append((first.start, .speech(speaker: first.speaker, speakerId: first.speakerId, pieces: group)))
            }
            group = []
        }
        for p in pieces {
            if let last = group.last, !last.sameSpeaker(as: p) || markers.contains(where: {
                let t = $0.at.timeIntervalSince(start)
                return t > last.start && t <= p.start
            }) {
                flush()
            }
            group.append(p)
        }
        flush()
        return events.sorted { $0.0 < $1.0 }.map(\.1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            ForEach(lines) { line in
                switch line {
                case let .speech(speaker, speakerId, pieces):
                    SpeechBlock(speaker: speaker, speakerId: speakerId, pieces: pieces, start: start, compact: compact,
                                diarized: diarized, onPick: onPickSpeaker.map { pick in
                                    { pick(SpeechGroup(speaker: speaker, speakerId: speakerId, pieces: pieces)) }
                                }, highlight: highlight, focus: focus)
                case let .marker(m):
                    HStack(spacing: 10) {
                        Rectangle().fill(Palette.marker(m.kind).opacity(0.35)).frame(height: 1)
                        MarkerLabel(kind: m.kind, size: 20).fixedSize()
                        Text(m.at.hhmmss).font(.caption.monospacedDigit()).foregroundStyle(Palette.inkSoft).fixedSize()
                        Rectangle().fill(Palette.marker(m.kind).opacity(0.35)).frame(height: 1)
                    }
                }
            }
        }
    }
}

/// 検索した言葉を強調した文
func highlighted(_ text: String, _ forms: [String]) -> AttributedString {
    var a = AttributedString(text)
    guard !forms.isEmpty else { return a }
    for r in TextSearch.ranges(of: forms, in: text) {
        guard let ar = Range(r, in: a) else { continue }
        a[ar].backgroundColor = Palette.yamabuki.opacity(0.3)
        a[ar].inlinePresentationIntent = .stronglyEmphasized
    }
    return a
}
