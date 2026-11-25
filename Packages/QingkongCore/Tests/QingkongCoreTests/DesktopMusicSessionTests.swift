import Foundation
import Testing
@testable import QingkongCore

struct DesktopMusicSessionTests {
    private let sessionID = UUID(uuidString: "0D42A921-607C-4DD0-9470-01D34D92426A")!
    private let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func onlineTrack(id: String = "rain", audioURL: String = "https://content.example.org/rain.m4a") -> PublicAudioTrack {
        PublicAudioTrack(id: id, albumID: "nature", title: "在线雨声", audioURL: URL(string: audioURL)!,
                         coverURL: nil, durationSeconds: 120, fileVersion: "1", byteSize: 1024,
                         sha256: String(repeating: "a", count: 64),
                         copyright: PublicAudioCopyright(owner: "Owner", source: "Original", license: "CC0", expiresAt: nil),
                         updatedAt: receivedAt, publishedAt: receivedAt, revision: 1, sortOrder: 0)
    }

    private func start(queue: [DesktopQueueItem] = [DesktopQueueItem(track: .rain)],
                       serviceAddress: String = "") -> DesktopPlaybackStart {
        DesktopPlaybackStart(sessionID: sessionID, queue: queue, index: 0, position: 10,
                             playing: true, mode: .sequence, deadline: nil, serviceAddress: serviceAddress)
    }

    private func snapshot() -> DesktopPlaybackSnapshot {
        DesktopPlaybackSnapshot(sessionID: sessionID, revision: 7, queue: [DesktopQueueItem(track: .rain)],
                                index: 0, position: 10, duration: 120, playing: true, mode: .single,
                                volume: 0.5, deadline: nil,
                                sampledAt: receivedAt.addingTimeInterval(100_000), deviceName: "客厅 Mac")
    }

    @Test func queueItemsIdentifySourceAndRejectMissingOrAmbiguousSources() throws {
        let bundled = DesktopQueueItem(track: .rain)
        let online = DesktopQueueItem(onlineTrack: onlineTrack())
        #expect(bundled.id == "builtin:rain")
        #expect(online.id == "online:rain")
        #expect(bundled.title == Track.rain.name)
        #expect(online.title == "在线雨声")
        #expect(bundled.isValid && online.isValid)
        let missing = try JSONDecoder().decode(DesktopQueueItem.self, from: Data("{}".utf8))
        #expect(!missing.isValid)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(online)) as? [String: Any])
        object["track"] = "rain"
        let ambiguous = try JSONDecoder().decode(DesktopQueueItem.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!ambiguous.isValid)
        #expect(!DesktopQueueItem(onlineTrack: onlineTrack(audioURL: "http://content.example.org/a.m4a")).isValid)
        #expect(!DesktopQueueItem(onlineTrack: onlineTrack(id: "")).isValid)
    }

    @Test func startValidatesQueueBoundsPositionAndOnlineServiceOnlyWhenNeeded() {
        #expect(start().isValid)
        #expect(start(serviceAddress: "not a service").isValid)
        #expect(!start(queue: []).isValid)
        #expect(start(queue: Array(repeating: DesktopQueueItem(track: .rain), count: 1000)).isValid)
        #expect(!start(queue: Array(repeating: DesktopQueueItem(track: .rain), count: 1001)).isValid)
        let online = [DesktopQueueItem(onlineTrack: onlineTrack())]
        #expect(start(queue: online, serviceAddress: "https://content.example.org").isValid)
        for address in ["", "http://content.example.org", "https://user:secret@content.example.org", "https://content.example.org?token=secret"] {
            #expect(!start(queue: online, serviceAddress: address).isValid)
        }
        for index in [-1, 1] {
            var value = start(); value.index = index
            #expect(!value.isValid)
        }
        for position in [-1.0, .infinity, .nan] {
            var value = start(); value.position = position
            #expect(!value.isValid)
        }
    }

