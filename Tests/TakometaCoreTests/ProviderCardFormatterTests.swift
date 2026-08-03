import XCTest
@testable import TakometaCore

final class ProviderCardFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        id: String, scope: RateLimitScope, used: Double,
        kind: WindowKind? = .weekly, resetsIn: TimeInterval? = 3600
    ) -> RateLimitWindow {
        RateLimitWindow(
            id: id, label: id, scope: scope, usedPercent: used,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) }, kind: kind)
    }

    private func cards(
        codex: (windows: [RateLimitWindow], freshness: Freshness)? = nil,
        claude: (windows: [RateLimitWindow], freshness: Freshness)? = nil,
        filter: DisplayFilter = DisplayFilter(),
        kindOrders: [ProviderID: [WindowKindCategory]] = [:]
    ) -> [ProviderCard] {
        MenuBarLabelFormatter.formatProviderCards(
            codex: codex, claude: claude, filter: filter,
            now: now, kindOrders: kindOrders)
    }

    func testRingUsesMostConstrainedVisibleWindow() {
        let result = cards(
            codex: ([
                window(id: "s", scope: .session, used: 34.9, kind: .session),
                window(id: "w", scope: .weeklyAll, used: 65.2),
            ], .fresh),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Codex")
        XCTAssertEqual(result[0].ring, .gauge(percent: 65, style: .normal))
    }

    func testRowsFollowKindOrderAndUseShortNames() {
        let result = cards(
            codex: ([
                window(id: "s", scope: .session, used: 34, kind: .session),
                window(id: "w", scope: .weeklyAll, used: 52),
                window(id: "g", scope: .model(id: "g", displayName: "GPT"), used: 10),
            ], .fresh),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)),
            kindOrders: [.codex: [.model, .session, .weekly]])

        XCTAssertEqual(result[0].rows.map(\.label), ["GPT", "5h", "1w"])
        XCTAssertEqual(result[0].rows.map(\.percent), [10, 34, 52])
    }

    func testUnavailableProducesUnavailableRingWithoutRows() {
        let result = cards(
            codex: ([], .unavailable),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result[0].ring, .unavailable)
        XCTAssertTrue(result[0].rows.isEmpty)
    }

    func testEmptyVisibleWindowsProducesUnavailableRing() {
        // 種別フィルタで全枠が非表示になった場合も 0% を描かず unavailable にする
        let result = cards(
            codex: ([window(id: "w", scope: .weeklyAll, used: 52)], .fresh),
            filter: DisplayFilter(
                codex: ProviderDisplayFilter(showWeekly: false),
                claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result[0].ring, .unavailable)
    }

    func testAuthenticationRequiredProducesLockRing() {
        let result = cards(
            codex: ([window(id: "w", scope: .weeklyAll, used: 52)], .authenticationRequired),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result[0].ring, .authenticationRequired)
        XCTAssertTrue(result[0].rows.isEmpty)
    }

    func testStaleSetsFlagButKeepsGauge() {
        let result = cards(
            codex: ([window(id: "w", scope: .weeklyAll, used: 52)], .stale),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertTrue(result[0].isStale)
        XCTAssertEqual(result[0].ring, .gauge(percent: 52, style: .normal))
    }

    func testHiddenProviderProducesNoCard() {
        let result = cards(
            codex: ([window(id: "w", scope: .weeklyAll, used: 52)], .fresh),
            claude: ([window(id: "w", scope: .weeklyAll, used: 10)], .fresh),
            filter: DisplayFilter(codex: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.map(\.name), ["Claude"])
    }

    func testProviderOrderFollowsOrderArgument() {
        let result = MenuBarLabelFormatter.formatProviderCards(
            codex: ([window(id: "w", scope: .weeklyAll, used: 52)], .fresh),
            claude: ([window(id: "s", scope: .session, used: 10, kind: .session)], .fresh),
            filter: DisplayFilter(),
            now: now,
            order: [.claude, .codex])

        XCTAssertEqual(result.map(\.name), ["Claude", "Codex"])
    }
}
