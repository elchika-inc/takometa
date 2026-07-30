import XCTest
@testable import TakometaCore

final class MenuBarLabelFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        id: String,
        scope: RateLimitScope,
        used: Double,
        kind: WindowKind? = .weekly,
        resetsIn: TimeInterval? = 3600
    ) -> RateLimitWindow {
        RateLimitWindow(
            id: id, label: id, scope: scope, usedPercent: used,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) }, kind: kind)
    }

    private func format(
        _ windows: [RateLimitWindow],
        provider: ProviderID = .codex,
        freshness: Freshness = .fresh,
        mode: DisplayMode = .full,
        customPrefix: String = "",
        kindOrder: [WindowKindCategory] = WindowKindCategory.defaultOrder
    ) -> MenuBarLabel {
        MenuBarLabelFormatter.format(
            provider: provider, windows: windows,
            freshness: freshness, now: now, mode: mode,
            customPrefix: customPrefix, kindOrder: kindOrder)
    }

    private func fullSet() -> [RateLimitWindow] {
        [
            window(id: "session", scope: .session, used: 34, kind: .session),
            window(id: "weekly", scope: .weeklyAll, used: 52),
            window(id: "g", scope: .model(id: "g", displayName: "GPT"), used: 78),
            window(id: "f", scope: .model(id: "f", displayName: "Fable"), used: 65),
        ]
    }

    private func numericMultiset(_ label: MenuBarLabel) -> [String] {
        label.segments.map(\.text)
            .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            .sorted()
    }

    private func overflowText(_ label: MenuBarLabel) -> String? {
        label.segments.map(\.text).first { $0.hasPrefix(" +") }
    }

    func testDefaultKindOrderOmitsBasicMarkers() {
        XCTAssertEqual(format(fullSet()).text, "CX 34|52|G78|F65")
    }

    func testSwappedSessionAndWeeklyRestoresMarkers() {
        XCTAssertEqual(
            format(fullSet(), kindOrder: [.weekly, .session, .model]).text,
            "CX W52|H34|G78|F65")
    }

    func testModelBetweenBasicsRestoresMarkers() {
        XCTAssertEqual(
            format(fullSet(), kindOrder: [.session, .model, .weekly]).text,
            "CX H34|G78|F65|W52")
    }

    func testModelFirstRestoresMarkersAndKeepsAbbreviations() {
        // model ブロックが session/weekly をまたいで移動する（N-3 の回帰。
        // resolveAbbreviations を並べ替え前に呼ぶ実装では G/F が脱落する）
        XCTAssertEqual(
            format(fullSet(), kindOrder: [.model, .session, .weekly]).text,
            "CX G78|F65|H34|W52")
    }

    func testWeeklyModelSessionRestoresMarkers() {
        XCTAssertEqual(
            format(fullSet(), kindOrder: [.weekly, .model, .session]).text,
            "CX W52|G78|F65|H34")
    }

    func testModelWeeklySessionRestoresMarkers() {
        XCTAssertEqual(
            format(fullSet(), kindOrder: [.model, .weekly, .session]).text,
            "CX G78|F65|W52|H34")
    }

    func testBasicsOnlyKeepsOmissionWhenSortedOrderMatchesDefault() {
        let windows = [
            window(id: "session", scope: .session, used: 34, kind: .session),
            window(id: "weekly", scope: .weeklyAll, used: 52),
        ]
        XCTAssertEqual(format(windows, kindOrder: [.session, .model, .weekly]).text, "CX 34|52")
    }

    func testSessionOnlyKeepsMarkerRegardlessOfKindOrder() {
        let windows = [window(id: "session", scope: .session, used: 34, kind: .session)]
        XCTAssertEqual(format(windows, kindOrder: [.model, .weekly, .session]).text, "CX H34")
    }

    func testWeeklyOnlyKeepsMarkerRegardlessOfKindOrder() {
        let windows = [window(id: "weekly", scope: .weeklyAll, used: 52)]
        XCTAssertEqual(format(windows, kindOrder: [.model, .session, .weekly]).text, "CX W52")
    }

    func testWindowSetAndOverflowAreInvariantAcrossKindOrders() {
        let windows = [
            window(id: "session", scope: .session, used: 34, kind: .session),
            window(id: "weekly", scope: .weeklyAll, used: 52),
            window(id: "g", scope: .model(id: "g", displayName: "GPT"), used: 78),
            window(id: "f", scope: .model(id: "f", displayName: "Fable"), used: 65),
            window(id: "o", scope: .model(id: "o", displayName: "Opus"), used: 40),
        ]
        let permutations: [[WindowKindCategory]] = [
            [.session, .weekly, .model], [.session, .model, .weekly],
            [.weekly, .session, .model], [.weekly, .model, .session],
            [.model, .session, .weekly], [.model, .weekly, .session],
        ]
        let baseline = numericMultiset(format(windows))
        let baselineOverflow = overflowText(format(windows))

        for order in permutations {
            let label = format(windows, kindOrder: order)
            XCTAssertEqual(numericMultiset(label), baseline, "order: \(order)")
            XCTAssertEqual(overflowText(label), baselineOverflow, "order: \(order)")
        }
    }

    func testCompactIsUnaffectedByKindOrder() {
        let permutations: [[WindowKindCategory]] = [
            [.session, .weekly, .model], [.session, .model, .weekly],
            [.weekly, .session, .model], [.weekly, .model, .session],
            [.model, .session, .weekly], [.model, .weekly, .session],
        ]
        let baseline = format(fullSet(), mode: .compact).text
        for order in permutations {
            XCTAssertEqual(
                format(fullSet(), mode: .compact, kindOrder: order).text, baseline,
                "order: \(order)")
        }
    }

    func testBalancedAppliesKindOrder() {
        XCTAssertEqual(
            format(fullSet(), mode: .balanced, kindOrder: [.model, .session, .weekly]).text,
            "CX G78|H34|W52")
    }

    // 設計書「formatCombined への伝播」と「provider ごとの独立性」を1件で担保する:
    // codex のみ非既定順を指定 → codex だけ並び替わり、claude は既定順のまま
    func testFormatCombinedAppliesKindOrderPerProviderAndLeavesOthersDefault() {
        let combined = MenuBarLabelFormatter.formatCombined(
            codex: (fullSet(), .fresh),
            claude: (fullSet(), .fresh),
            filter: DisplayFilter(),
            now: now, mode: .full,
            kindOrders: [.codex: [.model, .session, .weekly]])
        let codexPart = format(fullSet(), kindOrder: [.model, .session, .weekly]).text
        let claudePart = format(fullSet(), provider: .claude).text
        XCTAssertEqual(combined.text, "\(codexPart)  \(claudePart)")
        // claude 側が既定順であることを明示的に確認（マーカー無し＝並べ替えられていない）
        XCTAssertTrue(combined.text.hasSuffix("CL 34|52|G78|F65"))
    }

    private func weekly52() -> [RateLimitWindow] {
        [window(id: "weekly", scope: .weeklyAll, used: 52)]
    }

    func testCustomPrefixReplacesDefault() {
        XCTAssertEqual(format(weekly52(), customPrefix: "Codex").text, "Codex W52")
    }

    func testEmptyCustomPrefixFallsBackToProviderDefault() {
        XCTAssertEqual(format(weekly52(), provider: .codex).text, "CX W52")
        XCTAssertEqual(format(weekly52(), provider: .claude).text, "CL W52")
    }

    func testFormatWithoutCustomPrefixKeepsBackwardCompatibleDefault() {
        let label = MenuBarLabelFormatter.format(
            provider: .codex,
            windows: weekly52(),
            freshness: .fresh,
            now: now,
            mode: .full)

        XCTAssertEqual(label.text, "CX W52")
    }

    func testCustomPrefixExactlySixIsNotClamped() {
        XCTAssertEqual(format(weekly52(), customPrefix: "ABCDEF").text, "ABCDEF W52")
    }

    func testCustomPrefixOverSixIsClamped() {
        XCTAssertEqual(format(weekly52(), customPrefix: "ABCDEFG").text, "ABCDEF W52")
    }

    func testCustomPrefixClampsAtSixExtendedGraphemeClusters() {
        let cluster = "🇯🇵"
        let sixClusters = String(repeating: cluster, count: 6)
        let sevenClusters = String(repeating: cluster, count: 7)

        XCTAssertEqual(
            format(weekly52(), customPrefix: sixClusters).text,
            "\(sixClusters) W52")
        XCTAssertEqual(
            format(weekly52(), customPrefix: sevenClusters).text,
            "\(sixClusters) W52")
    }

    func testCustomPrefixStripsControlAndNewline() {
        XCTAssertEqual(format(weekly52(), customPrefix: "A\u{202E}B\nC").text, "ABC W52")
    }

    func testCustomPrefixRemovesNullZeroWidthAndUnicodeLineSeparator() {
        XCTAssertEqual(
            format(
                weekly52(),
                customPrefix: "A\u{0000}B\u{200B}C\u{2028}D"
            ).text,
            "ABCD W52")
    }

    func testCustomPrefixKeepsEmoji() {
        XCTAssertEqual(format(weekly52(), customPrefix: "🐙").text, "🐙 W52")
    }

    func testCustomPrefixAppliesWhenUnavailable() {
        let label = MenuBarLabelFormatter.format(
            provider: .codex, windows: [], freshness: .unavailable,
            now: now, mode: .full, customPrefix: "Codex")
        XCTAssertEqual(label.text, "Codex --")
    }

    func testCustomPrefixAppliesWhenFreshWithEmptyWindows() {
        let label = MenuBarLabelFormatter.format(
            provider: .codex,
            windows: [],
            freshness: .fresh,
            now: now,
            mode: .full,
            customPrefix: "Codex")

        XCTAssertEqual(label.text, "Codex --")
    }

    func testFormatCombinedAppliesLabelsPerProvider() {
        let label = MenuBarLabelFormatter.formatCombined(
            codex: ([window(id: "w", scope: .weeklyAll, used: 52)], .fresh),
            claude: ([window(id: "w", scope: .weeklyAll, used: 30)], .fresh),
            filter: DisplayFilter(),
            now: now, mode: .full,
            order: [.codex, .claude],
            labels: [.codex: "GPT", .claude: "🐙"])
        XCTAssertEqual(label.text, "GPT W52  🐙 W30")
    }

    func testFormatCombinedFallsBackForUnsetProvider() {
        let label = MenuBarLabelFormatter.formatCombined(
            codex: ([window(id: "w", scope: .weeklyAll, used: 52)], .fresh),
            claude: ([window(id: "w", scope: .weeklyAll, used: 30)], .fresh),
            filter: DisplayFilter(),
            now: now, mode: .full,
            order: [.codex, .claude],
            labels: [.codex: "GPT"])
        XCTAssertEqual(label.text, "GPT W52  CL W30")
    }

    func testFormatCombinedAppliesCustomLabelsInReversedProviderOrder() {
        let label = MenuBarLabelFormatter.formatCombined(
            codex: ([window(id: "codex", scope: .weeklyAll, used: 52)], .fresh),
            claude: ([window(id: "claude", scope: .weeklyAll, used: 30)], .fresh),
            filter: DisplayFilter(),
            now: now,
            mode: .full,
            order: [.claude, .codex],
            labels: [.codex: "GPT", .claude: "Anth"])

        XCTAssertEqual(label.text, "Anth W30  GPT W52")
    }

    private func formatCombined(
        codex: (windows: [RateLimitWindow], freshness: Freshness)? = nil,
        claude: (windows: [RateLimitWindow], freshness: Freshness)? = nil,
        filter: DisplayFilter = DisplayFilter(),
        mode: DisplayMode = .full
    ) -> MenuBarLabel {
        MenuBarLabelFormatter.formatCombined(
            codex: codex,
            claude: claude,
            filter: filter,
            now: now,
            mode: mode)
    }

    func testFullWithBothBasicsAndModel() {
        let label = format([
            window(id: "session", scope: .session, used: 34, kind: .session),
            window(id: "weekly", scope: .weeklyAll, used: 52),
            window(id: "spark", scope: .model(id: "spark", displayName: "GPT-5.3-Codex-Spark"), used: 78),
        ])
        XCTAssertEqual(label.text, "CX 34|52|G78")
    }

    func testFullWithOneBasicTwoModelsAndOverflow() {
        let label = format([
            window(id: "weekly", scope: .weeklyAll, used: 52),
            window(id: "g", scope: .model(id: "g", displayName: "GPT"), used: 78),
            window(id: "f", scope: .model(id: "f", displayName: "Fable"), used: 65),
            window(id: "o", scope: .model(id: "o", displayName: "Opus"), used: 40),
        ])
        XCTAssertEqual(label.text, "CX W52|G78|F65 +1")
    }

    func testAbbreviationCollisionExtendsPrefix() {
        let label = format([
            window(id: "fable", scope: .model(id: "1", displayName: "Fable"), used: 78),
            window(id: "flash", scope: .model(id: "2", displayName: "Flash"), used: 65),
        ])
        XCTAssertEqual(label.text, "CX Fa78|Fl65")
    }

    func testSameDisplayNameKeepsSameAbbreviation() {
        let label = format([
            window(id: "spark-a", scope: .model(id: "spark", displayName: "GPT"), used: 78),
            window(id: "spark-b", scope: .model(id: "spark", displayName: "GPT"), used: 65),
        ])
        XCTAssertEqual(label.text, "CX G78|G65")
    }

    func testBalancedShowsBasicsAndMostConstrainedNonBasic() {
        let label = format([
            window(id: "session", scope: .session, used: 34, kind: .session),
            window(id: "weekly", scope: .weeklyAll, used: 52),
            window(id: "g", scope: .model(id: "g", displayName: "GPT"), used: 78),
            window(id: "f", scope: .model(id: "f", displayName: "Fable"), used: 65),
            window(id: "o", scope: .model(id: "o", displayName: "Opus"), used: 40),
        ], mode: .balanced)
        XCTAssertEqual(label.text, "CX 34|52|G78")
    }

    func testCompactShowsMostConstrainedBasicWithKindPrefix() {
        let label = format([
            window(id: "session", scope: .session, used: 34, kind: .session),
            window(id: "weekly", scope: .weeklyAll, used: 65),
        ], provider: .claude, mode: .compact)
        XCTAssertEqual(label.text, "CL W65")
    }

    func testCriticalStylesOnlyValueSegment() {
        let label = format([
            window(id: "session", scope: .session, used: 100, kind: .session),
        ], mode: .compact)
        XCTAssertEqual(label.text, "CX H100")
        XCTAssertEqual(label.segments.first { $0.text == "100" }?.style, .critical)
        XCTAssertEqual(label.segments.first { $0.text == "H" }?.style, .normal)
    }

    func testStalePastResetClearsCriticalStyle() {
        let label = format([
            window(id: "session", scope: .session, used: 100, kind: .session, resetsIn: -60),
        ], freshness: .stale, mode: .compact)
        XCTAssertEqual(label.text, "CX H100 ⏱")
        XCTAssertEqual(label.segments.first { $0.text == "100" }?.style, .normal)
    }

    func testWarningStyleWhenPaceWillNotLast() {
        let label = format([
            window(id: "session", scope: .session, used: 90, kind: .session),
        ], mode: .compact)
        XCTAssertEqual(label.text, "CX H90")
        XCTAssertEqual(label.segments.first { $0.text == "90" }?.style, .warning)
    }

    func testAuthenticationRequiredShowsValuesOrPlaceholderAndLock() {
        let withValues = format([
            window(id: "session", scope: .session, used: 41, kind: .session),
        ], provider: .claude, freshness: .authenticationRequired)
        XCTAssertEqual(withValues.text, "CL H41 🔒")

        let empty = format([], provider: .claude, freshness: .authenticationRequired)
        XCTAssertEqual(empty.text, "CL -- 🔒")
    }

    func testUnavailableShowsPlaceholder() {
        XCTAssertEqual(format([], freshness: .unavailable).text, "CX --")
    }

    func testUsedPercentIsFloored() {
        let label = format([
            window(id: "session", scope: .session, used: 99.9, kind: .session, resetsIn: nil),
        ], mode: .compact)
        XCTAssertEqual(label.text, "CX H99")
        XCTAssertEqual(label.segments.first { $0.text == "99" }?.style, .normal)
    }

    func testTieBreaksByResetThenID() {
        let label = format([
            window(id: "c", scope: .model(id: "c", displayName: "C"), used: 50, resetsIn: 7200),
            window(id: "b", scope: .model(id: "b", displayName: "B"), used: 50),
            window(id: "a", scope: .model(id: "a", displayName: "A"), used: 50),
        ])
        XCTAssertEqual(label.text, "CX A50|B50 +1")
    }

    func testOtherScopeUsesRawValueForAbbreviation() {
        let label = format([
            window(id: "other", scope: .other("mystery"), used: 42, kind: nil),
        ])
        XCTAssertEqual(label.text, "CX M42")
    }

    func testCombinedOrdersCodexBeforeClaudeWithTwoSpaceSeparatorAndStaleMarks() {
        let label = formatCombined(
            codex: (windows: [
                window(id: "codex-weekly", scope: .weeklyAll, used: 57),
            ], freshness: .stale),
            claude: (windows: [
                window(id: "claude-weekly", scope: .weeklyAll, used: 30),
            ], freshness: .stale))

        XCTAssertEqual(label.text, "CX W57 ⏱  CL W30 ⏱")
        XCTAssertEqual(label.segments.first { $0.text == "  " }?.style, .normal)
    }

    func testCombinedExcludesCodexWhenProviderIsOff() {
        let label = formatCombined(
            codex: (windows: [
                window(id: "codex-weekly", scope: .weeklyAll, used: 57),
            ], freshness: .fresh),
            claude: (windows: [
                window(id: "claude-weekly", scope: .weeklyAll, used: 30),
            ], freshness: .fresh),
            filter: DisplayFilter(codex: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(label.text, "CL W30")
    }

    func testCombinedExcludesClaudeWhenProviderIsOff() {
        let label = formatCombined(
            codex: (windows: [
                window(id: "codex-weekly", scope: .weeklyAll, used: 57),
            ], freshness: .fresh),
            claude: (windows: [
                window(id: "claude-weekly", scope: .weeklyAll, used: 30),
            ], freshness: .fresh),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(label.text, "CX W57")
    }

    func testCombinedReturnsEmptyLabelOnlyWhenBothProvidersAreOff() {
        let bothOff = formatCombined(filter: DisplayFilter(
            codex: ProviderDisplayFilter(show: false),
            claude: ProviderDisplayFilter(show: false)))
        let bothOnWithoutSnapshots = formatCombined()

        XCTAssertTrue(bothOff.segments.isEmpty)
        XCTAssertFalse(bothOnWithoutSnapshots.segments.isEmpty)
    }

    func testCombinedSessionFilterRunsBeforeEveryDisplayMode() {
        let windows = filterTestWindows()
        let filter = DisplayFilter(
            codex: ProviderDisplayFilter(showSession: false),
            claude: ProviderDisplayFilter(show: false))

        XCTAssertEqual(
            formatCombined(
                codex: (windows: windows, freshness: .fresh),
                filter: filter,
                mode: .full).text,
            "CX W52|G78|F65 +1")
        XCTAssertEqual(
            formatCombined(
                codex: (windows: windows, freshness: .fresh),
                filter: filter,
                mode: .balanced).text,
            "CX W52|G78")
        XCTAssertEqual(
            formatCombined(
                codex: (windows: windows, freshness: .fresh),
                filter: filter,
                mode: .compact).text,
            "CX G78")
    }

    func testCombinedWeeklyFilterRunsBeforeEveryDisplayMode() {
        let windows = filterTestWindows()
        let filter = DisplayFilter(
            codex: ProviderDisplayFilter(showWeekly: false),
            claude: ProviderDisplayFilter(show: false))

        XCTAssertEqual(
            formatCombined(
                codex: (windows: windows, freshness: .fresh),
                filter: filter,
                mode: .full).text,
            "CX H34|G78|F65 +1")
        XCTAssertEqual(
            formatCombined(
                codex: (windows: windows, freshness: .fresh),
                filter: filter,
                mode: .balanced).text,
            "CX H34|G78")
        XCTAssertEqual(
            formatCombined(
                codex: (windows: windows, freshness: .fresh),
                filter: filter,
                mode: .compact).text,
            "CX G78")
    }

    func testCombinedModelFilterRunsBeforeEveryDisplayMode() {
        let windows = filterTestWindows()
        let filter = DisplayFilter(
            codex: ProviderDisplayFilter(showModel: false),
            claude: ProviderDisplayFilter(show: false))

        XCTAssertEqual(
            formatCombined(
                codex: (windows: windows, freshness: .fresh),
                filter: filter,
                mode: .full).text,
            "CX 34|52")
        XCTAssertEqual(
            formatCombined(
                codex: (windows: windows, freshness: .fresh),
                filter: filter,
                mode: .balanced).text,
            "CX 34|52")
        XCTAssertEqual(
            formatCombined(
                codex: (windows: windows, freshness: .fresh),
                filter: filter,
                mode: .compact).text,
            "CX W52")
    }

    func testCombinedClassifiesNilKindSessionByScope() {
        let label = formatCombined(
            codex: (windows: [
                window(id: "session", scope: .session, used: 45, kind: nil),
            ], freshness: .fresh),
            filter: DisplayFilter(
                codex: ProviderDisplayFilter(showSession: false),
                claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(label.text, "CX --")
    }

    func testCombinedClassifiesOtherScopeAsModelFilter() {
        let other = window(
            id: "other",
            scope: .other("mystery"),
            used: 45,
            kind: .other(minutes: 90))

        XCTAssertEqual(
            formatCombined(
                codex: (windows: [other], freshness: .fresh),
                filter: DisplayFilter(
                    codex: ProviderDisplayFilter(showModel: false),
                    claude: ProviderDisplayFilter(show: false))).text,
            "CX --")
        XCTAssertEqual(
            formatCombined(
                codex: (windows: [other], freshness: .fresh),
                filter: DisplayFilter(
                    codex: ProviderDisplayFilter(showModel: true),
                    claude: ProviderDisplayFilter(show: false))).text,
            "CX M45")
    }

    func testCombinedUsesModelScopeWhenKindSaysWeekly() {
        let mismatched = window(
            id: "model",
            scope: .model(id: "model", displayName: "Model"),
            used: 45,
            kind: .weekly)

        XCTAssertEqual(
            formatCombined(
                codex: (windows: [mismatched], freshness: .fresh),
                filter: DisplayFilter(
                    codex: ProviderDisplayFilter(showWeekly: false),
                    claude: ProviderDisplayFilter(show: false))).text,
            "CX M45")
        XCTAssertEqual(
            formatCombined(
                codex: (windows: [mismatched], freshness: .fresh),
                filter: DisplayFilter(
                    codex: ProviderDisplayFilter(showModel: false),
                    claude: ProviderDisplayFilter(show: false))).text,
            "CX --")
    }

    func testCombinedFilteredEmptyPreservesFreshnessMarkRules() {
        let weekly = [window(id: "weekly", scope: .weeklyAll, used: 52)]
        let filter = DisplayFilter(
            codex: ProviderDisplayFilter(showWeekly: false),
            claude: ProviderDisplayFilter(show: false))

        XCTAssertEqual(
            formatCombined(
                codex: (windows: weekly, freshness: .fresh),
                filter: filter).text,
            "CX --")
        XCTAssertEqual(
            formatCombined(
                codex: (windows: weekly, freshness: .stale),
                filter: filter).text,
            "CX -- ⏱")
    }

    func testCombinedNilSnapshotProducesPlaceholderInsteadOfOmittingProvider() {
        let label = formatCombined(
            codex: nil,
            claude: (windows: [
                window(id: "weekly", scope: .weeklyAll, used: 30),
            ], freshness: .fresh))

        XCTAssertEqual(label.text, "CX --  CL W30")
    }

    func testCombinedKeepsAbbreviationCollisionsWithinEachProvider() {
        let label = formatCombined(
            codex: (windows: [
                window(
                    id: "codex-fable",
                    scope: .model(id: "codex-fable", displayName: "Fable"),
                    used: 78),
            ], freshness: .fresh),
            claude: (windows: [
                window(
                    id: "claude-flash",
                    scope: .model(id: "claude-flash", displayName: "Flash"),
                    used: 65),
            ], freshness: .fresh))

        XCTAssertEqual(label.text, "CX F78  CL F65")
    }

    func testCodexModelFilterDoesNotAffectClaudeModel() {
        let label = formatCombined(
            codex: (windows: [
                window(id: "codex-model", scope: .model(id: "codex", displayName: "GPT"), used: 78),
            ], freshness: .fresh),
            claude: (windows: [
                window(id: "claude-model", scope: .model(id: "claude", displayName: "Opus"), used: 65),
            ], freshness: .fresh),
            filter: DisplayFilter(codex: ProviderDisplayFilter(showModel: false)))

        XCTAssertEqual(label.text, "CX --  CL O65")
    }

    func testClaudeModelFilterDoesNotAffectCodexModel() {
        let label = formatCombined(
            codex: (windows: [
                window(id: "codex-model", scope: .model(id: "codex", displayName: "GPT"), used: 78),
            ], freshness: .fresh),
            claude: (windows: [
                window(id: "claude-model", scope: .model(id: "claude", displayName: "Opus"), used: 65),
            ], freshness: .fresh),
            filter: DisplayFilter(claude: ProviderDisplayFilter(showModel: false)))

        XCTAssertEqual(label.text, "CX G78  CL --")
    }

    func testCombinedPreservesCriticalStyleWithoutAffectingOtherProvider() {
        let label = formatCombined(
            codex: (windows: [
                window(id: "session", scope: .session, used: 100, kind: .session),
            ], freshness: .fresh),
            claude: (windows: [
                window(id: "weekly", scope: .weeklyAll, used: 50),
            ], freshness: .fresh),
            mode: .compact)

        XCTAssertEqual(label.text, "CX H100  CL W50")
        XCTAssertEqual(label.segments.first { $0.text == "100" }?.style, .critical)
        XCTAssertEqual(label.segments.first { $0.text == "50" }?.style, .normal)
        XCTAssertEqual(label.segments.filter { $0.style == .critical }.count, 1)
    }

    private func filterTestWindows() -> [RateLimitWindow] {
        [
            window(id: "session", scope: .session, used: 34, kind: .session),
            window(id: "weekly", scope: .weeklyAll, used: 52),
            window(id: "gpt", scope: .model(id: "gpt", displayName: "GPT"), used: 78),
            window(id: "fable", scope: .model(id: "fable", displayName: "Fable"), used: 65),
            window(id: "opus", scope: .model(id: "opus", displayName: "Opus"), used: 40),
        ]
    }
}

extension MenuBarLabelFormatterTests {
    func testCombinedFollowsReversedProviderOrderIncludingSeparator() {
        let label = orderedCombined(order: [.claude, .codex])

        XCTAssertEqual(label.text, "CL W30  CX W57")
        XCTAssertEqual(label.segments.first { $0.text == "  " }?.style, .normal)
    }

    func testCombinedExplicitDefaultOrderMatchesOmittedOrder() {
        let codex = (windows: [
            window(id: "codex-weekly", scope: .weeklyAll, used: 57),
        ], freshness: Freshness.fresh)
        let claude = (windows: [
            window(id: "claude-weekly", scope: .weeklyAll, used: 30),
        ], freshness: Freshness.fresh)
        let omitted = MenuBarLabelFormatter.formatCombined(
            codex: codex,
            claude: claude,
            filter: DisplayFilter(),
            now: now,
            mode: .full)
        let explicit = MenuBarLabelFormatter.formatCombined(
            codex: codex,
            claude: claude,
            filter: DisplayFilter(),
            now: now,
            mode: .full,
            order: [.codex, .claude])

        XCTAssertEqual(explicit, omitted)
    }

    func testCombinedDeduplicatesProviderOrderByFirstOccurrence() {
        XCTAssertEqual(
            orderedCombined(order: [.codex, .codex, .claude]).text,
            "CX W57  CL W30")
    }

    func testCombinedOmitsProviderMissingFromOrder() {
        XCTAssertEqual(orderedCombined(order: [.claude]).text, "CL W30")
    }

    func testCombinedAppliesDisplayFilterWithinReversedOrder() {
        XCTAssertEqual(
            orderedCombined(
                filter: DisplayFilter(codex: ProviderDisplayFilter(show: false)),
                order: [.claude, .codex]).text,
            "CL W30")
    }

    func testCombinedEmptyOrderReturnsEmptyLabel() {
        XCTAssertTrue(orderedCombined(order: []).segments.isEmpty)
    }

    private func orderedCombined(
        filter: DisplayFilter = DisplayFilter(),
        order: [ProviderID]
    ) -> MenuBarLabel {
        MenuBarLabelFormatter.formatCombined(
            codex: (windows: [
                window(id: "codex-weekly", scope: .weeklyAll, used: 57),
            ], freshness: .fresh),
            claude: (windows: [
                window(id: "claude-weekly", scope: .weeklyAll, used: 30),
            ], freshness: .fresh),
            filter: filter,
            now: now,
            mode: .full,
            order: order)
    }
}
