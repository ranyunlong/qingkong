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
    }
}
