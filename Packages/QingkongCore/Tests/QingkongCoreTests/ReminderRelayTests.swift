import Foundation
import Testing
@testable import QingkongCore

struct ReminderRelayTests {
    let now = Date(timeIntervalSince1970: 1_795_000_000)
    func configuration() -> ReminderRelayConfiguration {
        .init(hrv: .init(now: now.addingTimeInterval(-7200)), vitalRules: Dictionary(uniqueKeysWithValues: VitalReminderKind.allCases.map { ($0, .init(kind: $0, now: now.addingTimeInterval(-7200))) }), updatedAt: now.addingTimeInterval(-60))
    }
    func signal(_ config: ReminderRelayConfiguration, kind: ReminderSignalKind = .hrv, age: TimeInterval = 60) -> ReminderSignal {
        .init(kind: kind, sampleID: UUID(), sampleDate: now.addingTimeInterval(-age), detectedAt: now, configurationID: config.id)
    }
    @Test func relayDoesNotRequireHealthLibraryToHaveReachedPhone() {
        let config = configuration()
        #expect(ReminderRelayPolicy.rejection(signal(config), configuration: config, hrv: config.hrv, vitalRules: config.vitalRules, now: now) == nil)
    }
    @Test func latestPhoneSettingsRejectOldOrDisabledWatchDecision() {
        var config = configuration()
        let old = signal(config)
        config = .init(hrv: config.hrv, vitalRules: config.vitalRules, updatedAt: now)
        #expect(ReminderRelayPolicy.rejection(old, configuration: config, hrv: config.hrv, vitalRules: config.vitalRules, now: now) != nil)
        var disabled = config.hrv
        disabled.setEnabled(false, now: now)
        #expect(ReminderRelayPolicy.rejection(signal(config), configuration: config, hrv: disabled, vitalRules: config.vitalRules, now: now) != nil)
    }
    @Test func pausedCooldownAndDailyLimitApplyAcrossBothDetectors() {
        let config = configuration()
        let event = signal(config)
        var state = config.hrv
        state.mutedUntil = now.addingTimeInterval(3600)
        #expect(ReminderRelayPolicy.rejection(event, configuration: config, hrv: state, vitalRules: config.vitalRules, now: now) != nil)
        state.mutedUntil = nil
        state.recordDelivery(sampleDate: now.addingTimeInterval(-120), now: now.addingTimeInterval(-120))
        #expect(ReminderRelayPolicy.rejection(event, configuration: config, hrv: state, vitalRules: config.vitalRules, now: now) != nil)
        state.deliveries = [now.addingTimeInterval(-8 * 3600), now.addingTimeInterval(-4 * 3600)]
        #expect(ReminderRelayPolicy.rejection(event, configuration: config, hrv: state, vitalRules: config.vitalRules, now: now) != nil)
    }
    @Test func queuedSignalsExpireAndFutureSignalsAreRejected() {
        let config = configuration()
        for kind in ReminderSignalKind.allCases {
            let maxAge: TimeInterval = kind == .hrv ? 3600 : 900
            #expect(ReminderRelayPolicy.rejection(signal(config, kind: kind, age: maxAge), configuration: config, hrv: config.hrv, vitalRules: config.vitalRules, now: now) == nil)
            #expect(ReminderRelayPolicy.rejection(signal(config, kind: kind, age: maxAge + 1), configuration: config, hrv: config.hrv, vitalRules: config.vitalRules, now: now) != nil)
            #expect(ReminderRelayPolicy.rejection(signal(config, kind: kind, age: -1), configuration: config, hrv: config.hrv, vitalRules: config.vitalRules, now: now) != nil)
        }
    }
    @Test func processedOrRecoveredPhoneDataSuppressesOlderWatchSignal() {
        let config = configuration()
        let event = signal(config)
        #expect(ReminderRelayPolicy.rejection(event, configuration: config, hrv: config.hrv, vitalRules: config.vitalRules, now: now, latestKnownSampleDate: now) != nil)
        var state = config.hrv
        state.consume(through: event.sampleDate)
        #expect(ReminderRelayPolicy.rejection(event, configuration: config, hrv: state, vitalRules: config.vitalRules, now: now) != nil)
        state.consume(through: now)
        #expect(ReminderRelayPolicy.rejection(event, configuration: config, hrv: state, vitalRules: config.vitalRules, now: now) != nil)
    }
    @Test func confirmationAndRestingRulesStillRunOnWatch() {
        var config = configuration()
        let unknown = [-700.0, -10].map { HealthReading(metric: .heartRate, date: now.addingTimeInterval($0), value: 130, source: "Watch") }
        #expect(config.assess(readings: unknown, now: now).signals.isEmpty)
        let resting = unknown.map { sample in var sample = sample; sample.isAtRest = true; return sample }
        // A newer configuration permits re-evaluating previously consumed timestamps.
        config = configuration()
        let report = config.assess(readings: resting, now: now)
        #expect(report.signals.map(\.kind) == [.highHeartRate])
        #expect(config.assess(readings: resting, now: now).signals.isEmpty)
    }
    @Test func sparseHRVIsEvaluatedOnWatchAndNotReplayedAfterRestart() throws {
        var config = configuration()
        let history = (1...3).map { offset in HealthReading(metric: .hrv, date: now.addingTimeInterval(Double(-offset) * 86400), value: 50, source: "Watch") }
        let readings = history + [HealthReading(metric: .hrv, date: now.addingTimeInterval(-30), value: 30, source: "Watch")]
        #expect(config.assess(readings: readings, now: now).signals.map(\.kind) == [.hrv])
        config = try JSONDecoder().decode(ReminderRelayConfiguration.self, from: JSONEncoder().encode(config))
        #expect(config.assess(readings: readings, now: now).signals.isEmpty)
    }
    @Test func settingsSyncPreservesWatchCooldownWithoutRevertingNewSwitches() throws {
        var previous = configuration()
        let samples = [-700.0, -10].map { HealthReading(metric: .heartRate, date: now.addingTimeInterval($0), value: 130, source: "Watch", isAtRest: true) }
        #expect(previous.assess(readings: samples, now: now).signals.count == 1)
        var changed = configuration()
        changed.mergeProgress(from: previous)
        let later = now.addingTimeInterval(60)
        let fresh = samples + [HealthReading(metric: .heartRate, date: later, value: 130, source: "Watch", isAtRest: true)]
        #expect(changed.assess(readings: fresh, now: later).signals.isEmpty)
        var disabled = configuration().hrv
        disabled.setEnabled(false, now: now)
        disabled.mergeProgress(from: previous.hrv)
        #expect(!disabled.enabled)
        #expect(disabled.eligibleSince == now)
    }

