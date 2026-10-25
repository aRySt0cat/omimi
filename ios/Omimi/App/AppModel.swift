import BackgroundTasks
import Foundation
import Observation
import OmiKit
import os

/// アプリ全体の状態と各コンポーネントの配線。
@MainActor @Observable
final class AppModel {
    static let backlogTaskIdentifier = (Bundle.main.bundleIdentifier ?? "local.omimi.app") + ".backlog"

    let settings = AppSettings()
    let store: SegmentStore
    @ObservationIgnored let markerStore: MarkerStore
    @ObservationIgnored private let buttons = ButtonHandler()
    @ObservationIgnored let device: OmiDeviceManager
    @ObservationIgnored let pipeline: RecordingPipeline
    @ObservationIgnored let transcription: TranscriptionQueue
    @ObservationIgnored let speakerQueue: SpeakerQueue
    @ObservationIgnored let notesStore: NotesStore
    @ObservationIgnored private let log = Logger(subsystem: "omimi", category: "App")

    var linkState: DeviceLinkState = .idle
    var discovered: [DiscoveredDevice] = []
    var battery: Int?
    /// 本体のランプの明るさとマイクの感度 (読めたら)
    var deviceLED: Int?
    var deviceMicGain: Int?
    /// バッテリー残量の記録 (減り方を求める)
    var batteryLog: BatteryLog = {
        guard let data = Prefs.defaults.data(forKey: "batteryLog"),
              let log = try? JSONDecoder.omi.decode(BatteryLog.self, from: data) else { return BatteryLog() }
        return log
    }()
    var stream: StreamInfo?
    var mtu: Int?
    var progress: RecordingPipeline.Progress?
    var segments: [SegmentMetadata] = []
    var transcribingID: String?
    /// iPhone で話者分離している録音
    var diarizingID: String?
    /// 名前を当てるのに使う学習した声 (iPhone で直した・付けた名前から学習する)
    var voiceLibrary: VoiceLibrary? = AppModel.loadVoiceLibrary()
    var modelState: TranscriptionQueue.ModelState = .unknown
    var lastError: String?
    var markers: [Marker] = []
    /// 受信中の音声の強さ (0〜1)
    var levels: [Double] = Array(repeating: 0, count: 36)
    /// 最後に受け付けたボタン操作 (画面で確認できるように)
    var lastMarker: Marker?
    /// AI が書いたまとめ・ノート
    var notes: [NoteSummary] = []
    /// 名前のある人 (「話者と声の学習」に出す)
    var people: [Person] = []
    /// 学習し直しを待っている (話者を直した直後)
    var speakerTrainingPending = false
    @ObservationIgnored var retrainTask: Task<Void, Never>?
    @ObservationIgnored let clipPlayer = ClipPlayer()
    /// 用語集
    var vocabulary: [VocabularyEntry] = AppModel.loadVocabulary()
    /// 「AI で整理」: ChatGPT の接続・モデル・指示・進み具合
    var aiMessage: String?
    var connectingChatGPT = false
    var aiAccount: ChatGPTCredentials?
    var aiModels: [ChatGPTModel] = []
    var aiModelSelected: String? = Prefs.defaults.string(forKey: "directAIModel")
    var aiJob = AIJob()
    var prompts: [AIPrompt] = []
    var promptSelected: String? = Prefs.defaults.string(forKey: "aiPrompt")
    @ObservationIgnored let chatGPT = ChatGPTDirect(store: ChatGPTKeychain())
    @ObservationIgnored let promptStore = AIPromptStore(url: URL.applicationSupportDirectory.appendingPathComponent("prompts.json"))

    @ObservationIgnored private var refreshScheduled = false

    init() {
        let dir = URL.applicationSupportDirectory.appendingPathComponent("Segments", isDirectory: true)
        // ロック中も録音を書き込めるよう「初回ロック解除後」まで保護する。iCloud バックアップからは除外。
        let store: SegmentStore
        do {
            store = try SegmentStore(directory: dir,
                                     fileAttributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                     excludeFromBackup: true)
        } catch {
            fatalError("cannot create storage: \(error)")
        }
        self.store = store
        store.recoverInterrupted()
        markerStore = MarkerStore(url: URL.applicationSupportDirectory.appendingPathComponent("markers.json"))
        do {
            notesStore = try NotesStore(directory: URL.applicationSupportDirectory.appendingPathComponent("Notes", isDirectory: true),
                                        fileAttributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                        excludeFromBackup: true)
        } catch {
            fatalError("cannot create notes storage: \(error)")
        }

        transcription = TranscriptionQueue(store: store)
        speakerQueue = SpeakerQueue(store: store)
        device = OmiDeviceManager(targetID: Prefs.savedDeviceID, wantsAudio: Prefs.recordingEnabled)
        pipeline = RecordingPipeline(store: store, queue: device.queue)
        wire()
        refreshSegments()
        markers = markerStore.all()
        notes = notesStore.all()
        prompts = promptStore.all()
        Self.removeLegacyServerSettings()
    }