    @Test func snapshotValidationAndCurrentItemRespectBounds() {
        #expect(snapshot().isValid)
        #expect(snapshot().currentItem == DesktopQueueItem(track: .rain))
        var value = snapshot()
        value.index = -1
        #expect(!value.isValid)
        #expect(value.currentItem == nil)
        value.index = 0; value.duration = 0; value.position = 0
        #expect(value.isValid)
        value.position = 1
        #expect(!value.isValid)
        for duration in [-1.0, .infinity, .nan] {
            value = snapshot(); value.duration = duration
            #expect(!value.isValid)
        }
        for volume: Float in [-0.1, 1.1, .infinity, .nan] {
            value = snapshot(); value.volume = volume
            #expect(!value.isValid)
        }
    }

    @Test func positionProjectionUsesLocalReceiptAndFreezesAfterThreeSeconds() {
        let value = snapshot()
        #expect(value.projectedPosition(at: receivedAt.addingTimeInterval(2), receivedAt: receivedAt, connected: true) == 12)
        #expect(value.projectedPosition(at: receivedAt.addingTimeInterval(30), receivedAt: receivedAt, connected: true) == 13)
        #expect(value.projectedPosition(at: receivedAt.addingTimeInterval(-1), receivedAt: receivedAt, connected: true) == 10)
        #expect(value.projectedPosition(at: receivedAt.addingTimeInterval(2), receivedAt: receivedAt, connected: false) == 10)
        var paused = value; paused.playing = false
        #expect(paused.projectedPosition(at: receivedAt.addingTimeInterval(2), receivedAt: receivedAt, connected: true) == 10)
        var buffering = value; buffering.buffering = true
        #expect(buffering.projectedPosition(at: receivedAt.addingTimeInterval(2), receivedAt: receivedAt, connected: true) == 10)
        var ending = value; ending.position = 119
        #expect(ending.projectedPosition(at: receivedAt.addingTimeInterval(2), receivedAt: receivedAt, connected: true) == 120)
    }

    @Test func commandsEnforceBoundsAndRejectUnrelatedArguments() {
        for action in [DesktopPlaybackCommand.Action.status, .play, .pause, .previous, .next, .release] {
            #expect(DesktopPlaybackCommand(sessionID: sessionID, action: action).isValid)
            #expect(!DesktopPlaybackCommand(sessionID: sessionID, action: action, amount: 1).isValid)
            #expect(!DesktopPlaybackCommand(sessionID: sessionID, action: action, mode: .shuffle).isValid)
            #expect(!DesktopPlaybackCommand(sessionID: sessionID, action: action, deadline: SleepDeadline(minutes: 10)).isValid)
        }
        for amount in [0.0, 1000] {
            #expect(DesktopPlaybackCommand(sessionID: sessionID, action: .seek, amount: amount).isValid)
        }
        for amount in [-1.0, .infinity, .nan] {
            #expect(!DesktopPlaybackCommand(sessionID: sessionID, action: .seek, amount: amount).isValid)
        }
        for amount in [0.0, 0.5, 1] {
            #expect(DesktopPlaybackCommand(sessionID: sessionID, action: .volume, amount: amount).isValid)
        }
        for amount in [-0.1, 1.1, .infinity, .nan] {
            #expect(!DesktopPlaybackCommand(sessionID: sessionID, action: .volume, amount: amount).isValid)
        }
        #expect(!DesktopPlaybackCommand(sessionID: sessionID, action: .seek).isValid)
        #expect(!DesktopPlaybackCommand(sessionID: sessionID, action: .volume).isValid)
        #expect(!DesktopPlaybackCommand(sessionID: sessionID, action: .mode).isValid)
        #expect(DesktopPlaybackCommand(sessionID: sessionID, action: .mode, mode: .shuffle).isValid)
        #expect(!DesktopPlaybackCommand(sessionID: sessionID, action: .mode, amount: 1, mode: .shuffle).isValid)
        #expect(!DesktopPlaybackCommand(sessionID: sessionID, action: .seek, amount: 1, mode: .single).isValid)
        #expect(DesktopPlaybackCommand(sessionID: sessionID, action: .timer).isValid)
        #expect(!DesktopPlaybackCommand(sessionID: sessionID, action: .timer, amount: 10).isValid)
    }

