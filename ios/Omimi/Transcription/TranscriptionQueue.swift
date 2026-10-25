import Foundation
import OmiKit
import OmiTranscription
import os

/// 録音済みセグメントを 1 つずつ Apple の端末内音声認識で文字起こしする。
@MainActor
final class TranscriptionQueue {
    enum ModelState: Equatable {
        case unknown, unsupported, notInstalled, downloading(Double), installed, failed(String)
    }

    private let log = Logger(subsystem: "omimi", category: "Transcription")
    private let store: SegmentStore
    private var task: Task<Void, Never>?
    private(set) var modelState: ModelState = .unknown
    private(set) var currentID: String?

    var onChange: (() -> Void)?
    /// 1 件完了するごとに呼ぶ (話者の聞き分けを始める)
    var onTranscribed: ((SegmentMetadata) -> Void)?
    /// バックグラウンドでの失敗を「失敗」にせず保留へ戻すか
    var isAppActive = true

    init(store: SegmentStore) {
        self.store = store
    }

    var isRunning: Bool { task != nil }

    func refreshModelState() async {
        switch await AppleSpeechTranscriber.modelStatus(for: Prefs.locales) {
        case .installed: modelState = .installed
        case .notInstalled: modelState = .notInstalled
        case .downloading: modelState = .downloading(0)
        case .unsupported: modelState = .unsupported
        }
        onChange?()
    }

    /// 言語モデルを Apple からダウンロードする (音声は送信しない)
    func installModel() async {
        modelState = .downloading(0)
        onChange?()
        do {
            try await AppleSpeechTranscriber.installModel(for: Prefs.locales) { p in
                Task { @MainActor in
                    self.modelState = .downloading(p)
                    self.onChange?()
                }
            }
            modelState = .installed
        } catch {
            modelState = .failed(error.localizedDescription)
        }
        onChange?()
    }

    /// 保留中のセグメントを処理する。実行中なら何もしない。
    func kick() {
        guard task == nil, Prefs.deviceTranscription else { return }
        task = Task { [weak self] in
            await self?.drain()
            self?.task = nil
            self?.onChange?()
        }
    }

    /// BGProcessingTask から: 完了まで待つ
    func runToCompletion() async {
        if let task { await task.value } else { kick(); await task?.value }
    }

    func cancel() {
        task?.cancel()
    }

    func retryFailed() {
        for meta in store.all() where meta.transcriptionState == .failed {
            store.update(meta.id) { $0.transcriptionState = .pending; $0.transcriptionError = nil }
        }
        kick()
    }

    func retranscribe(_ id: String) {
        store.update(id) { $0.transcriptionState = .pending; $0.transcriptionError = nil }
        kick()
    }

    private func nextPending() -> SegmentMetadata? {
        // 古い順
        store.all().last { $0.state == .closed && $0.transcriptionState == .pending }
    }

    private func drain() async {
        let locales = Prefs.locales
        // 言語の設定が変わっていることがあるので毎回確認する (未導入なら Apple から取得)
        await refreshModelState()
        if modelState != .installed {
            if modelState == .notInstalled { await installModel() }
            guard modelState == .installed else {
                log.error("speech model unavailable: \(String(describing: self.modelState))")
                return
            }
        }
        while !Task.isCancelled, Prefs.deviceTranscription, let meta = nextPending() {
            currentID = meta.id
            onChange?()
            let url = store.audioURL(for: meta)
            do {
                let transcript = try await AppleSpeechTranscriber.transcribe(segmentURL: url, locales: locales,
                                                                             contextualStrings: Prefs.vocabularyTerms)
                if let updated = store.update(meta.id, {
                    $0.transcript = transcript
                    $0.transcriptionState = .done
                    $0.transcriptionError = nil
                }) {
                    onTranscribed?(updated)
                }
                log.info("transcribed \(meta.id): \(transcript.pieces.count) pieces")
            } catch is CancellationError {
                break
            } catch {
                log.error("transcription failed \(meta.id): \(error.localizedDescription)")
                if !isAppActive {
                    // バックグラウンドでは実行できない場合がある。前面復帰時/充電中に再試行する。
                    break
                }
                store.update(meta.id) {
                    $0.transcriptionState = .failed
                    $0.transcriptionError = error.localizedDescription
                }
            }
        }
        currentID = nil
    }
}
