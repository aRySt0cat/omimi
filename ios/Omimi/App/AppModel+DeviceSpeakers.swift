import Foundation
import OmiKit

/// iPhone での話者分離と、名前を当てるための学習した声
extension AppModel {
    static var voicesURL: URL { URL.applicationSupportDirectory.appendingPathComponent("voices.json") }

    static func loadVoiceLibrary() -> VoiceLibrary? {
        guard let data = try? Data(contentsOf: voicesURL) else { return nil }
        return try? JSONDecoder.omi.decode(VoiceLibrary.self, from: data)
    }

    func saveVoiceLibrary() {
        guard let library = voiceLibrary, let data = try? JSONEncoder.omi.encode(library) else {
            try? FileManager.default.removeItem(at: Self.voicesURL)
            return
        }
        try? data.write(to: Self.voicesURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// 起動したとき: 以前に自宅サーバから受け取った声なら、iPhone の記録で学習し直す
    func prepareVoices() {
        if voiceLibrary == nil || voiceLibrary?.source == "server" { retrainVoices() }
    }

    /// 直した・付けた名前から声を学習し直し、iPhone で話者分離した録音の名前を付け直す
    func retrainVoices() {
        let segments = store.all()
        Task.detached(priority: .utility) {
            let library = VoiceTrainer.train(segments: segments)
            await MainActor.run {
                self.voiceLibrary = library
                self.saveVoiceLibrary()
                self.speakerTrainingPending = false
                self.speakerQueue.reapply()
                Task { await self.refreshPeople() }
            }
        }
    }

    /// 設定画面に出す、iPhone の話者分離の状態
    var deviceSpeakerStatus: String {
        let pending = segments.filter(\.needsDeviceSpeakers).count
        if let id = diarizingID, let meta = store.get(id) {
            let f = DateFormatter()
            f.dateFormat = "H:mm"
            return "\(f.string(from: meta.startedAt)) の録音を処理中 (残り \(pending) 件)"
        }
        if pending > 0 { return "未処理 \(pending) 件 (充電中やアプリを開いているときに進みます)" }
        return "すべて処理済み"
    }

    /// この起動の間の処理の速さ (1 時間の録音あたり)
    var deviceSpeakerSpeed: String? {
        _ = diarizingID  // 処理が進むたびに表示を更新する
        guard speakerQueue.processed > 0, speakerQueue.audioSeconds > 60 else { return nil }
        let perHour = speakerQueue.busySeconds / speakerQueue.audioSeconds * 3600
        return perHour < 90 ? String(format: "1 時間の録音を約 %.0f 秒", perHour)
            : String(format: "1 時間の録音を約 %.1f 分", perHour / 60)
    }

    var voiceLibraryDescription: String {
        guard let library = voiceLibrary, library.source != "server" else { return "まだ学習していません" }
        let learned = library.learnedNames
        return learned.isEmpty ? "まだ学習していません" : "\(learned.joined(separator: "、")) の声を学習済み"
    }
}
