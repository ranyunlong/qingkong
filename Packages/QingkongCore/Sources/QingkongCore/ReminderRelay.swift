import Foundation

public enum ReminderSignalKind: String, Codable, CaseIterable, Sendable {
    case hrv, highHeartRate, lowHeartRate, lowOxygen
    public var vitalKind: VitalReminderKind? { VitalReminderKind(rawValue: rawValue) }
    public var metric: HealthMetric { vitalKind?.metric ?? .hrv }
    public var maximumAge: TimeInterval { self == .hrv ? 3600 : 900 }
}

/// A Watch-side decision, not a copy of the user's HealthKit readings.
public struct ReminderSignal: Codable, Sendable, Identifiable {
    public let version: Int
    public let kind: ReminderSignalKind
    public let sampleID: UUID
    public let sampleDate: Date
    public let detectedAt: Date
    public let configurationID: UUID
    public var id: String { kind.rawValue + "." + sampleID.uuidString }
    public init(kind: ReminderSignalKind, sampleID: UUID, sampleDate: Date, detectedAt: Date, configurationID: UUID) {
        version = 1
        self.kind = kind; self.sampleID = sampleID; self.sampleDate = sampleDate
        self.detectedAt = detectedAt; self.configurationID = configurationID
    }
}

public struct WatchReminderReport: Codable, Sendable {
    public let version: Int
    public let configurationID: UUID
    public let checkedAt: Date
    public let updatedAt: Date
    public let results: [String: String]
    public let signals: [ReminderSignal]
    public let newestSamples: [HealthMetric: Date]
    public init(configurationID: UUID, checkedAt: Date, results: [String: String], signals: [ReminderSignal], newestSamples: [HealthMetric: Date]) {
        version = 1; self.configurationID = configurationID; self.checkedAt = checkedAt; updatedAt = .now
        self.results = results; self.signals = signals; self.newestSamples = newestSamples
    }
}

/// iPhone owns settings; Watch accepts only newer snapshots and persists its processing cursor.
public struct ReminderRelayConfiguration: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public let updatedAt: Date
    public let watchOwnerID: UUID?
    public private(set) var hrv: RelaxationReminderState
    public private(set) var vitalRules: [VitalReminderKind: VitalReminderRule]

    public init(hrv: RelaxationReminderState, vitalRules: [VitalReminderKind: VitalReminderRule], updatedAt: Date = .now, watchOwnerID: UUID? = nil) {
        version = 1; id = UUID(); self.updatedAt = updatedAt
        self.hrv = hrv; self.vitalRules = vitalRules; self.watchOwnerID = watchOwnerID
    }

    public mutating func mergeProgress(from previous: ReminderRelayConfiguration) {
        hrv.mergeProgress(from: previous.hrv)
        for kind in VitalReminderKind.allCases {
            if let old = previous.vitalRules[kind] { vitalRules[kind]?.delivery.mergeProgress(from: old.delivery) }
        }
    }

    public mutating func assess(readings: [HealthReading], now: Date = .now, calendar: Calendar = .current) -> WatchReminderReport {
        var signals: [ReminderSignal] = []
        var results: [String: String] = [:]
        let hrvResult = RelaxationReminderPolicy.assess(readings: readings, state: hrv, now: now, calendar: calendar)
        results["hrv"] = hrvResult.reason
        if let candidate = hrvResult.candidate {
            signals.append(.init(kind: .hrv, sampleID: candidate.sampleID, sampleDate: candidate.sampleDate, detectedAt: now, configurationID: id))
            // Reserve a detection window locally to avoid flooding the disconnected queue.
            // Notification submission is tracked separately by the selected dispatcher.
            hrv.recordDelivery(candidate, now: now)
        }
        for kind in VitalReminderKind.allCases {
            guard let rule = vitalRules[kind] else { continue }
            let result = VitalReminderPolicy.assess(kind: kind, readings: readings, rule: rule, now: now, calendar: calendar)
            results[kind.rawValue] = result.reason
            if let candidate = result.candidate, let signalKind = ReminderSignalKind(rawValue: kind.rawValue) {
                signals.append(.init(kind: signalKind, sampleID: candidate.sampleID, sampleDate: candidate.sampleDate, detectedAt: now, configurationID: id))
                vitalRules[kind]?.recordDelivery(candidate, now: now)
            }
        }
        var newest: [HealthMetric: Date] = [:]
        for metric in HealthMetric.allCases {
            if let date = readings.filter({ $0.metric == metric && $0.isValid && $0.wasUserEntered != true && $0.date <= now }).map(\.date).max() {
                newest[metric] = date
                if metric == .hrv { hrv.consume(through: date) }
                for kind in VitalReminderKind.allCases where kind.metric == metric { vitalRules[kind]?.delivery.consume(through: date) }
            }
        }
        return .init(configurationID: id, checkedAt: now, results: results, signals: signals, newestSamples: newest)
    }
}