    private func wire() {
        let pipeline = self.pipeline
        device.onAudio = { data in pipeline.handle(data) }
        device.onStreamStart = { [weak self] info in
            pipeline.streamStarted(info)
            Task { @MainActor in
                self?.stream = info
                Prefs.defaults.set(info.deviceName, forKey: PrefKey.savedDeviceName)
            }
        }
        device.onStreamEnd = { [weak self] in
            pipeline.streamEnded()
            Task { @MainActor in self?.stream = nil }
        }
        device.onState = { [weak self] state in Task { @MainActor in self?.linkState = state } }
        device.onBattery = { [weak self] level in
            Task { @MainActor in
                guard let self else { return }
                self.battery = level
                self.batteryLog.record(level)
                if let data = try? JSONEncoder.omi.encode(self.batteryLog) { Prefs.defaults.set(data, forKey: "batteryLog") }
            }
        }
        device.onLinkInfo = { [weak self] mtu in Task { @MainActor in self?.mtu = mtu } }
        device.onDeviceSettings = { [weak self] led, gain in
            Task { @MainActor in
                self?.deviceLED = led
                self?.deviceMicGain = gain
            }
        }
        let device = self.device, markerStore = self.markerStore, buttons = self.buttons
        device.onButton = { [weak self] event in
            // BLE のキュー上で呼ばれる
            let now = Date()
            guard let kind = buttons.decode(event, at: now) else { return }
            if kind == .split { pipeline.split() }
            device.vibrate(Self.hapticPattern(for: kind))
            let marker = Marker(kind: kind, at: now, deviceId: Prefs.savedDeviceID?.uuidString)
            markerStore.add(marker)
            Task { @MainActor in self?.lastMarker = marker }
        }
        markerStore.observe { [weak self] in Task { @MainActor in self?.markers = markerStore.all() } }
        device.onDiscover = { [weak self] d in
            Task { @MainActor in
                guard let self else { return }
                if let i = self.discovered.firstIndex(where: { $0.id == d.id }) {
                    self.discovered[i] = d
                } else {
                    self.discovered.append(d)
                }
            }
        }

        pipeline.onProgress = { [weak self] p in Task { @MainActor in self?.progress = p } }
        pipeline.onLevels = { [weak self] l in Task { @MainActor in self?.levels = l } }
        pipeline.onError = { [weak self] e in Task { @MainActor in self?.lastError = "録音の保存に失敗: \(e.localizedDescription)" } }
        pipeline.onSegmentClosed = { [weak self] _ in
            Task { @MainActor in self?.transcription.kick() }
        }

        store.observe { [weak self] _ in Task { @MainActor in self?.scheduleRefresh() } }
        transcription.onChange = { [weak self] in
            guard let self else { return }
            transcribingID = transcription.currentID
            modelState = transcription.modelState
        }
        transcription.onTranscribed = { [weak self] _ in self?.speakerQueue.kick() }
        speakerQueue.library = { [weak self] in self?.voiceLibrary }
        speakerQueue.onChange = { [weak self] in
            guard let self else { return }
            diarizingID = speakerQueue.currentID
        }
    }

    /// 受け付けたことを Omi の振動で知らせる (注目: 短く 1 回 / 区切り: 長めに 1 回 / メモ: 短く 2 回)
    nonisolated static func hapticPattern(for kind: Marker.Kind) -> [UInt8] {
        switch kind {
        case .highlight: return [1]
        case .split: return [2]
        case .memo: return [1, 1]
        }
    }

    // MARK: - ライフサイクル

    func didBecomeActive() {
        transcription.isAppActive = true
        speakerQueue.isAppActive = true
        let pipeline = self.pipeline
        device.queue.async { pipeline.levelsEnabled = true }
        Task { await transcription.refreshModelState() }
        transcription.kick()
        speakerQueue.kick()
        prepareVoices()
        Task { await refreshAI() }
    }

    func didEnterBackground() {
        transcription.isAppActive = false
        speakerQueue.appDidEnterBackground()
        let pipeline = self.pipeline
        device.queue.async {
            pipeline.flush()
            pipeline.levelsEnabled = false
        }
        scheduleBacklogTask()
    }

