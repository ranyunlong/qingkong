import Foundation

public enum LifeTag: String, Codable, CaseIterable, Identifiable, Sendable {
    case work, family, exercise, social, coffee, alcohol
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .work: "工作"
        case .family: "家庭"
        case .exercise: "运动"
        case .social: "社交"
        case .coffee: "咖啡"
        case .alcohol: "饮酒"
        }
    }
}

public enum RelaxationDuration: Int, Codable, CaseIterable, Identifiable, Sendable {
    case oneMinute = 1, threeMinutes = 3, fiveMinutes = 5
    public var id: Int { rawValue }
    public var minutes: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue * 60) }
    public var name: String { "\(minutes) 分钟" }
}

public enum RelaxationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case breathing, quiet
    public var id: String { rawValue }
    public var name: String { self == .breathing ? "舒缓呼吸" : "安静陪伴" }
}

public enum RelaxationFeedback: String, Codable, CaseIterable, Identifiable, Sendable {
    case better, same
    public var id: String { rawValue }
    public var name: String { self == .better ? "好一些" : "差不多" }
}

public enum RelaxationStatus: String, Codable, Sendable {
    case ready, running, paused, completed, exited
}

/// A comfortable suggested rhythm, with no breath holding. Users can breathe naturally.
public enum RelaxationPhase: String, Codable, Sendable {
    case inhale, exhale, quiet
    public var instruction: String {
        switch self {
        case .inhale: "轻轻吸气，按舒服的节奏就好"
        case .exhale: "慢慢呼气，不需要憋气"
        case .quiet: "安静待一会儿，我在这里陪你"
        }
    }
}

public struct BreathingHapticCue: Equatable, Sendable {
    public enum Kind: Sendable { case inhale, pulse, exhale }
    public let id: Int
    public let kind: Kind
}

public struct RelaxationRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let duration: RelaxationDuration
    public let mode: RelaxationMode
    public let startedAt: Date
    public let completedAt: Date
    public var feedback: RelaxationFeedback?
    public var practicedSeconds: TimeInterval { duration.seconds }

    public init(id: UUID = UUID(), duration: RelaxationDuration, mode: RelaxationMode, startedAt: Date, completedAt: Date, feedback: RelaxationFeedback? = nil) {
        self.id = id; self.duration = duration; self.mode = mode
        self.startedAt = startedAt; self.completedAt = completedAt; self.feedback = feedback
    }
}

/// Time comes from real dates, so delayed UI refreshes do not lengthen a session.
/// Exiting is deliberately separate from completing and never produces a record.
public struct RelaxationSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let duration: RelaxationDuration
    public let mode: RelaxationMode
    public var guidanceSoundEnabled: Bool
    public var hapticsEnabled: Bool
    public private(set) var status: RelaxationStatus = .ready
    public private(set) var startedAt: Date?
    public private(set) var endedAt: Date?
    private var accumulatedSeconds: TimeInterval = 0
    private var activeStartedAt: Date?
    private var pausedAt: Date?

    public init(id: UUID = UUID(), duration: RelaxationDuration, mode: RelaxationMode, guidanceSoundEnabled: Bool = false, hapticsEnabled: Bool = true) {
        self.id = id; self.duration = duration; self.mode = mode
        self.guidanceSoundEnabled = guidanceSoundEnabled; self.hapticsEnabled = hapticsEnabled
    }

    public var deadline: Date? {
        guard status == .running, let activeStartedAt else { return nil }
        return activeStartedAt.addingTimeInterval(duration.seconds - accumulatedSeconds)
    }

    public func elapsed(at now: Date = .now) -> TimeInterval {
        let active = status == .running ? activeStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0 : 0
        return min(duration.seconds, max(0, accumulatedSeconds + active))
    }

    public func remaining(at now: Date = .now) -> TimeInterval { duration.seconds - elapsed(at: now) }

    public func phase(at now: Date = .now) -> RelaxationPhase {
        guard mode == .breathing else { return .quiet }
        return elapsed(at: now).truncatingRemainder(dividingBy: 10) < 4 ? .inhale : .exhale
    }

    /// One cue per inhale second, then a distinct exhale cue. Delayed updates
    /// return only the current cue, so the caller never replays missed pulses.
    public func hapticCue(at now: Date = .now) -> BreathingHapticCue? {
        guard status == .running, mode == .breathing, hapticsEnabled else { return nil }
        let elapsed = elapsed(at: now)
        guard elapsed < duration.seconds else { return nil }
        let cycle = Int(elapsed / 10)
        let second = Int(elapsed.truncatingRemainder(dividingBy: 10))
        let slot = min(4, second)
        return BreathingHapticCue(id: cycle * 5 + slot, kind: slot == 0 ? .inhale : slot == 4 ? .exhale : .pulse)
    }

    public mutating func start(at now: Date = .now) {
        guard status == .ready else { return }
        startedAt = now; activeStartedAt = now; status = .running
    }

    public mutating func update(at now: Date = .now) {
        guard status == .running, let deadline, now >= deadline else { return }
        accumulatedSeconds = duration.seconds; endedAt = deadline
        activeStartedAt = nil; status = .completed
    }

    public mutating func pause(at now: Date = .now) {
        update(at: now)
        guard status == .running else { return }
        accumulatedSeconds = elapsed(at: now)
        pausedAt = max(now, activeStartedAt ?? now)
        activeStartedAt = nil; status = .paused
    }

    public mutating func resume(at now: Date = .now) {
        guard status == .paused else { return }
        activeStartedAt = max(now, pausedAt ?? now)
        pausedAt = nil; status = .running
    }

    public mutating func exit(at now: Date = .now) {
        guard status == .ready || status == .running || status == .paused else { return }
        accumulatedSeconds = elapsed(at: now); endedAt = max(now, startedAt ?? now)
        activeStartedAt = nil; pausedAt = nil; status = .exited
    }

    public func completedRecord(feedback: RelaxationFeedback? = nil) -> RelaxationRecord? {
        guard status == .completed, let startedAt, let endedAt else { return nil }
        return RelaxationRecord(id: id, duration: duration, mode: mode, startedAt: startedAt, completedAt: endedAt, feedback: feedback)
    }
}

