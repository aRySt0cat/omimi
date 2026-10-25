import Foundation

/// Omi のバッテリー残量の記録。減り方 (%/時) を求めて、省電力の効果を確かめるのに使う。
public struct BatteryLog: Codable, Equatable, Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        public var at: Date
        public var level: Int
    }

    public private(set) var samples: [Sample] = []
    /// 残しておく期間
    public var retention: TimeInterval = 7 * 86_400

    public init() {}

    /// 値が変わったときだけ記録する (同じ値は 1 時間に 1 回)。充電で増えたら、そこから測り直す。
    public mutating func record(_ level: Int, at now: Date = Date()) {
        if let last = samples.last {
            if level == last.level && now.timeIntervalSince(last.at) < 3600 { return }
            if level > last.level + 2 { samples.removeAll() } // 充電された
        }
        samples.append(Sample(at: now, level: level))
        samples.removeAll { now.timeIntervalSince($0.at) > retention }
    }

    /// 直近 `window` の減り方 (%/時)。測るのに十分な時間・変化がなければ nil。
    public func drainPerHour(window: TimeInterval = 6 * 3600, now: Date = Date()) -> Double? {
        let recent = samples.filter { now.timeIntervalSince($0.at) <= window }
        guard let first = recent.first, let last = recent.last else { return nil }
        let hours = last.at.timeIntervalSince(first.at) / 3600
        let drop = Double(first.level - last.level)
        guard hours >= 0.5, drop >= 2 else { return nil }
        return drop / hours
    }

    /// 今の減り方が続いた場合の残り時間
    public func hoursRemaining(now: Date = Date()) -> Double? {
        guard let rate = drainPerHour(now: now), rate > 0, let level = samples.last?.level else { return nil }
        return Double(level) / rate
    }
}
