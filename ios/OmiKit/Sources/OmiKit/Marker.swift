import Foundation

/// Omi のボタン操作で付ける印。録音とは独立した時刻付きのイベントとして保存し、
/// 表示やサーバでの書き出し時に時刻で録音と対応付ける。
public struct Marker: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        public var id: String { rawValue }

        /// ⭐ 注目: ここは大事
        case highlight
        /// ✂️ 区切り: 話題の切れ目 (録音もここで区切る)
        case split
        /// 📝 メモ: この後に話すことは自分へのメモ・指示
        case memo

        public var label: String {
            switch self {
            case .highlight: return "注目"
            case .split: return "区切り"
            case .memo: return "メモ"
            }
        }

        public var symbol: String {
            switch self {
            case .highlight: return "⭐"
            case .split: return "✂️"
            case .memo: return "📝"
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var at: Date
    public var deviceId: String?

    public init(id: String = UUID().uuidString.lowercased(), kind: Kind, at: Date = Date(), deviceId: String? = nil) {
        self.id = id
        self.kind = kind
        self.at = at
        self.deviceId = deviceId
    }
}

/// ボタンの通知を印に変換する。
///
/// ファームウェア (`button.c`) は 1 回押しで 1、2 回押しで 2 を送り、そのあと必ず 5 (離した) を送る。
/// 押して 0.3〜3 秒で離したときは 5 だけが届く (3 秒以上は電源オフ)。
/// そのため 1・2 の直後の 5 は無視し、単独の 5 を「長押し」とみなす。
public struct ButtonGestureDecoder: Sendable {
    public var releaseIgnoreWindow: TimeInterval
    private var lastTapAt: Date?

    public init(releaseIgnoreWindow: TimeInterval = 1.5) {
        self.releaseIgnoreWindow = releaseIgnoreWindow
    }

    public mutating func decode(_ event: OmiButtonEvent, at now: Date = Date()) -> Marker.Kind? {
        switch event {
        case .singleTap:
            lastTapAt = now
            return .highlight
        case .doubleTap:
            lastTapAt = now
            return .split
        case .release:
            if let last = lastTapAt, now.timeIntervalSince(last) < releaseIgnoreWindow {
                lastTapAt = nil
                return nil
            }
            return .memo
        case .press, .longTap:
            return nil
        }
    }
}

/// 印の保存場所 (`markers.json`)。複数スレッドから呼ばれるため内部でロックする。
public final class MarkerStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var markers: [Marker] = []
    private var observers: [UUID: @Sendable () -> Void] = [:]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let loaded = try? JSONDecoder.omi.decode([Marker].self, from: data) {
            markers = loaded
        }
    }

    public func all() -> [Marker] {
        lock.withLock { markers }.sorted { $0.at < $1.at }
    }

    public func add(_ marker: Marker) {
        lock.withLock {
            markers.append(marker)
            persist()
        }
        notify()
    }

    public func update(_ id: String, _ body: (inout Marker) -> Void) {
        lock.withLock {
            guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
            body(&markers[i])
            persist()
        }
        notify()
    }

    public func remove(_ id: String) {
        lock.withLock {
            markers.removeAll { $0.id == id }
            persist()
        }
        notify()
    }

    /// `[from, to]` の間の印
    public func between(_ from: Date, _ to: Date) -> [Marker] {
        all().filter { $0.at >= from && $0.at <= to }
    }

    public func observe(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.withLock { observers[token] = handler }
        return token
    }

    private func persist() {
        guard let data = try? JSONEncoder.omi.encode(markers) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func notify() {
        let handlers = lock.withLock { Array(observers.values) }
        handlers.forEach { $0() }
    }
}
