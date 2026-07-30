import XCTest
@testable import TakometaCore

final class MenuBarColumnsFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        id: String, scope: RateLimitScope, used: Double,
        kind: WindowKind? = .weekly, resetsIn: TimeInterval? = 3600
    ) -> RateLimitWindow {
        RateLimitWindow(
            id: id, label: id, scope: scope, usedPercent: used,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) }, kind: kind)
    }

    private func columns(
        codex: (windows: [RateLimitWindow], freshness: Freshness)? = nil,
        claude: (windows: [RateLimitWindow], freshness: Freshness)? = nil,
        filter: DisplayFilter = DisplayFilter(),
        mode: DisplayMode = .full,
        labels: [ProviderID: String] = [:],
        kindOrders: [ProviderID: [WindowKindCategory]] = [:]
    ) -> MenuBarColumns {
        MenuBarLabelFormatter.formatCombinedColumns(
            codex: codex, claude: claude, filter: filter,
            now: now, mode: mode, labels: labels, kindOrders: kindOrders)
    }

    private func basicSet() -> [RateLimitWindow] {
        [
            window(id: "s", scope: .session, used: 34, kind: .session),
            window(id: "w", scope: .weeklyAll, used: 52),
        ]
    }

    func testGroupStartsWithProviderLabelColumn() {
        // claude を明示的に非表示にする。claude: nil でも resolveProviders は
        // ([], .unavailable) を入れるため、既定の filter だと "CL --" グループが生まれる
        let result = columns(
            codex: (basicSet(), .fresh),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0][0].title, "CX")
        XCTAssertEqual(result.groups[0][0].value, " ")
    }

    func testProviderLabelColumnUsesCustomLabel() {
        let result = columns(codex: (basicSet(), .fresh), labels: [.codex: "Codex"])
        XCTAssertEqual(result.groups[0][0].title, "Codex")
    }

    func testWindowColumnsFollowLabelColumn() {
        let result = columns(codex: (basicSet(), .fresh))
        let group = result.groups[0]

        XCTAssertEqual(group.map(\.title), ["CX", "5h", "1w"])
        XCTAssertEqual(group.map(\.value), [" ", "34", "52"])
    }

    func testOverflowColumnIsAppended() {
        let windows = basicSet() + [
            window(id: "g", scope: .model(id: "g", displayName: "GPT"), used: 78),
            window(id: "f", scope: .model(id: "f", displayName: "Fable"), used: 65),
            window(id: "o", scope: .model(id: "o", displayName: "Opus"), used: 40),
        ]
        let result = columns(codex: (windows, .fresh))
        let last = result.groups[0].last!

        XCTAssertEqual(last.title, "他")
        XCTAssertEqual(last.value, "+1")
    }

    func testFreshnessMarkColumnIsLastWhenOverflowAlsoPresent() {
        let windows = basicSet() + [
            window(id: "g", scope: .model(id: "g", displayName: "GPT"), used: 78),
            window(id: "f", scope: .model(id: "f", displayName: "Fable"), used: 65),
            window(id: "o", scope: .model(id: "o", displayName: "Opus"), used: 40),
        ]
        let group = columns(codex: (windows, .stale)).groups[0]

        XCTAssertEqual(group[group.count - 2].title, "他")
        XCTAssertEqual(group[group.count - 1].title, " ")
        XCTAssertEqual(group[group.count - 1].value, "⏱")
    }

    func testUnavailableProducesLabelAndDashOnly() {
        let group = columns(codex: ([], .unavailable)).groups[0]

        XCTAssertEqual(group.map(\.title), ["CX", "--"])
        XCTAssertEqual(group.map(\.value), [" ", " "])
    }

    func testEmptyWindowsWithStaleKeepsFreshnessMark() {
        let group = columns(codex: ([], .stale)).groups[0]

        XCTAssertEqual(group.map(\.title), ["CX", "--", " "])
        XCTAssertEqual(group[2].value, "⏱")
    }

    func testEmptyWindowsWithFreshHasNoMark() {
        let group = columns(codex: ([], .fresh)).groups[0]
        XCTAssertEqual(group.map(\.title), ["CX", "--"])
    }

    func testAllColumnsHaveNonEmptyTitleAndValue() {
        // N-6 の回帰: どの構成でも空文字の列を作らない
        let cases: [(windows: [RateLimitWindow], freshness: Freshness)] = [
            (basicSet(), .fresh),
            ([], .unavailable),
            ([], .stale),
            ([], .authenticationRequired),
            (basicSet() + [
                window(id: "g", scope: .model(id: "g", displayName: "GPT"), used: 78),
                window(id: "f", scope: .model(id: "f", displayName: "Fable"), used: 65),
                window(id: "o", scope: .model(id: "o", displayName: "Opus"), used: 40),
            ], .stale),
        ]
        for input in cases {
            for group in columns(codex: input).groups {
                for column in group {
                    XCTAssertFalse(column.title.isEmpty, "title が空: \(input.freshness)")
                    XCTAssertFalse(column.value.isEmpty, "value が空: \(input.freshness)")
                }
            }
        }
    }

    func testTwoProvidersProduceTwoGroups() {
        let result = columns(codex: (basicSet(), .fresh), claude: (basicSet(), .fresh))
        XCTAssertEqual(result.groups.count, 2)
    }

    func testHiddenProviderIsExcluded() {
        let result = columns(
            codex: (basicSet(), .fresh), claude: (basicSet(), .fresh),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0][0].title, "CX")
    }

    func testBothHiddenProducesEmptyGroups() {
        // N-10 の前提: 描画側が EmptyMenuBarLabelView へ落とす
        let result = columns(
            codex: (basicSet(), .fresh), claude: (basicSet(), .fresh),
            filter: DisplayFilter(
                codex: ProviderDisplayFilter(show: false),
                claude: ProviderDisplayFilter(show: false)))
        XCTAssertTrue(result.groups.isEmpty)
    }

    func testKindOrderIsApplied() {
        let windows = basicSet()
        let result = columns(
            codex: (windows, .fresh), kindOrders: [.codex: [.weekly, .session, .model]])
        XCTAssertEqual(result.groups[0].map(\.title), ["CX", "1w", "5h"])
    }

    func testCompactModeSelectsSingleWindow() {
        // N-1 の共有経路: compact は全体で1枠のみ。select を共有していることの確認
        let windows = basicSet() + [
            window(id: "g", scope: .model(id: "g", displayName: "GPT"), used: 78),
        ]
        let result = columns(
            codex: (windows, .fresh),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)),
            mode: .compact)

        // ラベル列 + 枠1つ
        XCTAssertEqual(result.groups[0].count, 2)
    }

    func testWindowKindFilterIsApplied() {
        // N-8 の回帰: 枠種別の表示 ON/OFF（DisplayFilter）が2行でも効く。
        // testHiddenProviderIsExcluded は show: false（プロバイダー丸ごと）で別物
        let result = columns(
            codex: (basicSet(), .fresh),
            filter: DisplayFilter(
                codex: ProviderDisplayFilter(showSession: false),
                claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.groups[0].map(\.title), ["CX", "1w"])
    }

    func testStyleMatchesOneLineOutput() {
        // 等価性: 同一入力で1行と2行の SegmentStyle が一致する
        let windows = basicSet() + [
            window(id: "g", scope: .model(id: "g", displayName: "GPT"), used: 100),
        ]
        let oneLine = MenuBarLabelFormatter.formatCombined(
            codex: (windows, .fresh), claude: nil,
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)),
            now: now, mode: .full)
        let twoLine = columns(
            codex: (windows, .fresh),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        let oneLineStyles = oneLine.segments
            .filter { !$0.text.isEmpty && $0.text.allSatisfy(\.isNumber) }
            .map(\.style)
        let twoLineStyles = twoLine.groups[0]
            .filter { !$0.value.isEmpty && $0.value.allSatisfy(\.isNumber) }
            .map(\.style)

        XCTAssertEqual(oneLineStyles, twoLineStyles)
    }

    func testWindowSetMatchesOneLineOutput() {
        // 等価性: 同一入力で選ばれる枠の集合が1行と一致する
        let windows = basicSet() + [
            window(id: "g", scope: .model(id: "g", displayName: "GPT"), used: 78),
            window(id: "f", scope: .model(id: "f", displayName: "Fable"), used: 65),
            window(id: "o", scope: .model(id: "o", displayName: "Opus"), used: 40),
        ]
        let filter = DisplayFilter(claude: ProviderDisplayFilter(show: false))
        let oneLine = MenuBarLabelFormatter.formatCombined(
            codex: (windows, .fresh), claude: nil, filter: filter, now: now, mode: .full)
        let twoLine = columns(codex: (windows, .fresh), filter: filter)

        // sorted() で並べ替えない。設計書は「同じ枠集合・同じ順序」を求めており、
        // 順序を捨てると並べ替えのドリフトを検出できない
        let oneLineValues = oneLine.segments
            .map(\.text).filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        let twoLineValues = twoLine.groups[0]
            .map(\.value).filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }

        XCTAssertEqual(oneLineValues, twoLineValues)
    }
}