public struct HealthChangeSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let metric: HealthMetric
    public let sampleDate: Date
    public let observedAt: Date
    public let value: Double
    public let referenceValue: Double?
    public let source: String
    public var interpretationNotice: String { "基于已有健康采样的变化摘要，不用于诊断。时间接近不代表因果关系。" }

    public init(id: UUID = UUID(), metric: HealthMetric, sampleDate: Date, observedAt: Date, value: Double, referenceValue: Double? = nil, source: String) {
        self.id = id; self.metric = metric; self.sampleDate = sampleDate; self.observedAt = observedAt
        self.value = value; self.referenceValue = referenceValue; self.source = source
    }
}

/// A successful submission to the notification system is not evidence of receipt.
public struct ReminderSubmissionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: ReminderSignalKind
    public let sampleDate: Date
    public let submittedAt: Date
    public var statusText: String { "提醒已提交" }

    public init(id: UUID = UUID(), kind: ReminderSignalKind, sampleDate: Date, submittedAt: Date) {
        self.id = id; self.kind = kind; self.sampleDate = sampleDate; self.submittedAt = submittedAt
    }
}

public enum CompanionTimelineContent: Codable, Equatable, Sendable {
    case mood(MoodRecord)
    case healthChange(HealthChangeSummary)
    case reminderSubmission(ReminderSubmissionRecord)
    case practice(RelaxationRecord)
}

public struct CompanionTimelineItem: Codable, Equatable, Identifiable, Sendable {
    public let content: CompanionTimelineContent
    public var id: String {
        switch content {
        case .mood(let record): "mood:\(record.id)"
        case .healthChange(let record): "health:\(record.id)"
        case .reminderSubmission(let record): "reminder:\(record.id)"
        case .practice(let record): "practice:\(record.id)"
        }
    }
    public var date: Date {
        switch content {
        case .mood(let record): record.createdAt
        case .healthChange(let record): record.observedAt
        case .reminderSubmission(let record): record.submittedAt
        case .practice(let record): record.completedAt
        }
    }
    public init(content: CompanionTimelineContent) { self.content = content }
}

public enum CompanionTimeline {
    public static func items(moods: [MoodRecord], healthChanges: [HealthChangeSummary], reminderSubmissions: [ReminderSubmissionRecord], practices: [RelaxationRecord]) -> [CompanionTimelineItem] {
        let contents = moods.filter { !$0.isDeleted }.map(CompanionTimelineContent.mood)
            + healthChanges.map(CompanionTimelineContent.healthChange)
            + reminderSubmissions.map(CompanionTimelineContent.reminderSubmission)
            + practices.map(CompanionTimelineContent.practice)
        return contents.map { CompanionTimelineItem(content: $0) }.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }
    }
}

/// Local counts of actual observations. Unobserved mood/stress levels remain absent.
public struct WeeklyCompanionReview: Equatable, Sendable {
    public let startDate: Date
    public let endDate: Date
    public let recordedDayCount: Int
    public let moodRecordDayCount: Int
    public let moodDistribution: [Int: Int]
    public let stressDistribution: [Int: Int]
    public let practiceCount: Int
    public let practicedSeconds: TimeInterval
    public var hasData: Bool { recordedDayCount > 0 }
    public var message: String {
        hasData ? "这一周有 \(recordedDayCount) 天留下记录，按自己的节奏继续就好。" : "这一周还没有记录，按自己的节奏开始就好。"
    }

