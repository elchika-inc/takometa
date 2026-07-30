import XCTest
@testable import TakometaCore

final class LiveFixtureTests: XCTestCase {
    func testLiveCodexFixtureDecodes() throws {
        let url = Bundle.module.url(
            forResource: "Fixtures/codex/live_masked", withExtension: "json")!
        let result = try CodexRateLimitsDecoder.decode(try Data(contentsOf: url))
        XCTAssertFalse(result.windows.isEmpty)
    }

    func testLiveClaudeFixtureDecodes() throws {
        let url = Bundle.module.url(
            forResource: "Fixtures/claude/live_masked", withExtension: "json")!
        let result = try ClaudeOAuthUsageDecoder.decode(
            try Data(contentsOf: url), now: Date())
        XCTAssertFalse(result.windows.isEmpty)
    }
}
