import AVFoundation
import Observation

/// 発話を確かめるための再生 (1 つずつ。もう一度押すと止める)
@MainActor @Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playingKey: String?
    private(set) var loadingKey: String?
    var errorMessage: String?
    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle(key: String, load: @escaping @MainActor () async throws -> Data) {
        if playingKey == key || loadingKey == key {
            stop()
            return
        }
        stop()
        loadingKey = key
        errorMessage = nil
        Task {
            do {
                let data = try await load()
                guard loadingKey == key else { return }
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true)
                let p = try AVAudioPlayer(data: data)
                p.delegate = self
                p.play()
                player = p
                playingKey = key
                loadingKey = nil
            } catch {
                if loadingKey == key { loadingKey = nil }
                errorMessage = "再生できませんでした (\(error.localizedDescription))"
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingKey = nil
        loadingKey = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
