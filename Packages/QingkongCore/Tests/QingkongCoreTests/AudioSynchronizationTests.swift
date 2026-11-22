import Foundation
import Testing
@testable import QingkongCore

struct AudioSynchronizationTests {
    @Test func audioRepliesCarryFreshnessForPhoneUpdates() throws {
        let before = Date.now.timeIntervalSinceReferenceDate
        let data = try JSONEncoder().encode(AudioReply(id: UUID(), state: AudioState()))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let timestamp = try #require(object["updatedAt"] as? Double)
        #expect(timestamp >= before)
        #expect(timestamp <= Date.now.timeIntervalSinceReferenceDate)
        let decoded = try JSONDecoder().decode(AudioReply.self, from: data)
        #expect(decoded.updatedAt != nil)
    }

    @Test func legacyPhoneReplyStillDecodesWithoutFreshness() throws {
        let data = Data("""
        {"id":"B3192E00-64D7-4AE6-8F3A-BE504E98C5D7","state":{"track":"ocean","playing":true,"volume":0.25}}
        """.utf8)
        let reply = try JSONDecoder().decode(AudioReply.self, from: data)
        #expect(reply.updatedAt == nil)
        #expect(reply.state.track == .ocean)
        #expect(reply.state.playing)
        #expect(reply.state.volume == 0.25)
        #expect(reply.state.onlineTrackID == nil)
        #expect(reply.state.onlineArtworkURL == nil)
        #expect(reply.state.artwork == .bundled(Track.ocean.image))
        #expect(reply.state.buffering == nil)
        #expect(reply.state.displayTitle == Track.ocean.name)
    }

    @Test func onlineTitleAndRealBufferingStateReachWatchWithoutChangingLocalTrack() throws {
        var state = AudioState()
        state.onlineTrackID = "track-123"
        state.onlineTitle = "线上海浪"
        state.buffering = true
        let restored = try JSONDecoder().decode(AudioState.self, from: JSONEncoder().encode(state))
        #expect(restored.displayTitle == "线上海浪")
        #expect(restored.buffering == true)
        #expect(!restored.playing)
        #expect(restored.track == .rain)
    }

    @Test func publicArtworkSurvivesPhoneWatchStateRoundTrip() throws {
        let data = Data("""
        {"track":"rain","playing":true,"volume":0.4,"onlineTrackID":"online-1","onlineTitle":"Public track","onlineArtworkURL":"https://example.invalid/cover.jpg"}
        """.utf8)
        let state = try JSONDecoder().decode(AudioState.self, from: data)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        #expect(object["onlineArtworkURL"] as? String == "https://example.invalid/cover.jpg")
        #expect(state.artwork == .remote(URL(string: "https://example.invalid/cover.jpg")!))
    }

    @Test func publicTracksWithoutSafeArtworkNeverUseThePreviousBuiltInCover() throws {
        var state = AudioState()
        state.track = .ocean
        state.onlineTrackID = "online-1"
        #expect(state.artwork == .placeholder)
        for address in ["http://example.invalid/cover.jpg", "file:///private/cover.jpg", "https://user:password@example.invalid/cover.jpg"] {
            state.onlineArtworkURL = URL(string: address)
            #expect(state.artwork == .placeholder)
        }
        let oldState = Data("""
        {"track":"ocean","playing":true,"volume":0.4,"onlineTrackID":"older-phone-track","onlineTitle":"Older phone"}
        """.utf8)
        #expect(try JSONDecoder().decode(AudioState.self, from: oldState).artwork == .placeholder)
    }

    @Test func builtInSelectionUsesItsOwnCoverEvenWithStalePublicMetadata() {
        var state = AudioState()
        state.track = .ocean
        state.onlineArtworkURL = URL(string: "https://example.invalid/stale-cover.jpg")
        #expect(state.artwork == .bundled(Track.ocean.image))
    }
}