    @Test func timerPreservesAbsoluteDeadlineThroughRequestsAndResponses() throws {
        let deadline = SleepDeadline(minutes: 15, now: receivedAt)
        let command = DesktopPlaybackCommand(sessionID: sessionID, action: .timer, deadline: deadline)
        #expect(command.isValid)
        let request = DesktopMusicRequest(action: .command, command: command, deviceID: "phone", deviceName: "iPhone")
        let decoded = try JSONDecoder().decode(DesktopMusicRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.version == 2)
        #expect(decoded.id == request.id)
        #expect(decoded.command == command)
        #expect(decoded.command?.deadline?.date == deadline.date)
        var state = snapshot(); state.deadline = deadline
        let response = DesktopMusicResponse(id: request.id, snapshot: state, preparedID: sessionID)
        let received = try JSONDecoder().decode(DesktopMusicResponse.self, from: JSONEncoder().encode(response))
        #expect(received.version == 2)
        #expect(received.success)
        #expect(received.id == request.id)
        #expect(received.snapshot == state)
        #expect(received.preparedID == sessionID)
        #expect(received.snapshot?.deadline?.date == deadline.date)
        var invalid = deadline; invalid.date = Date(timeIntervalSince1970: .infinity)
        #expect(!DesktopPlaybackCommand(sessionID: sessionID, action: .timer, deadline: invalid).isValid)
        // A legacy deadline has no durationMinutes and must retain its exact instant too.
        let legacy = try JSONDecoder().decode(SleepDeadline.self, from: Data("{\"date\":100}".utf8))
        #expect(DesktopPlaybackCommand(sessionID: sessionID, action: .timer, deadline: legacy).isValid)
    }

    @Test func prepareRequestRoundTripsCompleteQueueAndModeLabels() throws {
        let value = start(queue: [DesktopQueueItem(track: .rain), DesktopQueueItem(onlineTrack: onlineTrack())],
                          serviceAddress: "https://content.example.org")
        let request = DesktopMusicRequest(action: .prepare, start: value, sessionID: sessionID)
        let decoded = try JSONDecoder().decode(DesktopMusicRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.start == value)
        #expect(decoded.sessionID == sessionID)
        #expect(AudioPlaybackMode.allCases.map(\.title) == ["单曲循环", "顺序循环", "随机循环"])
        #expect(AudioPlaybackMode.allCases.map(\.symbol) == ["repeat.1", "repeat", "shuffle"])
    }

    @Test func observationSubscriptionCanStopPushWithoutReleasingPlayback() throws {
        let request = DesktopMusicRequest(action: .observe, sessionID: sessionID, observing: false)
        let decoded = try JSONDecoder().decode(DesktopMusicRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.action == .observe)
        #expect(decoded.observing == false)
        #expect(decoded.sessionID == sessionID)
        #expect(decoded.command == nil)
        let hello = DesktopMusicRequest(action: .hello)
        let oldShape = try JSONDecoder().decode(DesktopMusicRequest.self, from: JSONEncoder().encode(hello))
        #expect(oldShape.observing == nil)
    }

    @Test func releaseResponseCarriesPlaybackIntentBeforeTheAtomicPause() throws {
        var paused = snapshot(); paused.playing = false
        let response = DesktopMusicResponse(id: UUID(), snapshot: paused, resumeOnRelease: true)
        let decoded = try JSONDecoder().decode(DesktopMusicResponse.self, from: JSONEncoder().encode(response))
        #expect(decoded.snapshot?.playing == false)
        #expect(decoded.resumeOnRelease == true)
        let ordinary = DesktopMusicResponse(id: UUID())
        let oldShape = try JSONDecoder().decode(DesktopMusicResponse.self, from: JSONEncoder().encode(ordinary))
        #expect(oldShape.resumeOnRelease == nil)
    }
}
