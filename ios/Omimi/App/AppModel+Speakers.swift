import Foundation
import OmiKit

/// 名前のある人 (iPhone の記録から数える)
struct Person: Identifiable, Hashable, Sendable {
    var name: String
    var seconds: Double = 0
    var utterances = 0
    var confirmed = 0
    var suspicious = 0
    var learned = false
    var lastSeen: Date?
    var id: String { name }
}

/// ある人の発話 (同じ人が続けて話したところ)
struct PersonUtterance: Identifiable, Hashable, Sendable {
    var segmentId: String
    var start: Double
    var end: Double
    var at: Date
    var text: String
    var manual: Bool
    /// その人らしさと、確認したい線 (学習した人で、声の特徴があるときだけ)
    var score: Double?
    var review: Double?
    var id: String { "\(segmentId)@\(start)" }
    var suspicious: Bool { !manual && score != nil && review != nil && score! < review! }
}

/// 話者の指定と、声の学習の確認 (すべて iPhone の中)
extension AppModel {
    /// 表示している文字起こし (以前に自宅サーバから受け取ったものがあればそれ)
    nonisolated static func displayTranscript(_ meta: SegmentMetadata) -> Transcript? {
        if let s = meta.serverTranscript, !s.pieces.isEmpty { return s }
        return meta.transcript
    }

    // MARK: - 話者を直す

    /// 話者を直す。文字起こしにすぐ反映し、少し待ってから声を学習し直す
    func assignSpeaker(segmentId: String, scope: SpeakerEdit.Scope, target: SpeakerTarget) {
        let edit = SpeakerEdit(segmentId: segmentId, scope: scope, target: target)
        // 声ごと決めたときは、ほかの録音のその声にも反映する
        let ids: [String] = if case let .voice(id) = scope { segmentIds(withSpeaker: id) } else { [segmentId] }
        for id in ids {
            store.update(id) { m in
                if var t = m.transcript, edit.apply(to: &t) { m.transcript = t }
                if var t = m.serverTranscript, edit.apply(to: &t) { m.serverTranscript = t }
            }
        }
        scheduleRetrain()
    }

    func segmentIds(withSpeaker id: Int) -> [String] {
        store.all().filter { m in
            [m.transcript, m.serverTranscript].contains { $0?.pieces.contains { $0.speakerId == id } == true }
        }.map(\.id)
    }

    /// 人の名前を変える (すべての録音)。ほかの人と同じ名前にすると、その人とまとめる。nil は名前を外す (「その他」)
    func renamePerson(_ old: String, to new: String?) {
        let target = new?.trimmingCharacters(in: .whitespaces)
        for meta in store.all() {
            func rename(_ t: Transcript?) -> Transcript? {
                guard var t else { return nil }
                for i in t.pieces.indices where t.pieces[i].speaker == old {
                    if let target, !target.isEmpty, isNamedSpeaker(target) {
                        t.pieces[i].speaker = target
                    } else {
                        t.pieces[i].speaker = otherSpeakerName
                        t.pieces[i].speakerId = nil
                    }
                }
                return t
            }
            let device = rename(meta.transcript), server = rename(meta.serverTranscript)
            if device != meta.transcript || server != meta.serverTranscript {
                store.update(meta.id) { m in
                    m.transcript = device
                    m.serverTranscript = server
                }
            }
        }
        scheduleRetrain(after: 0.5)
    }

    /// 直したあと少し待ってから学習し直す (続けて直す間は待つ)
    func scheduleRetrain(after seconds: Double = 3) {
        speakerTrainingPending = true
        retrainTask?.cancel()
        retrainTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.retrainVoices()
        }
    }

    // MARK: - 人の一覧・確認

    /// 名前のある人 (話した時間の長い順)。記録が多いので裏で数える
    func refreshPeople() async {
        let segments = store.all(), library = voiceLibrary
        people = await Task.detached(priority: .userInitiated) { Self.countPeople(segments, library: library) }.value
    }

    nonisolated static func countPeople(_ segments: [SegmentMetadata], library: VoiceLibrary?) -> [Person] {
        var people: [String: Person] = [:]
        let learned = Set(library?.learnedNames ?? [])
        for meta in segments {
            for u in utterances(of: meta, library: library) {
                var p = people[u.name] ?? Person(name: u.name, learned: learned.contains(u.name))
                p.seconds += u.utterance.end - u.utterance.start
                p.utterances += 1
                if u.utterance.manual { p.confirmed += 1 }
                if u.utterance.suspicious { p.suspicious += 1 }
                let at = u.utterance.at
                if p.lastSeen.map({ at > $0 }) ?? true { p.lastSeen = at }
                people[u.name] = p
            }
        }
        return people.values.sorted { $0.seconds > $1.seconds }
    }

    /// 録音の中の、名前のある人の発話 (同じ人が続けて話したところをまとめる)
    nonisolated static func utterances(of meta: SegmentMetadata, library: VoiceLibrary?) -> [(name: String, utterance: PersonUtterance)] {
        guard let t = displayTranscript(meta) else { return [] }
        var out: [(String, PersonUtterance)] = []
        var group: [TranscriptPiece] = []
        func flush() {
            guard let first = group.first, let name = first.speaker, isNamedSpeaker(name), let last = group.last else {
                group = []
                return
            }
            var u = PersonUtterance(segmentId: meta.id, start: first.start, end: last.end, at: meta.startedAt.addingTimeInterval(first.start),
                                    text: group.map(\.text).joined(separator: " "), manual: group.contains { $0.speakerManual == true })
            if let e = meta.deviceSpeakers?.embedding(for: u.start, u.end), let like = library?.likeness(e, name: name) {
                u.score = like.score
                u.review = like.review
            }
            out.append((name, u))
            group = []
        }
        for p in t.pieces {
            if let last = group.last, last.speaker != p.speaker || p.start - last.end > 2 { flush() }
            group.append(p)
        }
        flush()
        return out
    }

    /// ある人の発話 (確認したい = その人らしさが線を下回るもの、低い順)
    func utterances(of name: String, filter: String) async -> [PersonUtterance] {
        let segments = store.all(), library = voiceLibrary
        return await Task.detached(priority: .userInitiated) {
            let all = segments.flatMap { m in Self.utterances(of: m, library: library).filter { $0.name == name }.map(\.utterance) }
            switch filter {
            case "suspicious": return all.filter(\.suspicious).sorted { ($0.score ?? 0) < ($1.score ?? 0) }
            case "confirmed": return all.filter(\.manual).sorted { $0.at > $1.at }
            default: return all.sorted { $0.at > $1.at }
            }
        }.value
    }

    /// 発話の話者を直す・確認する
    func fixUtterance(_ u: PersonUtterance, target: SpeakerTarget) {
        assignSpeaker(segmentId: u.segmentId, scope: .range(start: u.start, end: u.end), target: target)
    }

    // MARK: - 発話の音声

    func clipData(segmentId: String, start: Double, end: Double) async throws -> Data {
        guard let meta = store.get(segmentId), meta.state == .closed else { throw CocoaError(.fileNoSuchFile) }
        let url = store.audioURL(for: meta)
        return try await Task.detached(priority: .userInitiated) {
            let file = try OggOpusReader.read(url: url, verifyCRC: false)
            let packets = OggClip.packets(file, from: max(0, start - 0.25), to: end + 0.25)
            let rate = file.head.inputSampleRate == 0 ? 16_000 : Int(file.head.inputSampleRate)
            let samples = try OpusDecoder(sampleRate: Double(rate)).decodeSamples(packets)
            return WAV.make(samples: samples, sampleRate: rate)
        }.value
    }
}
