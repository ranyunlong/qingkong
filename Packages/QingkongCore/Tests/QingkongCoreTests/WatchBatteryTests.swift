import Foundation
import Testing
@testable import QingkongCore

struct WatchBatteryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func validatesReadingAndKeepsRealZero() {
        #expect(WatchBatterySnapshot(level: 0, charging: false, sampledAt: now).percentage(at: now) == 0)
        #expect(WatchBatterySnapshot(level: 0.655, charging: true, sampledAt: now).percentage(at: now) == 66)
        for invalid in [-1.0, 1.1, .nan, .infinity] {
            #expect(WatchBatterySnapshot(level: invalid, charging: false, sampledAt: now).percentage(at: now) == nil)
        }
    }

    @Test func expiresAndRejectsFutureReadings() {
        let reading = WatchBatterySnapshot(level: 0.5, charging: false, sampledAt: now)
        #expect(reading.percentage(at: now.addingTimeInterval(1799)) == 50)
        #expect(reading.percentage(at: now.addingTimeInterval(1800)) == nil)
        #expect(reading.percentage(at: now.addingTimeInterval(-61)) == nil)
    }

    @Test func roundTripsWithoutChangingSampleTime() throws {
        let reading = WatchBatterySnapshot(level: 0.4, charging: true, sampledAt: now)
        let restored = try JSONDecoder().decode(WatchBatterySnapshot.self, from: JSONEncoder().encode(reading))
        #expect(restored == reading)
        #expect(restored.percentage(at: now.addingTimeInterval(1800)) == nil)
    }
}
