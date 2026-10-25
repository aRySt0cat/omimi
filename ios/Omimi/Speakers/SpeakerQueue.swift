import Foundation
import OmiKit
import OmiSpeakers
import os

/// 文字起こしの済んだ録音を、iPhone の中で話者分離する (Core ML)。
/// 学習した声 (iPhone で直した・付けた名前から学習したもの) で名前を当て、文字起こしに付ける。
/// 以前に自宅サーバが話者を付けた録音は、その話者のままにする (声の特徴だけ取って学習に使う)。
@MainActor
final class SpeakerQueue {
    private let log = Logger(subsystem: "omimi", category: "Speakers")
    private let store: SegmentStore
    private var task: Task<Void, Never>?
    private var networks: SpeakerNetworks?
    private(set) var currentID: String?
    private(set) var lastError: String?
    /// 処理した録音の数と、かかった時間 (この起動の間)
    private(set) var processed = 0
    private(set) var audioSeconds = 0.0
    private(set) var busySeconds = 0.0

    /// 名前を当てるのに使う学習した声
    var library: () -> VoiceLibrary? = { nil }
    var onChange: (() -> Void)?
    /// アプリを開いているか。録音中のバックグラウンドでは重い処理をしない (録音が止められないように)
    /// (バックグラウンドで起動されたときは開いていない。開いたときに AppModel が true にする)
    var isAppActive = false
    /// 充電中のバックグラウンドの処理 (BGProcessingTask) の中か
    private var inBackgroundTask = false

    private var allowed: Bool { isAppActive || inBackgroundTask }

    init(store: SegmentStore) {
        self.store = store
    }

    var isRunning: Bool { task != nil }

    var pendingCount: Int { store.all().filter(\.needsDeviceSpeakers).count }

    func kick() {
        guard task == nil, Prefs.deviceSpeakers, allowed else { return }
        task = Task { [weak self] in
            await self?.drain()
            self?.task = nil
            self?.networks = nil  // 使い終わったらモデルを手放す (メモリ)
            self?.onChange?()
        }
        onChange?()
    }

    /// BGProcessingTask から (充電中): 終わるまで続ける
    func runToCompletion() async {
        inBackgroundTask = true
        defer { inBackgroundTask = false }
        if let task { await task.value } else { kick(); await task?.value }
    }

    /// アプリを離れたら止める (充電中の処理の中を除く)
    func appDidEnterBackground() {
        isAppActive = false
        if !inBackgroundTask { cancel() }
    }

    func cancel() {
        task?.cancel()
    }

    /// 新しい録音から (最近の会話に早く名前が付くように)
    private func next() -> SegmentMetadata? {
        store.all().first(where: \.needsDeviceSpeakers)
    }

    private func drain() async {
        while !Task.isCancelled, Prefs.deviceSpeakers, allowed, let meta = next() {
            currentID = meta.id
            onChange?()
            do {
                // モデルの読み込みは時間がかかるので、画面の処理を止めないよう裏で行う
                if networks == nil {
                    networks = try await Task.detached(priority: .utility) { try SpeakerNetworks.bundled() }.value
                }
                let analyzer = SpeakerAnalyzer(networks: networks!)
                let url = store.audioURL(for: meta)
                let settings = library()?.settings ?? VoiceLibrary.Settings()
                let work = Task.detached(priority: .utility) { () throws -> (DeviceSpeakers, Double) in
                    let audio = try Self.loadAudio(url)
                    return (try analyzer.analyze(audio, settings: settings), Double(audio.count) / 16_000)
                }
                let (result, seconds) = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                processed += 1
                audioSeconds += seconds
                busySeconds += result.processingSeconds
                apply(result, to: meta.id)
                log.info("speakers \(meta.id): \(result.turns.count) turns, \(result.voices.count) voices in \(result.processingSeconds, format: .fixed(precision: 1))s")
            } catch is CancellationError {
                break
            } catch {
                log.error("speakers failed \(meta.id): \(error.localizedDescription)")
                lastError = error.localizedDescription
                // 同じ録音で止まり続けないよう、空の結果を付けておく (話者は付けない)
                store.update(meta.id) {
                    $0.deviceSpeakers = DeviceSpeakers(engine: SpeakerAnalyzer.engine, turns: [], voices: [], utterances: [],
                                                       processingSeconds: 0)
                }
            }
        }
        currentID = nil
    }

    private func apply(_ result: DeviceSpeakers, to id: String) {
        let library = library()
        let matcher = VoiceMatcher(library: library)
        let decided = matcher.match(result)
        store.update(id) { m in
            var device = result
            device.appliedVersion = library?.version
            m.deviceSpeakers = device
            // 以前に自宅サーバが話者を付けた録音は、その話者のままにする
            guard !m.hasServerSpeakers, var t = m.transcript else { return }
            matcher.apply(decided, device: device, to: &t)
            m.transcript = t
            m.speakerSource = .device
        }
    }

    /// 学習した声が変わったら、iPhone で話者分離した録音の名前を付け直す (声の特徴は保存してあるので速い)
    func reapply() {
        let library = library()
        let matcher = VoiceMatcher(library: library)
        var changed = 0
        for meta in store.all() where meta.speakerSource != .server {
            guard let device = meta.deviceSpeakers, device.appliedVersion != library?.version, !device.turns.isEmpty else { continue }
            let decided = matcher.match(device)
            store.update(meta.id) { m in
                guard !m.hasServerSpeakers else { return }
                m.deviceSpeakers?.appliedVersion = library?.version
                if var t = m.transcript, matcher.apply(decided, device: device, to: &t) {
                    m.transcript = t
                    changed += 1
                }
                m.speakerSource = .device
            }
        }
        if changed > 0 { log.info("reapplied voices to \(changed) segments") }
    }

    /// Ogg Opus の録音を 16 kHz の -1〜1 に
    nonisolated static func loadAudio(_ url: URL) throws -> [Float] {
        let file = try OggOpusReader.read(url: url, verifyCRC: false)
        let rate = file.head.inputSampleRate == 0 ? 16_000 : Double(file.head.inputSampleRate)
        let samples = try OpusDecoder(sampleRate: rate).decodeSamples(file.packets)
        guard rate == 16_000 else { throw SpeakerNetworkError.badOutput("sample rate \(rate)") }
        return samples.map { Float($0) / 32768 }
    }
}
