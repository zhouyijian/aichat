import XCTest
@testable import AIChat

@MainActor
final class StreamingThrottlerTests: XCTestCase {

    func testCoalescesRapidChangesIntoSingleTick() async {
        let messageID = UUID()
        var events: [(UUID, Bool)] = []

        let throttler = StreamingThrottler(
            intervalNs: 20_000_000,
            shouldPinToBottom: { true },
            onTick: { id, shouldPin in
                events.append((id, shouldPin))
            }
        )

        throttler.markChanged(id: messageID)
        throttler.markChanged(id: messageID)
        throttler.markChanged(id: messageID)

        try? await Task.sleep(nanoseconds: 55_000_000)
        throttler.stop(flushPending: false)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.0, messageID)
        XCTAssertEqual(events.first?.1, true)
    }

    func testRefreshRestoresPinningWhenUserReturnsToBottom() async {
        let messageID = UUID()
        var isNearBottom = true
        var events: [(UUID, Bool)] = []

        let throttler = StreamingThrottler(
            intervalNs: 20_000_000,
            shouldPinToBottom: { isNearBottom },
            onTick: { id, shouldPin in
                events.append((id, shouldPin))
            }
        )

        throttler.markChanged(id: messageID)
        throttler.disablePinToBottomForCurrentStream()
        isNearBottom = true
        throttler.refreshPinToBottomForCurrentStream()

        try? await Task.sleep(nanoseconds: 55_000_000)
        throttler.stop(flushPending: false)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.0, messageID)
        XCTAssertEqual(events.first?.1, true)
    }

    func testStopFlushesPendingChangeWithCurrentPinState() {
        let messageID = UUID()
        var events: [(UUID, Bool)] = []

        let throttler = StreamingThrottler(
            intervalNs: 1_000_000_000,
            shouldPinToBottom: { true },
            onTick: { id, shouldPin in
                events.append((id, shouldPin))
            }
        )

        throttler.markChanged(id: messageID)
        throttler.disablePinToBottomForCurrentStream()
        throttler.stop(flushPending: true)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.0, messageID)
        XCTAssertEqual(events.first?.1, false)
    }
}
