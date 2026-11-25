import Foundation

public struct WatchBatterySnapshot: Codable, Equatable, Sendable {
    public static let maximumAge: TimeInterval = 30 * 60
    public let level: Double
    public let charging: Bool
    public let sampledAt: Date

    public init(level: Double, charging: Bool, sampledAt: Date = .now) {
        self.level = level; self.charging = charging; self.sampledAt = sampledAt
    }

    public func percentage(at now: Date = .now) -> Int? {
        let age = now.timeIntervalSince(sampledAt)
        guard level.isFinite, (0...1).contains(level), age.isFinite,
              age >= -60, age < Self.maximumAge else { return nil }
        return Int((level * 100).rounded())
    }
}
