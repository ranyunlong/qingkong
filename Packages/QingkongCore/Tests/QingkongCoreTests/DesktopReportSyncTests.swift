import Foundation
import Testing
@testable import QingkongCore

struct DesktopReportSyncTests {
    @Test func authorizationIsExplicitAndScopedToAnAccountAndMac() throws {
        let first = UUID(), other = UUID()
        var authorization = DesktopReportAuthorization()
        authorization.confirmAccount("account-a")
        #expect(!authorization.isEnabled(for: first))
        authorization.setEnabled(true, for: first)
        #expect(authorization.isEnabled(for: first))
        #expect(!authorization.isEnabled(for: other))
        #expect(authorization.maySend(to: first, foreground: true, connected: true, isDemo: false))
        #expect(!authorization.maySend(to: first, foreground: false, connected: true, isDemo: false))
        #expect(!authorization.maySend(to: first, foreground: true, connected: false, isDemo: false))
        #expect(!authorization.maySend(to: first, foreground: true, connected: true, isDemo: true))
        let restored = try JSONDecoder().decode(DesktopReportAuthorization.self, from: JSONEncoder().encode(authorization))
        #expect(restored.isEnabled(for: first))
        authorization.setEnabled(false, for: first)
        #expect(!authorization.isEnabled(for: first))
    }

    @Test func accountChangesAndSignOutRevokeExistingAuthorizations() {
        let mac = UUID()
        var authorization = DesktopReportAuthorization()
        authorization.setEnabled(true, for: mac)
        #expect(!authorization.isEnabled(for: mac))
        authorization.confirmAccount("account-a")
        authorization.setEnabled(true, for: mac)
        authorization.confirmAccount("account-a")
        #expect(authorization.isEnabled(for: mac))
        authorization.confirmAccount("account-b")
        #expect(!authorization.isEnabled(for: mac))
        authorization.setEnabled(true, for: mac)
        authorization.confirmAccount(nil)
        authorization.confirmAccount("account-b")
        #expect(!authorization.isEnabled(for: mac))
    }

    @Test func reportContentExcludesGenerationTimeButIncludesTimezoneAndData() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = DesktopReport.build(readings: [], moods: [], practices: [], sleepSamples: [], now: now)
        let b = DesktopReport.build(readings: [], moods: [], practices: [], sleepSamples: [], now: now.addingTimeInterval(1))
        #expect(try a.contentIdentity() == b.contentIdentity())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3600)!
        let c = DesktopReport.build(readings: [], moods: [], practices: [], sleepSamples: [], now: now, calendar: calendar)
        #expect(try a.contentIdentity() != c.contentIdentity())
        let nextDay = DesktopReport.build(readings: [], moods: [], practices: [], sleepSamples: [], now: now.addingTimeInterval(86400))
        #expect(try a.contentIdentity() != nextDay.contentIdentity())
    }

    @Test func newHandshakeAndSyncStateRoundTripWhileLegacyResponsesStillDecode() throws {
        let legacy = Data("{\"version\":2,\"id\":\"00000000-0000-0000-0000-000000000001\",\"success\":true}".utf8)
        let old = try JSONDecoder().decode(DesktopMusicResponse.self, from: legacy)
        #expect(old.hostID == nil && old.capabilities == nil)
        let host = UUID()
        let hello = DesktopMusicResponse(id: UUID(), hostID: host, capabilities: [DesktopReportSyncState.capability])
        let decoded = try JSONDecoder().decode(DesktopMusicResponse.self, from: JSONEncoder().encode(hello))
        #expect(decoded.hostID == host)
        #expect(decoded.capabilities == [DesktopReportSyncState.capability])
        for state in [DesktopReportSyncState.disabled, .enabled, .syncing, .failed] {
            let request = DesktopMusicRequest(action: .reportSyncStatus, reportSyncState: state)
            let decoded = try JSONDecoder().decode(DesktopMusicRequest.self, from: JSONEncoder().encode(request))
            #expect(decoded.reportSyncState == state)
            #expect(decoded.report == nil && decoded.command == nil)
        }
    }

    @Test func aggregateEditsAndDeletionChangeContentWhilePrivateNotesDoNot() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var mood = MoodRecord(mood: 2, stress: 4, note: "private", createdAt: now)
        func report(_ record: MoodRecord) -> DesktopReport {
            DesktopReport.build(readings: [], moods: [record], practices: [], sleepSamples: [], now: now)
        }
        let original = try report(mood).contentIdentity()
        mood.note = "a different private note"
        #expect(try report(mood).contentIdentity() == original)
        mood.mood = 5
        #expect(try report(mood).contentIdentity() != original)
        mood.mood = 2; mood.isDeleted = true
        #expect(try report(mood).contentIdentity() != original)
        let empty = DesktopReport.build(readings: [], moods: [], practices: [], sleepSamples: [], now: now)
        #expect(try report(mood).contentIdentity() == empty.contentIdentity())
    }
}
