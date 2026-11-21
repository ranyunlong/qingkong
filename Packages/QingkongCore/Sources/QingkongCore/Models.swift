import Foundation

public enum SceneTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case clear, forest, ocean, night
    public var id: String { rawValue }
    public var name: String {
        switch self { case .clear: "晴空"; case .forest: "林间"; case .ocean: "海岸"; case .night: "星夜" }
    }
    public var caption: String {
        switch self { case .clear: "清晰、轻盈的日常"; case .forest: "把脚步交还给自然"; case .ocean: "让思绪慢慢舒展"; case .night: "给今晚一点安静" }
    }
    public var hex: UInt32 {
        switch self { case .clear: 0x32699d; case .forest: 0x476c50; case .ocean: 0x2c727b; case .night: 0x696080 }
    }
    public var image: String { self == .clear ? "sky" : rawValue }
}

public enum HealthMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    case hrv, heartRate, oxygen
    public var id: String { rawValue }
    public var name: String { switch self { case .hrv: "HRV"; case .heartRate: "心率"; case .oxygen: "血氧" } }
    public var unit: String { switch self { case .hrv: "ms"; case .heartRate: "次/分"; case .oxygen: "%" } }
    public var symbol: String { switch self { case .hrv: "waveform.path.ecg"; case .heartRate: "heart"; case .oxygen: "drop" } }
}

public struct HealthReading: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var metric: HealthMetric
    public var date: Date
    public var value: Double
    public var source: String
    public var sourceIdentifier: String?
    public var wasUserEntered: Bool?
    public var isAtRest: Bool?
    public init(id: UUID = UUID(), metric: HealthMetric, date: Date, value: Double, source: String, sourceIdentifier: String? = nil, wasUserEntered: Bool? = nil, isAtRest: Bool? = nil) {
        self.id = id; self.metric = metric; self.date = date; self.value = value; self.source = source
        self.sourceIdentifier = sourceIdentifier
        self.wasUserEntered = wasUserEntered
        self.isAtRest = isAtRest
    }
    public var isValid: Bool { value.isFinite && value > 0 && (metric != .oxygen || value <= 100) }
}

public struct MoodRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var mood: Int
    public var stress: Int
    public var note: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool
    public init(id: UUID = UUID(), mood: Int, stress: Int, note: String, createdAt: Date = .now) {
        precondition((1...5).contains(mood) && (1...5).contains(stress))
        self.id = id; self.mood = mood; self.stress = stress; self.note = String(note.prefix(1000))
        self.createdAt = createdAt; self.updatedAt = createdAt; self.isDeleted = false
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        mood = try c.decode(Int.self, forKey: .mood)
        stress = try c.decode(Int.self, forKey: .stress)
        note = try c.decode(String.self, forKey: .note)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        isDeleted = try c.decode(Bool.self, forKey: .isDeleted)
        guard (1...5).contains(mood), (1...5).contains(stress), note.count <= 1000,
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid mood record"))
        }
    }
    public static let labels = ["低落", "疲惫", "平静", "不错", "开心"]
    public var label: String { Self.labels[mood - 1] }
    public var reflection: String {
        stress >= 4 ? "你记录了较高的压力。可以先留几分钟休息，或听一段自然声音。" : "把此刻记下来，就是一次对自己的关照。愿你按舒服的节奏度过今天。"
    }
}