    public init(weekStarting date: Date, moods: [MoodRecord], practices: [RelaxationRecord], calendar: Calendar = .current) {
        startDate = calendar.startOfDay(for: date)
        endDate = calendar.date(byAdding: .day, value: 7, to: startDate) ?? startDate
        let start = startDate, end = endDate
        let validMoods = moods.filter { !$0.isDeleted && $0.createdAt >= start && $0.createdAt < end }
        let validPractices = practices.filter { $0.completedAt >= start && $0.completedAt < end }
        let moodDays = Set(validMoods.map { calendar.startOfDay(for: $0.createdAt) })
        let practiceDays = Set(validPractices.map { calendar.startOfDay(for: $0.completedAt) })
        moodRecordDayCount = moodDays.count
        recordedDayCount = moodDays.union(practiceDays).count
        moodDistribution = validMoods.reduce(into: [:]) { $0[$1.mood, default: 0] += 1 }
        stressDistribution = validMoods.reduce(into: [:]) { $0[$1.stress, default: 0] += 1 }
        practiceCount = validPractices.count
        practicedSeconds = validPractices.reduce(0) { $0 + $1.practicedSeconds }
    }
}

public struct BedtimePlan: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var track: Track
    public var scene: SceneTheme
    public var stopAfterMinutes: Int

    public init(id: UUID = UUID(), name: String, track: Track, scene: SceneTheme, stopAfterMinutes: Int) {
        self.id = id; self.name = name; self.track = track; self.scene = scene
        self.stopAfterMinutes = max(1, stopAfterMinutes)
    }

    public func makeDeadline(at now: Date = .now) -> SleepDeadline { SleepDeadline(minutes: max(1, stopAfterMinutes), now: now) }
}

public enum CompanionAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case greeting, nod, sway
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .greeting: "轻轻招呼"
        case .nod: "温柔点头"
        case .sway: "轻轻摇摆"
        }
    }
    public var duration: TimeInterval {
        switch self { case .greeting: 3; case .nod: 1.8; case .sway: 2.4 }
    }

    /// One short response, followed by rest. Motion never loops or depends on health values.
    public func transform(elapsed: TimeInterval, reduceMotion: Bool = false) -> CompanionActionTransform {
        guard !reduceMotion, elapsed.isFinite, elapsed > 0, elapsed < duration else { return .rest }
        let progress = elapsed / duration
        let envelope = sin(progress * .pi)
        switch self {
        case .greeting:
            return .init(rotationDegrees: sin(progress * .pi * 4) * envelope * 2, offsetX: 0, offsetY: -envelope * 2, scaleY: 1)
        case .nod:
            return .init(rotationDegrees: 0, offsetX: 0, offsetY: envelope * 4, scaleY: 1 - envelope * 0.035)
        case .sway:
            let sway = sin(progress * .pi * 2) * envelope
            return .init(rotationDegrees: sway * 6, offsetX: sway * 3, offsetY: 0, scaleY: 1)
        }
    }
}

public struct CompanionActionTransform: Equatable, Sendable {
    public let rotationDegrees: Double
    public let offsetX: Double
    public let offsetY: Double
    public let scaleY: Double
    public static let rest = Self(rotationDegrees: 0, offsetX: 0, offsetY: 0, scaleY: 1)
}

/// Milestones use actual local records, with no streak, expiry, mood-score or feedback requirement.
public struct CompanionActionAvailability: Equatable, Sendable {
    public let actions: [CompanionAction]

    public init(moods: [MoodRecord], practices: [RelaxationRecord], now: Date = .now, rememberedActions: [CompanionAction] = []) {
        var available: [CompanionAction] = [.greeting]
        if rememberedActions.contains(.nod) || moods.contains(where: { !$0.isDeleted && $0.createdAt.timeIntervalSince1970.isFinite && $0.createdAt <= now }) {
            available.append(.nod)
        }
        if rememberedActions.contains(.sway) || practices.contains(where: {
            $0.startedAt.timeIntervalSince1970.isFinite && $0.completedAt.timeIntervalSince1970.isFinite
                && $0.completedAt <= now && $0.completedAt.timeIntervalSince($0.startedAt) >= $0.duration.seconds
        }) {
            available.append(.sway)
        }
        actions = available
    }
}

/// Optional artwork, separate from the five mood values and four app themes.
public enum CompanionExpression: String, CaseIterable, Identifiable, Sendable {
    case gentleSmile, brightEyes
    public var id: String { rawValue }
    public var name: String { self == .gentleSmile ? "眯眼微笑" : "眼里有光" }
    public var requiredAction: CompanionAction { self == .gentleSmile ? .nod : .sway }
}

public enum CompanionScenery: String, CaseIterable, Identifiable, Sendable {
    case morningMeadow, moonlitLake
    public var id: String { rawValue }
    public var name: String { self == .morningMeadow ? "晨光草地" : "月下湖畔" }
    public var requiredAction: CompanionAction { self == .morningMeadow ? .nod : .sway }
}

/// Reuses the existing permanent local unlock flags; no new personal records or scores.
public struct CompanionCollectionAvailability: Equatable, Sendable {
    public let expressions: [CompanionExpression]
    public let scenery: [CompanionScenery]

    public init(actions: [CompanionAction]) {
        expressions = CompanionExpression.allCases.filter { actions.contains($0.requiredAction) }
        scenery = CompanionScenery.allCases.filter { actions.contains($0.requiredAction) }
    }
}
