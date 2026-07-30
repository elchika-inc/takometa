import XCTest
@testable import TakometaCore

final class UsagePaceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func window(
        used: Double,
        kind: WindowKind? = .session,
        resetsIn: TimeInterval? = 3600
    ) -> RateLimitWindow {
        RateLimitWindow(
            id: "t", label: "t", scope: .session,
            usedPercent: used,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) },
            kind: kind)
    }

    func testNormalCase() {
        let pace = UsagePace.calculate(
            window: window(used: 50), freshness: .fresh, now: now)!
        XCTAssertEqual(pace.averagePercentPerHour, 12.5, accuracy: 0.001)
        XCTAssertEqual(pace.projectedLimitAt!.timeIntervalSince(now), 4 * 3600, accuracy: 1)
        XCTAssertTrue(pace.willLastToReset)
    }

    func testWillNotLastToReset() {
        let pace = UsagePace.calculate(
            window: window(used: 90), freshness: .fresh, now: now)!
        XCTAssertFalse(pace.willLastToReset)
    }

    func testNilCases() {
        XCTAssertNil(UsagePace.calculate(
            window: window(used: 50), freshness: .stale, now: now))
        XCTAssertNil(UsagePace.calculate(
            window: window(used: 50, kind: nil), freshness: .fresh, now: now))
        XCTAssertNil(UsagePace.calculate(
            window: window(used: 50, resetsIn: nil), freshness: .fresh, now: now))
        XCTAssertNil(UsagePace.calculate(
            window: window(used: 50, resetsIn: -60), freshness: .fresh, now: now))
        XCTAssertNil(UsagePace.calculate(
            window: window(used: 0), freshness: .fresh, now: now))
        XCTAssertNil(UsagePace.calculate(
            window: window(used: 100), freshness: .fresh, now: now))
        XCTAssertNil(UsagePace.calculate(
            window: window(used: 50, resetsIn: 6 * 3600), freshness: .fresh, now: now))
    }
}
