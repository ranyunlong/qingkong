import Foundation

/// The widget never needs a journal entry, its note, or its stress rating.
public struct MoodSummary: Codable, Equatable, Sendable {
    public let value: Int
    public let date: Date
    public var label: String { MoodRecord.labels[value - 1] }

    private init(record: MoodRecord) { value = record.mood; date = record.createdAt }

    public static func latest(in records: [MoodRecord], now: Date = .now) -> MoodSummary? {
        records.filter { !$0.isDeleted && $0.createdAt <= now }
            .max { left, right in
                if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
                if left.updatedAt != right.updatedAt { return left.updatedAt < right.updatedAt }
                return left.id.uuidString < right.id.uuidString
            }.map(Self.init(record:))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(Int.self, forKey: .value)
        date = try container.decode(Date.self, forKey: .date)
        guard (1...5).contains(value), date.timeIntervalSince1970.isFinite else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid mood summary"))
        }
    }
}

public enum DumplingMotion {
    public static let duration: TimeInterval = 3
    /// Rest is zero, including after the single greeting finishes.
    public static func progress(elapsed: TimeInterval) -> Double {
        guard elapsed.isFinite, elapsed >= 0, elapsed < duration else { return 0 }
        return elapsed / duration
    }
}