public enum ReminderRelayPolicy {
    /// Final gate on iPhone, using its current settings and shared notification ledger.
    public static func rejection(_ signal: ReminderSignal, configuration: ReminderRelayConfiguration,
                                 hrv: RelaxationReminderState, vitalRules: [VitalReminderKind: VitalReminderRule],
                                 now: Date = .now, calendar: Calendar = .current, latestKnownSampleDate: Date? = nil) -> String? {
        guard signal.version == 1, signal.configurationID == configuration.id else { return "手表使用的提醒设置已过期，等待同步新设置" }
        guard signal.sampleDate <= now, signal.detectedAt <= now.addingTimeInterval(30), signal.detectedAt >= signal.sampleDate,
              now.timeIntervalSince(signal.sampleDate) <= signal.kind.maximumAge else { return "手表结果已过期或时间无效，不补发旧提醒" }
        if let latestKnownSampleDate, latestKnownSampleDate > signal.sampleDate { return "已有更新的健康记录，不补发较早的变化提醒" }
        let state: RelaxationReminderState
        if let kind = signal.kind.vitalKind {
            guard let rule = vitalRules[kind], rule.threshold.isFinite, kind.thresholdRange.contains(rule.threshold) else { return "提醒规则无效" }
            state = rule.delivery
        } else { state = hrv }
        guard state.enabled else { return "提醒已关闭" }
        guard state.mutedUntil.map({ now >= $0 }) ?? true else { return "今天已暂停提醒" }
        guard signal.sampleDate > state.eligibleSince else { return "不补发启用或调整设置前的记录" }
        guard signal.sampleDate > state.consumedThrough else { return "该记录或更新的记录已在手机处理，不重复提醒" }
        guard state.deliveries.filter({ calendar.isDate($0, inSameDayAs: now) }).count < 2,
              state.deliveries.max().map({ now.timeIntervalSince($0) >= 4 * 3600 }) ?? true else { return "处于提醒间隔或已达今日上限" }
        return nil
    }
}

public struct WatchReminderReady: Codable, Sendable {
    public let watchID: UUID
    public let configurationID: UUID
    public init(watchID: UUID, configurationID: UUID) { self.watchID = watchID; self.configurationID = configurationID }
}

public enum ReminderDispatchRoute: String, Codable, Sendable { case undecided, phone, watch }

public struct PendingReminderDispatch: Codable, Sendable, Identifiable {
    public let signal: ReminderSignal
    public var route: ReminderDispatchRoute = .undecided
    public var id: String { signal.id }
    public init(signal: ReminderSignal) { self.signal = signal }
    /// Once chosen, a route cannot change after a lost reply or a later reconnect.
    public mutating func assignRoute(after probe: ReminderProbeResult) -> Bool {
        guard route == .undecided else { return true }
        switch probe {
        case .accepted: route = .phone
        case .unavailable: route = .watch
        case .rejected: return false
        }
        return true
    }
}

public enum ReminderProbeResult: Equatable, Sendable { case accepted, unavailable, rejected }
