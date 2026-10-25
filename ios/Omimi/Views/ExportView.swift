import OmiKit
import SwiftUI
import UIKit

/// 録音 (音声) と文字起こしを、期間を選んで書き出す。PC で分析するときに使う
struct ExportView: View {
    @Environment(AppModel.self) private var model
    @State private var period = Period.week
    @State private var from = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var includeSilent = false
    @State private var format = OmiExport.AudioFormat.opus
    @State private var working: AppModel.ExportKind?
    @State private var done = 0
    @State private var total = 0
    @State private var shared: SharedFile?
    @State private var error: String?

    enum Period: String, CaseIterable, Identifiable {
        case today = "今日", yesterday = "昨日", week = "直近 7 日", all = "すべて", custom = "期間を選ぶ"
        var id: String { rawValue }
    }

    struct SharedFile: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    private var interval: DateInterval? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }
        switch period {
        case .today: return DateInterval(start: today, end: day(1))
        case .yesterday: return DateInterval(start: day(-1), end: today)
        case .week: return DateInterval(start: day(-6), end: day(1))
        case .all: return nil
        case .custom:
            let a = cal.startOfDay(for: min(from, to)), b = cal.startOfDay(for: max(from, to))
            return DateInterval(start: a, end: cal.date(byAdding: .day, value: 1, to: b)!)
        }
    }

    private var label: String {
        let f = AppModel.dayFormatter
        guard let interval else {
            let days = model.segments.map(\.startedAt)
            guard let a = days.min(), let b = days.max() else { return "すべて" }
            return "\(f.string(from: a))〜\(f.string(from: b))"
        }
        let a = f.string(from: interval.start), b = f.string(from: interval.end.addingTimeInterval(-1))
        return a == b ? a : "\(a)〜\(b)"
    }

    var body: some View {
        let selected = model.exportSegments(interval: interval, includeSilent: includeSilent)
        let seconds = selected.reduce(0) { $0 + $1.durationSeconds }
        Form {
            Section {
                Picker("期間", selection: $period) {
                    ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                }
                if period == .custom {
                    DatePicker("から", selection: $from, displayedComponents: .date)
                    DatePicker("まで", selection: $to, displayedComponents: .date)
                }
                Toggle("話し声のない録音も含める", isOn: $includeSilent)
                LabeledContent("録音", value: "\(selected.count) 件・\(formatDuration(seconds))")
            } header: {
                Text("書き出す期間")
            }

            Section {
                Picker("形式", selection: $format) {
                    Text("そのまま (Ogg Opus)").tag(OmiExport.AudioFormat.opus)
                    Text("WAV (16 kHz)").tag(OmiExport.AudioFormat.wav)
                }
                LabeledContent("大きさの目安", value: ByteCountFormatter.string(fromByteCount: estimate(selected), countStyle: .file))
                exportButton(.audio(format), count: selected.count)
            } header: {
                Text("音声")
            } footer: {
                Text("日付ごとのフォルダに、録音 1 件ずつのファイルと、録音の一覧 (recordings.csv) を入れます。Ogg Opus は ffmpeg や VLC で扱えます。WAV は多くの分析の道具でそのまま読めますが、大きくなります (1 時間 約 115 MB)。")
            }

            Section {
                exportButton(.transcripts, count: selected.count)
            } header: {
                Text("文字起こし")
            } footer: {
                Text("発話ごとの表 (utterances.csv・Excel で開けます / utterances.jsonl)、録音ごとの字幕 (.srt。音声と同じファイル名)、日ごとの Markdown、印 (markers.csv) を入れます。話者・言語・時刻つきです。")
            }

            if let error {
                Section { Text(error).foregroundStyle(Palette.shu) }
            }
        }
        .paperBackground()
        .navigationTitle("書き出し")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shared) { ActivityView(items: [$0.url]) }
    }

    @ViewBuilder private func exportButton(_ kind: AppModel.ExportKind, count: Int) -> some View {
        if working == kind {
            HStack(spacing: 10) {
                ProgressView()
                Text(total > 1 ? "書き出しています… \(done)/\(total)" : "書き出しています…").foregroundStyle(Palette.inkSoft)
            }
        } else {
            Button("\(kind.title)を書き出す") { run(kind) }
                .disabled(count == 0 || working != nil)
        }
    }

    private func run(_ kind: AppModel.ExportKind) {
        working = kind
        error = nil
        done = 0
        total = 0
        Task {
            defer { working = nil }
            do {
                let url = try await model.export(kind, interval: interval, includeSilent: includeSilent, label: label) { d, t in
                    Task { @MainActor in
                        done = d
                        total = t
                    }
                }
                shared = SharedFile(url: url)
            } catch {
                self.error = "書き出せませんでした: \(error.localizedDescription)"
            }
        }
    }

    /// Opus はファイルの大きさ、WAV は 16 kHz × 16 bit
    private func estimate(_ segments: [SegmentMetadata]) -> Int64 {
        switch format {
        case .wav: return Int64(segments.reduce(0) { $0 + $1.durationSeconds } * 32_000)
        case .opus:
            return segments.reduce(Int64(0)) { sum, m in
                sum + Int64((try? model.store.audioURL(for: m).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
    }
}

/// 共有シート (AirDrop・「ファイル」に保存 など)
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
