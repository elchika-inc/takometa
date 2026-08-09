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
        XCTAssertEqual(GaugeLevel.forUsedPercent(-.infinity), .max)
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
        filter: DisplayFilter = DisplayFilter(),
        order: [ProviderID] = [.codex, .claude]
    ) -> MenuBarIcons {
        MenuBarLabelFormatter.formatCombinedIcons(
            codex: codex, claude: claude, filter: filter, now: now,
            order: order)
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

        XCTAssertEqual(result.icons, [MenuBarIcon(
            glyph: .unavailable, style: .normal, isStale: false,
            accessibilityText: "Codex 取得できません")])
    }

    func testEmptyWindowListProducesUnavailableGlyph() {
        let result = icons(
            codex: ([], .fresh),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.icons[0].glyph, .unavailable)
    }

    func testAuthenticationRequiredProducesLockGlyph() {
        let result = icons(
            codex: ([], .authenticationRequired),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.icons, [MenuBarIcon(
            glyph: .authenticationRequired, style: .normal, isStale: false,
            accessibilityText: "Codex 要認証")])
    }

    func testAuthenticationRequiredIgnoresCachedWindows() {
        let result = icons(
            codex: ([window(id: "w", scope: .weeklyAll, used: 50)], .authenticationRequired),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.icons, [MenuBarIcon(
            glyph: .authenticationRequired, style: .normal, isStale: false,
            accessibilityText: "Codex 要認証")])
    }

    func testStaleIsMarkedWithoutChangingGlyph() {
        let result = icons(
            codex: ([window(id: "w", scope: .weeklyAll, used: 50)], .stale),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.icons, [MenuBarIcon(
            glyph: .gauge(.mid), style: .normal, isStale: true,
            accessibilityText: "Codex 週間枠 50%（更新が古い）")])
    }

    func testAccessibilityTextJoinsProvidersWithTwoSpaces() {
        let result = icons(
            codex: ([window(id: "w", scope: .weeklyAll, used: 49)], .fresh),
            claude: ([window(id: "s", scope: .session, used: 20, kind: .session)], .fresh))

        XCTAssertEqual(result.accessibilityText, "Codex 週間枠 49%  Claude 5時間枠 20%")
    }

    func testNilInputProducesUnavailableIconForVisibleProvider() {
        let result = icons(
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.icons, [MenuBarIcon(
            glyph: .unavailable, style: .normal, isStale: false,
            accessibilityText: "Codex 取得できません")])
    }

    func testProviderOrderUsesDisplayNames() {
        let result = icons(
            codex: ([window(id: "cw", scope: .weeklyAll, used: 30)], .fresh),
            claude: ([window(id: "cs", scope: .session, used: 40, kind: .session)], .fresh),
            order: [.claude, .codex])

        XCTAssertEqual(
            result.icons.map(\.accessibilityText),
            ["Claude 5時間枠 40%", "Codex 週間枠 30%"])
    }

    func testWindowKindFiltersAreAppliedBeforeMostConstrainedSelection() {
        let cases: [([RateLimitWindow], ProviderDisplayFilter, String)] = [
            ([
                window(id: "s", scope: .session, used: 95, kind: .session),
                window(id: "w", scope: .weeklyAll, used: 85),
            ], .init(showSession: false), "Codex 週間枠 85%"),
            ([
                window(id: "w", scope: .weeklyAll, used: 95),
                window(id: "m", scope: .model(id: "model", displayName: "Model"), used: 75),
            ], .init(showWeekly: false), "Codex Model 75%"),
            ([
                window(id: "m", scope: .model(id: "model", displayName: "Model"), used: 95),
                window(id: "s", scope: .session, used: 75, kind: .session),
            ], .init(showModel: false), "Codex 5時間枠 75%"),
        ]

        for (windows, providerFilter, expectedText) in cases {
            let result = icons(
                codex: (windows, .fresh),
                filter: DisplayFilter(
                    codex: providerFilter,
                    claude: ProviderDisplayFilter(show: false)))

            XCTAssertEqual(result.icons[0].accessibilityText, expectedText)
        }
    }

    func testIconStyleReflectsUsagePaceAndExhaustion() {
        let cases: [(Double, TimeInterval, SegmentStyle)] = [
            (10, 6 * 86400, .normal),
            (20, 6 * 86400, .warning),
            (100, 3600, .critical),
        ]

        for (used, resetsIn, expectedStyle) in cases {
            let result = icons(
                codex: ([window(
                    id: "w", scope: .weeklyAll, used: used, resetsIn: resetsIn
                )], .fresh),
                filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

            XCTAssertEqual(result.icons[0].style, expectedStyle)
        }
    }

    func testNonFiniteAndOutOfRangePercentAreSafeInCombinedFormatter() {
        let cases = [Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude]

        for used in cases {
            let result = icons(
                codex: ([window(id: "w", scope: .weeklyAll, used: used)], .fresh),
                filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

            XCTAssertEqual(result.icons[0].glyph, .gauge(.max))
            XCTAssertEqual(result.icons[0].accessibilityText, "Codex 週間枠 値不明")
        }
    }

    func testNonFinitePercentWinsSelectionAgainstFiniteWindow() {
        for used in [Double.nan, Double.infinity, -Double.infinity] {
            let result = icons(
                codex: ([
                    window(id: "finite", scope: .session, used: 99, kind: .session),
                    window(id: "invalid", scope: .weeklyAll, used: used),
                ], .fresh),
                filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

            XCTAssertEqual(result.icons[0].glyph, .gauge(.max))
            XCTAssertEqual(result.icons[0].accessibilityText, "Codex 週間枠 値不明")
        }
    }

    func testAccessibilityPercentIsTruncated() {
        let result = icons(
            codex: ([window(id: "w", scope: .weeklyAll, used: 49.9)], .fresh),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.icons[0].accessibilityText, "Codex 週間枠 49%")
    }
}
