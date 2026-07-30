import XCTest
@testable import TakometaCore

final class ClaudeOAuthUsageDecoderTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(
            forResource: "Fixtures/claude/\(name)", withExtension: "json")!
        return try Data(contentsOf: url)
    }

    func testNormalDecodesLimitsArrayAsSourceOfTruth() throws {
        let result = try ClaudeOAuthUsageDecoder.decode(try fixture("normal"), now: Date())
        XCTAssertEqual(result.windows.count, 3)
        let fable = result.windows.first {
            $0.scope == .model(id: nil, displayName: "Fable")
        }
        XCTAssertNotNil(fable)
        XCTAssertEqual(fable?.usedPercent, 17)
        XCTAssertEqual(fable?.isActive, true)
        XCTAssertEqual(fable?.severity, "normal")
        XCTAssertNotNil(fable?.resetsAt)
        // crosscheck: トップレベル five_hour / seven_day は突合用に保持
        XCTAssertEqual(result.crosscheck["five_hour"], 8.0)
        XCTAssertEqual(result.crosscheck["seven_day"], 10.0)
    }

    func testLegacyModelFieldsDecodeWhenLimitsAbsent() throws {
        let result = try ClaudeOAuthUsageDecoder.decode(
            try fixture("legacy_model_fields"), now: Date())
        XCTAssertEqual(result.windows.count, 4)
        XCTAssertTrue(result.windows.contains {
            $0.scope == .model(id: nil, displayName: "Opus") && $0.usedPercent == 78.0
        })
        XCTAssertTrue(result.windows.contains { $0.scope == .session && $0.usedPercent == 41.0 })
    }

    func testEmptyLimitsDoesNotFallBackToTopLevelWindows() throws {
        let data = #"{"five_hour":{"utilization":8.0},"seven_day":{"utilization":10.0},"limits":[]}"#
            .data(using: .utf8)!
        let result = try ClaudeOAuthUsageDecoder.decode(data, now: Date())

        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.crosscheck["five_hour"], 8.0)
        XCTAssertEqual(result.crosscheck["seven_day"], 10.0)
    }

    func testMissingValuesProduceNoWindow() throws {
        let result = try ClaudeOAuthUsageDecoder.decode(
            try fixture("missing_values"), now: Date())
        // percent の無い session は作らない（0% 禁止）。resets_at 欠落だけなら作る。
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows[0].scope, .weeklyAll)
        XCTAssertEqual(result.windows[0].usedPercent, 12)
        XCTAssertNil(result.windows[0].resetsAt)
    }

    func testUnknownFieldsAreLoggedNotFatal() throws {
        let result = try ClaudeOAuthUsageDecoder.decode(
            try fixture("unknown_fields"), now: Date())
        XCTAssertTrue(result.unknownKeys.contains("tangelo"))
        XCTAssertTrue(result.unknownKeys.contains("nimbus_quill"))
        XCTAssertFalse(result.unknownKeys.contains("five_hour"))
        XCTAssertTrue(result.windows.contains {
            $0.scope == .model(id: "some-model", displayName: "SomeModel")
        })
    }

    func testKindMapping() throws {
        let json = """
        {"limits": [
          {"kind": "session", "percent": 20, "resets_at": "2026-07-19T13:30:00Z"},
          {"kind": "weekly_all", "percent": 13, "resets_at": "2026-07-24T15:00:00Z"},
          {"kind": "weekly_scoped", "percent": 21, "resets_at": "2026-07-24T15:00:00Z", "model": "Fable"},
          {"kind": "mystery_kind", "percent": 5, "resets_at": "2026-07-24T15:00:00Z"}
        ]}
        """
        let result = try ClaudeOAuthUsageDecoder.decode(
            Data(json.utf8), now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(result.windows[0].kind, .session)
        XCTAssertEqual(result.windows[1].kind, .weekly)
        XCTAssertEqual(result.windows[2].kind, .weekly)
        XCTAssertNil(result.windows[3].kind)
    }
}
