import XCTest
@testable import AIChat

final class MessageCodableTests: XCTestCase {

    func testMaxTokenHitCountRoundTrips() throws {
        let message = Message(
            role: .assistant,
            content: "长回答片段",
            maxTokenHitCount: 2,
            status: .needsContinuation
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        XCTAssertEqual(decoded.maxTokenHitCount, 2)
        XCTAssertEqual(decoded.status, .needsContinuation)
        XCTAssertEqual(decoded.contentText, "长回答片段")
    }

    func testDecodesOlderMessagesWithoutMaxTokenHitCount() throws {
        let message = Message(
            role: .assistant,
            content: "旧版本消息",
            maxTokenHitCount: 3,
            status: .success
        )

        let data = try JSONEncoder().encode(message)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "maxTokenHitCount")
        let oldData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(Message.self, from: oldData)

        XCTAssertNil(decoded.maxTokenHitCount)
        XCTAssertEqual(decoded.status, .success)
        XCTAssertEqual(decoded.contentText, "旧版本消息")
    }
}