    @Test func dispatchedRouteSurvivesReconnectionAndRestartWithoutSendingTwice() throws {
        let config = configuration()
        var phone = PendingReminderDispatch(signal: signal(config))
        let phoneAccepted = phone.assignRoute(after: .accepted)
        #expect(phoneAccepted)
        phone = try JSONDecoder().decode(PendingReminderDispatch.self, from: JSONEncoder().encode(phone))
        let phoneKept = phone.assignRoute(after: .unavailable)
        #expect(phoneKept)
        #expect(phone.route == .phone)
        var watch = PendingReminderDispatch(signal: signal(config))
        let watchAccepted = watch.assignRoute(after: .unavailable)
        #expect(watchAccepted)
        let watchKept = watch.assignRoute(after: .accepted)
        #expect(watchKept)
        #expect(watch.route == .watch)
        var staleSettings = PendingReminderDispatch(signal: signal(config))
        let staleAccepted = staleSettings.assignRoute(after: .rejected)
        #expect(!staleAccepted)
        #expect(staleSettings.route == .undecided)
    }

    @Test func settingsSyncDoesNotCountPhoneSubmissionAndWatchReservationTwice() {
        var watch = configuration().hrv
        watch.recordDelivery(sampleDate: now.addingTimeInterval(-60), now: now)
        var phone = configuration().hrv
        phone.recordDelivery(sampleDate: now.addingTimeInterval(-60), now: now.addingTimeInterval(1))
        phone.mergeProgress(from: watch)
        #expect(phone.deliveries == [now])
        #expect(phone.consumedThrough == watch.consumedThrough)
    }

    @Test func envelopeCarriesNoHealthValuesAndRulesSurviveRoundTrip() throws {
        let config = configuration()
        let event = signal(config)
        let data = try JSONEncoder().encode(event)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("baseline"))
        #expect(!text.contains("threshold"))
        #expect(!text.contains("value"))
        let decoded = try JSONDecoder().decode(ReminderRelayConfiguration.self, from: JSONEncoder().encode(config))
        #expect(decoded.id == config.id)
        #expect(decoded.vitalRules[.lowOxygen]?.threshold == 90)
    }
}
