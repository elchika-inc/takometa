import XCTest
@testable import TakometaCore

final class NotificationIdentifierTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMicrosecondJitterUsesSameIdentifier() {
        let before = NotificationEvent.thresholdExceeded(
            provider: .claude,
            windowID: "claude|weekly|fable",
            windowLabel: "Fable weekly",
            usedPercent: 82,
            threshold: 80,
            resetsAt: now.addingTimeInterval(-0.005))
        let after = NotificationEvent.thresholdExceeded(
            provider: .claude,
            windowID: "claude|weekly|fable",
            windowLabel: "Fable weekly",
            usedPercent: 83,
            threshold: 80,
            resetsAt: now.addingTimeInterval(0.005))

        XCTAssertEqual(
            NotificationIdentifier.identifier(for: before),
            NotificationIdentifier.identifier(for: after))
    }

    func testWindowRenewalUsesDifferentIdentifier() {
        let current = NotificationEvent.limitReached(
            provider: .codex,
            windowID: "codex|session|session",
            windowLabel: "5 hours",
            resetsAt: now)
        let renewed = NotificationEvent.limitReached(
            provider: .codex,
            windowID: "codex|session|session",
            windowLabel: "5 hours",
            resetsAt: now.addingTimeInterval(5 * 3600))

        XCTAssertNotEqual(
            NotificationIdentifier.identifier(for: current),
            NotificationIdentifier.identifier(for: renewed))
    }

    func testSameDisplayNameWithDifferentStateKeyUsesDifferentIdentifier() {
        let first = NotificationEvent.paceDanger(
            provider: .claude,
            windowID: "claude|weekly|model-a",
            windowLabel: "Same",
            projectedLimitAt: now.addingTimeInterval(1800),
            resetsAt: now.addingTimeInterval(3600))
        let second = NotificationEvent.paceDanger(
            provider: .claude,
            windowID: "claude|weekly|model-b",
            windowLabel: "Same",
            projectedLimitAt: now.addingTimeInterval(1800),
            resetsAt: now.addingTimeInterval(3600))

        XCTAssertNotEqual(
            NotificationIdentifier.identifier(for: first),
            NotificationIdentifier.identifier(for: second))
    }

    func testRecoveredUsesBasisResetsAt() {
        let first = NotificationEvent.recovered(
            provider: .codex,
            windowID: "codex|weekly|weeklyAll",
            windowLabel: "Weekly",
            basisResetsAt: now)
        let second = NotificationEvent.recovered(
            provider: .codex,
            windowID: "codex|weekly|weeklyAll",
            windowLabel: "Weekly",
            basisResetsAt: now.addingTimeInterval(7 * 86400))

        XCTAssertNotEqual(
            NotificationIdentifier.identifier(for: first),
            NotificationIdentifier.identifier(for: second))
    }

    func testDailyUsesDayString() {
        let first = NotificationEvent.dailyExceeded(
            provider: .claude,
            windowID: "claude|weekly|weeklyAll",
            windowLabel: "Weekly",
            consumedPercent: 20,
            threshold: 20,
            day: "2027-01-15")
        let second = NotificationEvent.dailyExceeded(
            provider: .claude,
            windowID: "claude|weekly|weeklyAll",
            windowLabel: "Weekly",
            consumedPercent: 25,
            threshold: 20,
            day: "2027-01-16")

        XCTAssertEqual(
            NotificationIdentifier.identifier(for: first),
            "dailyExceeded:claude|weekly|weeklyAll:2027-01-15")
        XCTAssertNotEqual(
            NotificationIdentifier.identifier(for: first),
            NotificationIdentifier.identifier(for: second))
    }
}
