import Foundation

/// 録音セグメントの保存場所。`<id>.opus` (音声) と `<id>.json` (メタデータ) をフラットに置く。
/// 複数スレッドから呼ばれるため内部でロックする。
public final class SegmentStore: @unchecked Sendable {
    public let directory: URL
    /// 新規ファイル作成時の属性 (iOS ではデータ保護クラスを指定する)
    public let fileAttributes: [FileAttributeKey: Any]?

    private let lock = NSLock()
    private var cache: [String: SegmentMetadata] = [:]
    private var observers: [UUID: @Sendable (SegmentMetadata?) -> Void] = [:]

    public init(directory: URL, fileAttributes: [FileAttributeKey: Any]? = nil, excludeFromBackup: Bool = true) throws {
        self.directory = directory
        self.fileAttributes = fileAttributes
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: fileAttributes)
        if excludeFromBackup {
            var dir = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        try reload()
    }

    public func reload() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var loaded: [String: SegmentMetadata] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let meta = try? JSONDecoder.omi.decode(SegmentMetadata.self, from: data) else { continue }
            loaded[meta.id] = meta
        }
        lock.withLock { cache = loaded }
    }

    public func audioURL(for meta: SegmentMetadata) -> URL {
        directory.appendingPathComponent(meta.audioFileName)
    }

    public func audioURL(id: String) -> URL? {
        get(id).map(audioURL(for:))
    }

    private func metadataURL(id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    public func get(_ id: String) -> SegmentMetadata? {
        lock.withLock { cache[id] }
    }

    /// 開始時刻の新しい順
    public func all() -> [SegmentMetadata] {
        lock.withLock { Array(cache.values) }.sorted { $0.startedAt > $1.startedAt }
    }

    public func save(_ meta: SegmentMetadata) throws {
        let data = try JSONEncoder.omi.encode(meta)
        try lock.withLock {
            let url = metadataURL(id: meta.id)
            if FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            } else {
                FileManager.default.createFile(atPath: url.path, contents: data, attributes: fileAttributes)
            }
            cache[meta.id] = meta
        }
        notify(meta)
    }

    /// 読み込み→変更→保存を原子的に行う。
    @discardableResult
    public func update(_ id: String, _ body: (inout SegmentMetadata) -> Void) -> SegmentMetadata? {
        let result: SegmentMetadata? = lock.withLock {
            guard var meta = cache[id] else { return nil }
            body(&meta)
            guard let data = try? JSONEncoder.omi.encode(meta),
                  (try? data.write(to: metadataURL(id: id), options: .atomic)) != nil else { return nil }
            cache[id] = meta
            return meta
        }
        if let result { notify(result) }
        return result
    }

    public func delete(_ id: String) {
        lock.withLock {
            if let meta = cache[id] {
                try? FileManager.default.removeItem(at: audioURL(for: meta))
            }
            try? FileManager.default.removeItem(at: metadataURL(id: id))
            cache[id] = nil
        }
        notify(nil)
    }

    /// アプリが録音中に終了した場合、`recording` のまま残ったセグメントを閉じる。
    /// 長さは Ogg ファイルから読み直す。
    @discardableResult
    public func recoverInterrupted(excluding activeID: String? = nil) -> [SegmentMetadata] {
        let stale = all().filter { $0.state == .recording && $0.id != activeID }
        var recovered: [SegmentMetadata] = []
        for meta in stale {
            let url = audioURL(for: meta)
            if let file = try? OggOpusReader.read(url: url, verifyCRC: false), !file.packets.isEmpty {
                let updated = update(meta.id) {
                    $0.state = .closed
                    $0.frameCount = file.packets.count
                    $0.durationSeconds = file.durationSeconds
                    $0.endedAt = $0.startedAt.addingTimeInterval(file.durationSeconds)
                }
                if let updated { recovered.append(updated) }
            } else {
                // 音声が 1 フレームも無いセグメントは不要
                delete(meta.id)
            }
        }
        return recovered
    }

    /// 変更通知を購読する (nil は削除)。戻り値で解除できる。
    @discardableResult
    public func observe(_ handler: @escaping @Sendable (SegmentMetadata?) -> Void) -> UUID {
        let token = UUID()
        lock.withLock { observers[token] = handler }
        return token
    }

    public func removeObserver(_ token: UUID) {
        lock.withLock { observers[token] = nil }
    }

    private func notify(_ meta: SegmentMetadata?) {
        let handlers = lock.withLock { Array(observers.values) }
        handlers.forEach { $0(meta) }
    }
}
