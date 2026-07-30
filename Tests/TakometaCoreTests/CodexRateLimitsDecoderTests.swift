import XCTest
@testable import TakometaCore

final class CodexRateLimitsDecoderTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(
            forResource: "Fixtures/codex/\(name)", withExtension: "json")!
        return try Data(contentsOf: url)
    }

    func testMultiBucketDecodesModelSpecificLimit() throws {
        let result = try CodexRateLimitsDecoder.decode(try fixture("multi_bucket"))
        // codex バケットの週間枠 + モデルバケットの週間枠 = 2
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertTrue(result.windows.contains {
            $0.scope == .weeklyAll && $0.usedPercent == 42
        })
        let spark = result.windows.first {
            $0.scope == .model(id: "codex_bengalfox", displayName: "GPT-5.3-Codex-Spark")
        }
        XCTAssertNotNil(spark)
        XCTAssertEqual(spark?.resetsAt, Date(timeIntervalSince1970: 1_785_067_490))
    }

    func testPrimaryIsNotAssumedToBeSession() throws {
        // 実測: primary が週間枠になる環境がある（設計書 §2.1）
        let result = try CodexRateLimitsDecoder.decode(try fixture("multi_bucket"))
        let codexWindows = result.windows.filter { $0.scope == .weeklyAll }
        XCTAssertEqual(codexWindows.count, 1)
        XCTAssertTrue(result.windows.allSatisfy { $0.scope != .session })
    }

    func testSingleBucketFallbackWithSecondary() throws {
        let result = try CodexRateLimitsDecoder.decode(
            try fixture("single_bucket_with_secondary"))
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertTrue(result.windows.contains { $0.scope == .session && $0.usedPercent == 34 })
        XCTAssertTrue(result.windows.contains { $0.scope == .weeklyAll && $0.usedPercent == 52 })
    }

    func testMissingPercentProducesNoWindow() throws {
        let result = try CodexRateLimitsDecoder.decode(try fixture("missing_values"))
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.unknownKeys.isEmpty)
    }

    func testKindCarriedToWindow() throws {
        let json = """
        {"rateLimits": {"limitId": "codex",
          "primary": {"usedPercent": 34, "windowDurationMins": 300, "resetsAt": 1785070352},
          "secondary": {"usedPercent": 52, "windowDurationMins": 10080, "resetsAt": 1785070352}}}
        """
        let result = try CodexRateLimitsDecoder.decode(Data(json.utf8))
        XCTAssertEqual(result.windows[0].kind, .session)
        XCTAssertEqual(result.windows[1].kind, .weekly)
    }
}