public enum RecordMerge {
    public static func resolve(local: MoodRecord, incoming: MoodRecord) -> MoodRecord {
        if incoming.updatedAt != local.updatedAt { return incoming.updatedAt > local.updatedAt ? incoming : local }
        if incoming.isDeleted != local.isDeleted { return incoming.isDeleted ? incoming : local }
        return local
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var manualScene: SceneTheme = .clear
    public var automaticScene = false
    public var relaxingScene: SceneTheme = .forest
    public var complicationMetric: HealthMetric = .hrv
    public var showComplicationTrend = true
    public var updatedAt: Date = .distantPast
    public init() {}
    public mutating func selectScene(_ scene: SceneTheme) {
        manualScene = scene; automaticScene = false; updatedAt = .now
    }
    public func scene(entries: [MoodRecord], now: Date = .now, calendar: Calendar = .current) -> SceneTheme {
        guard automaticScene,
              let latest = entries.filter({ !$0.isDeleted && $0.createdAt <= now && calendar.isDate($0.createdAt, inSameDayAs: now) }).max(by: { $0.createdAt < $1.createdAt }),
              latest.stress >= 4 else { return manualScene }
        return relaxingScene
    }
}

public enum TrendPeriod: String, CaseIterable, Identifiable, Sendable {
    case day, week, month
    public var id: String { rawValue }
    public var name: String { switch self { case .day: "日"; case .week: "周"; case .month: "月" } }
}

public struct TrendBucket: Identifiable, Codable, Equatable, Sendable {
    public var date: Date
    public var value: Double?
    public var segment: Int
    public var id: Date { date }
    public init(date: Date, value: Double?, segment: Int) { self.date = date; self.value = value; self.segment = segment }
}

public enum Track: String, CaseIterable, Codable, Identifiable, Sendable {
    case rain, ocean, night
    public var id: String { rawValue }
    public var name: String { switch self { case .rain: "林间落雨"; case .ocean: "慢慢听海"; case .night: "星光慢板" } }
    public var subtitle: String { switch self { case .rain: "自然雨声"; case .ocean: "轻柔海浪"; case .night: "夜间自然声" } }
    public var image: String { self == .rain ? "forest" : rawValue }
}

public struct SleepDeadline: Codable, Equatable, Sendable {
    public var date: Date
    public private(set) var durationMinutes: Int?
    public init(minutes: Int, now: Date = .now) {
        durationMinutes = max(0, minutes)
        date = now.addingTimeInterval(TimeInterval(max(0, minutes)) * 60)
    }
    public func expired(at now: Date = .now) -> Bool { now >= date }
    public func remaining(at now: Date = .now) -> TimeInterval { max(0, date.timeIntervalSince(now)) }
}

public struct AudioState: Codable, Equatable, Sendable {
    public var track: Track = .rain
    public var playing = false
    public var volume: Float = 0.45
    public var deadline: SleepDeadline?
    public init() {}
}

public struct AudioCommand: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case status, playPause, pause, previous, next, volume, timer, select }
    public var id: UUID = UUID()
    public var action: Action
    public var amount: Double?
    public var track: Track?
    public init(action: Action, amount: Double? = nil, track: Track? = nil) { self.action = action; self.amount = amount; self.track = track }
}

public struct AudioReply: Codable, Sendable {
    public var id: UUID
    public var state: AudioState
    public var error: String?
    public var updatedAt: Date?
    public init(id: UUID, state: AudioState, error: String? = nil, updatedAt: Date? = .now) {
        self.id = id; self.state = state; self.error = error; self.updatedAt = updatedAt
    }
}

public struct SyncPayload: Codable, Equatable, Sendable {
    public var version = 1
    public var record: MoodRecord
    public init(record: MoodRecord) { self.record = record }
}

public struct SyncReceipt: Codable, Equatable, Sendable {
    public var id: UUID
    public var updatedAt: Date
    public init(record: MoodRecord) { id = record.id; updatedAt = record.updatedAt }
    public func matches(_ record: MoodRecord) -> Bool { id == record.id && updatedAt == record.updatedAt }
}

public struct ComplicationSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var readings: [HealthReading]
    public var trends: [HealthMetric: [TrendBucket]]
    public var preferences: Preferences
    public var mood: MoodSummary?
    public init(generatedAt: Date = .now, readings: [HealthReading], trends: [HealthMetric: [TrendBucket]], preferences: Preferences, mood: MoodSummary? = nil) {
        self.generatedAt = generatedAt; self.readings = readings; self.trends = trends; self.preferences = preferences
        self.mood = mood
    }
}
