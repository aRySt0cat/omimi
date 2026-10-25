import Foundation
import OmiKit
import os

/// BLE の音声 notification → フレーム組み立て → セグメントファイル。
/// `queue` (OmiDeviceManager.queue) 上からだけ呼ぶ。
final class RecordingPipeline: @unchecked Sendable {
    struct Progress: Sendable {
        var segmentID: String?
        var segmentStartedAt: Date?
        var segmentSeconds: Double
        var maxSegmentSeconds: Double
        var streamStartedAt: Date?
        /// 最後に音声フレームを受信した時刻 (無音でマイクが休止すると更新されない)
        var lastFrameAt: Date?
        var stats: AudioPacketAssembler.Stats
    }

    /// これだけ無音 (フレームなし) が続いたらセグメントを閉じて文字起こしへ回す
    static let splitAfterSilence: Double = 30

    private let log = Logger(subsystem: "omimi", category: "Recording")
    private let queue: DispatchQueue
    private let recorder: SegmentRecorder
    private var assembler = AudioPacketAssembler()
    private var context: SegmentRecorder.Context?
    private var streamStartedAt: Date?
    private var lastFrameAt: Date?
    private var lastProgress = Date.distantPast
    private var idleTimer: DispatchSourceTimer?

    // 音声の強さの目安 (画面表示用)。CELT の VBR はうるさいほどパケットが大きくなるので、その大きさから推定する。
    private var levelBytes = 0
    private var levelFrames = 0
    private var levelWindowStart = Date()
    private var levels = Array(repeating: 0.0, count: 36)
    /// 画面に表示している間だけ true (バックグラウンドでは計算しない)
    var levelsEnabled = false
    /// 0.1 秒ごとの強さ (0〜1) の履歴 (queue 上で呼ばれる)
    var onLevels: (([Double]) -> Void)?

    /// セグメントが閉じた (queue 上で呼ばれる)
    var onSegmentClosed: ((SegmentMetadata) -> Void)?
    /// 進捗 (1 秒に 1 回程度, queue 上で呼ばれる)
    var onProgress: ((Progress) -> Void)?
    var onError: ((Error) -> Void)?

    init(store: SegmentStore, queue: DispatchQueue) {
        recorder = SegmentRecorder(store: store)
        self.queue = queue
    }

    func streamStarted(_ info: StreamInfo) {
        assembler.resetStream()
        assembler.resetStats()
        assembler.maxFragmentPayload = info.maxPayload
        streamStartedAt = Date()
        lastFrameAt = nil
        context = SegmentRecorder.Context(
            deviceId: info.deviceID.uuidString, deviceName: info.deviceName, firmware: info.firmware,
            codec: info.codec, source: "live", maxSegmentSeconds: Prefs.segmentSeconds,
            transcribeOnDevice: Prefs.deviceTranscription,
            splitAfterSilence: Self.splitAfterSilence)
        startIdleTimer()
        log.info("stream started codec=\(info.codec.wireName) maxPayload=\(info.maxPayload)")
        report(force: true)
    }

    func handle(_ notification: Data) {
        guard let context else { return }
        do {
            let frames = assembler.push(notification)
            guard !frames.isEmpty else { return }
            lastFrameAt = Date()
            if levelsEnabled { updateLevels(frames) }
            for meta in try recorder.append(frames, context: context) {
                onSegmentClosed?(meta)
            }
        } catch {
            log.error("write failed: \(error.localizedDescription)")
            onError?(error)
        }
        report(force: false)
    }

    func streamEnded() {
        stopIdleTimer()
        guard let context else { return }
        do {
            _ = try recorder.append(assembler.flush(), context: context)
            if let meta = try recorder.close() { onSegmentClosed?(meta) }
        } catch {
            onError?(error)
        }
        log.info("stream ended \(String(describing: self.assembler.stats))")
        self.context = nil
        streamStartedAt = nil
        report(force: true)
    }

    /// 書きかけのページをディスクへ (バックグラウンド移行時)
    func flush() {
        try? recorder.flush()
    }

    /// 設定変更を反映する
    func reloadSettings() {
        context?.maxSegmentSeconds = Prefs.segmentSeconds
        context?.transcribeOnDevice = Prefs.deviceTranscription
    }

    var activeSegmentID: String? { recorder.current?.id }

    private func updateLevels(_ frames: [AudioFrame]) {
        for f in frames where !f.concealed {
            levelBytes += f.data.count
            levelFrames += 1
        }
        let now = Date()
        guard now.timeIntervalSince(levelWindowStart) >= 0.1, levelFrames > 0 else { return }
        let average = Double(levelBytes) / Double(levelFrames)
        levels.removeFirst()
        levels.append(min(1, max(0, (average - 24) / 110)))
        levelBytes = 0
        levelFrames = 0
        levelWindowStart = now
        onLevels?(levels)
    }

    /// 現在のセグメントをここで区切る (ボタンの「区切り」)。次の音声から新しいセグメントになる。
    func split() {
        do {
            if let meta = try recorder.close() {
                log.info("split segment \(meta.id) by button")
                onSegmentClosed?(meta)
            }
        } catch {
            onError?(error)
        }
        report(force: true)
    }

    /// Omi は無音が 10 秒続くとマイクを休止して送信を止める。
    /// 無音が続いたら現在のセグメントを閉じ、すぐ文字起こしできるようにする。
    private func startIdleTimer() {
        stopIdleTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.checkIdle() }
        timer.resume()
        idleTimer = timer
    }

    private func stopIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    private func checkIdle() {
        do {
            if let meta = try recorder.closeIfIdle(after: Self.splitAfterSilence) {
                log.info("closed idle segment \(meta.id)")
                onSegmentClosed?(meta)
            }
        } catch {
            onError?(error)
        }
        report(force: true)
    }

    private func report(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastProgress) >= 1 else { return }
        lastProgress = now
        onProgress?(Progress(segmentID: recorder.current?.id, segmentStartedAt: recorder.current?.startedAt,
                             segmentSeconds: recorder.currentDuration,
                             maxSegmentSeconds: context?.maxSegmentSeconds ?? Prefs.segmentSeconds,
                             streamStartedAt: streamStartedAt, lastFrameAt: lastFrameAt,
                             stats: assembler.stats))
    }
}
