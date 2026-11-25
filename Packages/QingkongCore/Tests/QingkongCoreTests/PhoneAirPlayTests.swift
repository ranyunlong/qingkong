import Foundation
import Testing
@testable import QingkongCore

struct PhoneAirPlayTests {
    private func snapshot() -> DesktopPlaybackSnapshot {
        .init(sessionID: UUID(), revision: 8, queue: [.init(track: .rain)], index: 0,
              position: 7, duration: 120, playing: true, mode: .sequence, volume: 0.4,
              deadline: SleepDeadline(minutes: 12), deviceName: "iPhone")
    }

    @Test func mirrorOnlyMatchesOneExactReceiver() {
        #expect(PhoneAirPlay.matchingReceiver("书房 Mac", receivers: ["a": "书房 Mac", "b": "客厅 Mac"]) == "a")
        #expect(PhoneAirPlay.matchingReceiver("书房 Mac", receivers: ["a": "书房 Mac", "b": "书房 Mac"]) == nil)
        #expect(PhoneAirPlay.matchingReceiver("Mac", receivers: ["a": "书房 Mac"]) == nil)
        #expect(PhoneAirPlay.matchingReceiver("", receivers: ["a": ""]) == nil)
    }

    @Test func genericAirPlayRouteMirrorsOnlyOneConnectedTrustedMac() {
        #expect(PhoneAirPlay.matchingReceiver("AirPlay", receivers: ["a": "书房 Mac"]) == "a")
        #expect(PhoneAirPlay.matchingReceiver("AirPlay", receivers: [:]) == nil)
        #expect(PhoneAirPlay.matchingReceiver("AirPlay", receivers: ["a": "书房 Mac", "b": "客厅 Mac"]) == nil)
        #expect(PhoneAirPlay.matchingReceiver("客厅音箱", receivers: ["a": "书房 Mac"]) == nil)
    }

    @Test func updatesRoundTripWithoutChangingAbsoluteDeadline() throws {
        let update = PhonePlaybackUpdate(routeName: "书房 Mac", snapshot: snapshot())
        #expect(update.isValid)
        let request = DesktopMusicRequest(action: .phonePlayback, phonePlayback: update)
        let decoded = try JSONDecoder().decode(DesktopMusicRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.phonePlayback == update)
        #expect(decoded.phonePlayback?.snapshot.deadline == update.snapshot.deadline)
        var invalid = update
        invalid.routeName = ""
        #expect(!invalid.isValid)
        invalid = update; invalid.snapshot.position = .infinity
        #expect(!invalid.isValid)
    }

    @Test func controlValidationRejectsAmbiguousAndInvalidInputs() throws {
        let session = UUID()
        #expect(PhonePlaybackCommand(sessionID: session, action: .pause).isValid)
        #expect(PhonePlaybackCommand(sessionID: session, action: .select, amount: 1).isValid)
        #expect(!PhonePlaybackCommand(sessionID: session, action: .select, amount: 1.5).isValid)
        #expect(!PhonePlaybackCommand(sessionID: session, action: .seek, amount: .nan).isValid)
        #expect(!PhonePlaybackCommand(sessionID: session, action: .volume, amount: 1.1).isValid)
        #expect(!PhonePlaybackCommand(sessionID: session, action: .pause, amount: 1).isValid)
        let command = PhonePlaybackCommand(sessionID: session, action: .timer, deadline: SleepDeadline(minutes: 15))
        let response = DesktopMusicResponse(id: command.id, phoneCommand: command)
        #expect(try JSONDecoder().decode(DesktopMusicResponse.self, from: JSONEncoder().encode(response)).phoneCommand == command)
    }
}