    /// 充電中に、未処理の文字起こしと話者の聞き分けをまとめて行う
    func scheduleBacklogTask() {
        let request = BGProcessingTaskRequest(identifier: Self.backlogTaskIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        do { try BGTaskScheduler.shared.submit(request) } catch { log.error("BG task submit: \(error.localizedDescription)") }
    }

    func handleBacklogTask(_ task: BGProcessingTask) {
        scheduleBacklogTask()
        let work = Task { @MainActor in
            await transcription.runToCompletion()
            await speakerQueue.runToCompletion()
            retrainVoices()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { [transcription, speakerQueue] in
            Task { @MainActor in
                transcription.cancel()
                speakerQueue.cancel()
            }
            work.cancel()
        }
    }

    // MARK: - デバイス

    func startScan() {
        discovered.removeAll()
        device.startScan()
    }

    func stopScan() {
        device.stopScan()
    }

    func select(_ d: DiscoveredDevice) {
        Prefs.defaults.set(d.id.uuidString, forKey: PrefKey.savedDeviceID)
        Prefs.defaults.set(d.name, forKey: PrefKey.savedDeviceName)
        device.connect(to: d.id, name: d.name)
    }

    func forgetDevice() {
        Prefs.defaults.removeObject(forKey: PrefKey.savedDeviceID)
        Prefs.defaults.removeObject(forKey: PrefKey.savedDeviceName)
        device.forget()
        battery = nil
        mtu = nil
    }

    var savedDeviceName: String? { Prefs.defaults.string(forKey: PrefKey.savedDeviceName) }
    var hasSavedDevice: Bool { Prefs.savedDeviceID != nil }

    func setRecording(_ enabled: Bool) {
        settings.recordingEnabled = enabled
        device.setAudioEnabled(enabled)
    }

    /// 録音関連の設定を変えたとき
    func settingsChanged() {
        let pipeline = self.pipeline
        device.queue.async { pipeline.reloadSettings() }
        device.applyDeviceSettings()
        transcription.kick()
    }

    // MARK: - セグメント

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            refreshScheduled = false
            refreshSegments()
        }
    }

    func refreshSegments() {
        segments = store.all()
    }

    func delete(_ id: String) {
        guard id != pipeline.activeSegmentID else { return }
        store.delete(id)
    }

    /// 録音をまとめて削除する (話し声のない録音の一括削除など)
    func deleteSegments(_ ids: [String]) {
        ids.filter { $0 != pipeline.activeSegmentID }.forEach { store.delete($0) }
    }

    /// アプリから印を付ける (Omi のボタンと同じ扱い)
    func addMarker(_ kind: Marker.Kind) {
        if kind == .split {
            let pipeline = self.pipeline
            device.queue.async { pipeline.split() }
        }
        let marker = Marker(kind: kind, at: Date(), deviceId: Prefs.savedDeviceID?.uuidString)
        markerStore.add(marker)
        lastMarker = marker
    }

    var days: [DayDigest] { DayDigest.build(segments: segments, markers: markers) }

    func deleteMarker(_ id: String) {
        markerStore.remove(id)
    }

    var pendingTranscriptions: Int { segments.filter { $0.state == .closed && $0.transcriptionState == .pending }.count }

    /// 録音の時間帯に入る印 (前後に少し余裕を持たせる)
    func markers(for meta: SegmentMetadata) -> [Marker] {
        let end = meta.endedAt ?? meta.startedAt.addingTimeInterval(meta.durationSeconds)
        return markers.filter { $0.at >= meta.startedAt.addingTimeInterval(-2) && $0.at <= end.addingTimeInterval(2) }
    }

    var storageBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: - 以前の版の後片付け

    /// 自宅サーバとつないでいたころの設定と接続のトークンを消す (このアプリはもうサーバと通信しない)
    static func removeLegacyServerSettings() {
        let d = Prefs.defaults
        guard !d.bool(forKey: "legacyServerRemoved") else { return }
        for key in ["serverURL", "pinnedCertSHA256", "uploadEnabled", "wifiOnly", "requestServerTranscription", "retentionDays",
                    "speakersCache", "notesSyncedAt", "aiPlace"] {
            d.removeObject(forKey: key)
        }
        Keychain.removeLegacyServerToken()
        for file in ["speaker-edits.json"] {
            try? FileManager.default.removeItem(at: URL.applicationSupportDirectory.appendingPathComponent(file))
        }
        d.set(true, forKey: "legacyServerRemoved")
    }
}

/// ボタン通知の解釈 (BLE のキューからだけ使う)
final class ButtonHandler: @unchecked Sendable {
    private var decoder = ButtonGestureDecoder()

    func decode(_ event: OmiButtonEvent, at now: Date) -> Marker.Kind? {
        decoder.decode(event, at: now)
    }
}
