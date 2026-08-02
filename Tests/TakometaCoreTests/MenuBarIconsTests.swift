import XCTest
@testable import TakometaCore

final class MenuBarIconsTests: XCTestCase {
    func testGaugeLevelBoundaries() {
        let cases: [(Double, GaugeLevel)] = [
            (0, .zero), (19.9, .zero),
            (20, .low), (39.9, .low),
            (40, .mid), (59.9, .mid),
            (60, .high), (79.9, .high),
            (80, .max), (100, .max), (120, .max),
        ]
        for (percent, expected) in cases {
            XCTAssertEqual(
                GaugeLevel.forUsedPercent(percent), expected,
                "\(percent)% の量子化が想定と異なる")
        }
    }

    func testNegativePercentFallsToZero() {
        XCTAssertEqual(GaugeLevel.forUsedPercent(-5), .zero)
    }

    func testNonFinitePercentFallsToMax() {
        // 異常値は危険側へ倒す。針が振り切れていれば利用者が気づける
        XCTAssertEqual(GaugeLevel.forUsedPercent(.nan), .max)
        XCTAssertEqual(GaugeLevel.forUsedPercent(.infinity), .max)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        id: String, scope: RateLimitScope, used: Double,
        kind: WindowKind? = .weekly, resetsIn: TimeInterval? = 3600
    ) -> RateLimitWindow {
        RateLimitWindow(
            id: id, label: id, scope: scope, usedPercent: used,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) }, kind: kind)
    }

    private func icons(
        codex: (windows: [RateLimitWindow], freshness: Freshness)? = nil,
        claude: (windows: [RateLimitWindow], freshness: Freshness)? = nil,
        filter: DisplayFilter = DisplayFilter()
    ) -> MenuBarIcons {
        MenuBarLabelFormatter.formatCombinedIcons(
            codex: codex, claude: claude, filter: filter, now: now)
    }

    func testOneIconPerVisibleProviderUsesMostConstrainedWindow() {
        let result = icons(
            codex: ([
                window(id: "s", scope: .session, used: 34, kind: .session),
                window(id: "w", scope: .weeklyAll, used: 65),
            ], .fresh),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.icons.count, 1)
        XCTAssertEqual(result.icons[0].glyph, .gauge(.high))
    }

    func testHiddenProviderProducesNoIcon() {
        let result = icons(
            codex: ([window(id: "w", scope: .weeklyAll, used: 10)], .fresh),
            filter: DisplayFilter(
                codex: ProviderDisplayFilter(show: false),
                claude: ProviderDisplayFilter(show: false)))

        XCTAssertTrue(result.icons.isEmpty)
    }

    func testUnavailableProducesUnavailableGlyphNotZeroGauge() {
        let result = icons(
            codex: ([], .unavailable),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.icons[0].glyph, .unavailable)
    }

    func testEmptyWindowListProducesUnavailableGlyph() {
        let result = icons(
            codex: ([], .fresh),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.icons[0].glyph, .unavailable)
    }

    func testAuthenticationRequiredProducesLockGlyph() {
        let result = icons(
            codex: ([window(id: "w", scope: .weeklyAll, used: 50)], .authenticationRequired),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.icons[0].glyph, .authenticationRequired)
    }

    func testStaleIsMarkedWithoutChangingGlyph() {
        let result = icons(
            codex: ([window(id: "w", scope: .weeklyAll, used: 50)], .stale),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.icons[0].glyph, .gauge(.mid))
        XCTAssertTrue(result.icons[0].isStale)
        XCTAssertTrue(result.icons[0].accessibilityText.contains("更新が古い"))
    }

    func testAccessibilityTextJoinsProvidersWithTwoSpaces() {
        let result = icons(
            codex: ([window(id: "w", scope: .weeklyAll, used: 49)], .fresh),
            claude: ([window(id: "s", scope: .session, used: 20, kind: .session)], .fresh))

        XCTAssertEqual(result.accessibilityText, "CX 週間枠 49%  CL 5時間枠 20%")
    }
}
