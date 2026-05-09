import XCTest
@testable import AIChat

final class StreamingContinuationPrefixFilterTests: XCTestCase {

    func testDropsDuplicatedContinuationPrefix() {
        let filter = StreamingContinuationPrefixFilter(
            existingText: "前文内容。\n地面聚变实验： ITER 正式运行"
        )

        let output = filter.consume("地面聚变实验： ITER 正式运行\n后续重点是商业化验证。")

        XCTAssertEqual(output, "\n后续重点是商业化验证。")
        XCTAssertTrue(filter.isResolved)
    }

    func testDropsLeadingWhitespaceBeforeDuplicatedPrefix() {
        let filter = StreamingContinuationPrefixFilter(
            existingText: "结论：太阳能帆依然需要长期验证"
        )

        let output = filter.consume("\n\n结论：太阳能帆依然需要长期验证，并进入工程化阶段。")

        XCTAssertEqual(output, "，并进入工程化阶段。")
        XCTAssertTrue(filter.isResolved)
    }

    func testKeepsNonDuplicatedContinuationPrefixOnFlush() {
        let filter = StreamingContinuationPrefixFilter(
            existingText: "上一段已经完整结束。"
        )

        XCTAssertNil(filter.consume("下一阶段是商业化验证。"))

        let output = filter.flush()
        XCTAssertEqual(output, "下一阶段是商业化验证。")
        XCTAssertTrue(filter.isResolved)
    }

    func testAfterResolutionPassesThroughDeltas() {
        let filter = StreamingContinuationPrefixFilter(existingText: "ABCDEFGH")

        XCTAssertEqual(filter.consume("ABCDEFGH\nIJK"), "\nIJK")
        XCTAssertEqual(filter.consume("LMN"), "LMN")
    }

    func testWaitsAcrossSmallDuplicatedPrefixDeltas() {
        let filter = StreamingContinuationPrefixFilter(
            existingText: "这一段回答的最后一句会被模型在续写时重复。"
        )

        XCTAssertNil(filter.consume("最后一句会被"))
        XCTAssertNil(filter.consume("模型在续写时"))
        let output = filter.consume("重复。新的内容继续。")

        XCTAssertEqual(output, "新的内容继续。")
        XCTAssertTrue(filter.isResolved)
    }
}
