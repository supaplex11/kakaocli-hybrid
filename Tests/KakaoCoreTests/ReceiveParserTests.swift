import XCTest
@testable import KakaoCore

final class ReceiveParserTests: XCTestCase {
    func payload(_ id: String = "9007199254740993_9007199254740995", date: Any = 123.5) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["req": ["iden": id, "titl": "Synthetic sender", "body": "synthetic", "atta": [["pat": "/synthetic/avatar"]]], "date": date], format: .binary, options: 0)
    }
    func testIdentityAndUnknowns() throws {
        let observation = try XCTUnwrap(NotificationParser.parse(payload()))
        let event = ReceiveEvent(account: "fixture", observation: observation, observedAt: Date(timeIntervalSince1970: 0))
        let data = try event.json()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["chat_id"] as? String, "9007199254740993")
        XCTAssertTrue(json["sender_id"] is NSNull)
        XCTAssertTrue(json["is_from_me"] is NSNull)
        XCTAssertTrue(json["verified_chat_name"] is NSNull)
        XCTAssertNotEqual(event.eventId, ReceiveEvent(account: "other", observation: observation, observedAt: Date()).eventId)
        XCTAssertEqual(event.eventId, ReceiveEvent(account: "fixture", observation: observation, observedAt: Date()).eventId)
    }
    func testMalformed() throws {
        XCTAssertNil(NotificationParser.parse(Data("garbage".utf8)))
        for id in ["1", "1_2_3", "-1_2", "1_x", "18446744073709551616_1", "01_2"] {
            XCTAssertNil(NotificationParser.parse(try payload(id)))
        }
    }
    func testDatesAndHiddenPreview() throws {
        for date: Any in [123, 123.0, "123", Date(timeIntervalSinceReferenceDate: 123)] {
            XCTAssertEqual(NotificationParser.parse(try payload(date: date))?.notificationAt, Date(timeIntervalSinceReferenceDate: 123))
        }
        let data = try PropertyListSerialization.data(fromPropertyList: ["req": ["iden": "1_2"]], format: .xml, options: 0)
        let o = try XCTUnwrap(NotificationParser.parse(data))
        XCTAssertNil(o.text); XCTAssertNil(o.attachmentPath); XCTAssertNil(o.notificationAt)
    }
}
