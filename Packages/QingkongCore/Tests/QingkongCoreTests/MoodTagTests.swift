import XCTest
@testable import QingkongCore

final class MoodTagTests: XCTestCase {
    func testOldMoodPayloadDecodesWithoutTags() throws {
        let old = MoodRecord(mood: 3, stress: 2, note: "旧记录")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "tags")
        let decoded = try JSONDecoder().decode(MoodRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.tags, [])
    }

    func testTagsRoundTripWithoutChangingDiaryOrIdentity() throws {
        let record = MoodRecord(mood: 4, stress: 2, note: "今天", tags: [.work, .coffee])
        XCTAssertEqual(try JSONDecoder().decode(MoodRecord.self, from: JSONEncoder().encode(record)), record)
        XCTAssertEqual(record.tags, [.work, .coffee])
    }
}
