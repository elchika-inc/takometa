import XCTest
@testable import TakometaCore

final class UsageReportTextTests: XCTestCase {
    /// 2027-01-15 17:00:00 JST（= 2027-01-15T08:00:00Z）
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private let locale = Locale(identifier: "ja_JP")

    private func render(_ report: UsageReport) -> String {
        UsageReportText.render(report, now: now, calendar: calendar, locale: locale)
    }

    private func report(_ providers: [ProviderReport]) -> UsageReport {
        UsageReport(schemaVersion: 1, generatedAt: now, providers: providers)
    }

    private func available(
        _ id: ProviderID, ageSeconds: Int, windows: [WindowReport]
    ) -> ProviderReport {
        ProviderReport(
            id: id, available: true,
            fetchedAt: now.addingTimeInterval(-Double(ageSeconds)),
            ageSeconds: ageSeconds,
            source: id == .codex ? .codexAppServer : .claudeOAuth,
            windows: windows)
    }

    private func window(
        scope: ScopeName, index: Int? = nil, window: WindowName? = nil,
        windowMinutes: Int64? = nil, usedPercent: Double = 10,
        resetsAt: Date? = nil, expired: Bool? = nil
    ) -> WindowReport {
        WindowReport(
            scope: scope, index: index, window: window, windowMinutes: windowMinutes,
            usedPercent: usedPercent, resetsAt: resetsAt, expired: expired, isActive: nil)
    }

    // MARK: - 経過時間の桁上げ

    func testElapsedTextGoesUpByMagnitude() {
        XCTAssertEqual(UsageReportText.elapsedText(seconds: 0), "0秒前")
        XCTAssertEqual(UsageReportText.elapsedText(seconds: 59), "59秒前")
        XCTAssertEqual(UsageReportText.elapsedText(seconds: 60), "1分0秒前")
        XCTAssertEqual(UsageReportText.elapsedText(seconds: 142), "2分22秒前")
        XCTAssertEqual(UsageReportText.elapsedText(seconds: 3599), "59分59秒前")
        XCTAssertEqual(UsageReportText.elapsedText(seconds: 3600), "1時間0分前")
        XCTAssertEqual(UsageReportText.elapsedText(seconds: 5400), "1時間30分前")
        XCTAssertEqual(UsageReportText.elapsedText(seconds: 86399), "23時間59分前")
        XCTAssertEqual(UsageReportText.elapsedText(seconds: 86400), "1日前")
        XCTAssertEqual(UsageReportText.elapsedText(seconds: 259_200), "3日前")
    }

    // MARK: - 枠の表記

    func testScopeLabelsMatchExistingUI() {
        XCTAssertEqual(
            UsageReportText.windowLabel(window(scope: .session, window: .session)), "5時間枠")
        XCTAssertEqual(
            UsageReportText.windowLabel(window(scope: .weeklyAll, window: .weekly)), "週間枠")
    }

    func testModelScopeIncludesIndexAndDuration() {
        // 継続時間を落とすと、モデル固有の5時間枠と週間枠が同じ表記になり情報が失われる
        XCTAssertEqual(
            UsageReportText.windowLabel(window(scope: .model, index: 1, window: .session)),
            "モデル固有枠 #1（5時間）")
        XCTAssertEqual(
            UsageReportText.windowLabel(window(scope: .model, index: 2, window: .weekly)),
            "モデル固有枠 #2（週間）")
    }

    func testOtherScopeAndOtherDuration() {
        XCTAssertEqual(
            UsageReportText.windowLabel(
                window(scope: .other, index: 1, window: .other, windowMinutes: 1440)),
            "その他 #1（1440分）")
    }

    func testDurationIsOmittedWhenWindowIsNil() {
        XCTAssertEqual(
            UsageReportText.windowLabel(window(scope: .model, index: 1, window: nil)),
            "モデル固有枠 #1", "kind が nil なら括弧ごと省略する")
    }

    // MARK: - パーセント

    func testPercentIsTruncatedNotRounded() {
        XCTAssertEqual(UsageReportText.percentText(66.310000000000002), "66%")
        XCTAssertEqual(UsageReportText.percentText(99.6), "99%", "100% にしない")
        XCTAssertEqual(UsageReportText.percentText(0), "0%")
        XCTAssertEqual(UsageReportText.percentText(100), "100%")
    }

    func testPercentOutsideIntRangeDoesNotCrash() {
        XCTAssertEqual(UsageReportText.percentText(1e308), "値不明")
    }

    // MARK: - 全体

    func testAvailableProviderShowsHeadingAndWindows() {
        let text = render(report([
            available(.codex, ageSeconds: 142, windows: [
                window(
                    scope: .weeklyAll, window: .weekly, usedPercent: 66.310000000000002,
                    resetsAt: now.addingTimeInterval(6 * 86400), expired: false),
            ]),
        ]))
        XCTAssertTrue(text.contains("codex"))
        XCTAssertTrue(text.contains("2分22秒前に取得"))
        XCTAssertTrue(text.contains("週間枠"))
        XCTAssertTrue(text.contains("66%"))
    }

    func testUnavailableProviderIsShownNotDropped() {
        let text = render(report([
            ProviderReport(id: .claude, available: false, reason: .absent),
        ]))
        XCTAssertTrue(text.contains("claude"))
        XCTAssertTrue(text.contains("取得していません"), "黙って消さない")
    }

    func testUnreadableProviderIsDistinguishedFromAbsent() {
        let absent = render(report([
            ProviderReport(id: .codex, available: false, reason: .absent),
        ]))
        let unreadable = render(report([
            ProviderReport(id: .codex, available: false, reason: .unreadable),
        ]))
        XCTAssertNotEqual(absent, unreadable, "absent と unreadable を同じ文言にしない")
        XCTAssertFalse(unreadable.contains("/"), "パスを出さない（N-2）")
    }

    // MARK: - 日時

    func testResetDateUsesRelativeFormForToday() {
        let text = render(report([
            available(.codex, ageSeconds: 10, windows: [
                window(
                    scope: .session, window: .session,
                    resetsAt: now.addingTimeInterval(3600), expired: false),
            ]),
        ]))
        XCTAssertTrue(text.contains("本日"), "当日は相対表記")
        XCTAssertFalse(text.contains("2027/"), "スラッシュ区切りにならない")
    }

    func testResetDateUsesAbsoluteFormForDistantDate() {
        let text = render(report([
            available(.codex, ageSeconds: 10, windows: [
                window(
                    scope: .weeklyAll, window: .weekly,
                    resetsAt: now.addingTimeInterval(6 * 86400), expired: false),
            ]),
        ]))
        XCTAssertTrue(text.contains("年"), "ja_JP の abbreviated 書式（例: 2027年1月21日）")
        XCTAssertFalse(text.contains("2027/"), "スラッシュ区切りにならない")
    }

    func testResetIsOmittedWhenResetsAtIsNil() {
        let text = render(report([
            available(.codex, ageSeconds: 10, windows: [
                window(scope: .session, window: .session, resetsAt: nil),
            ]),
        ]))
        XCTAssertFalse(text.contains("リセット"), "resetsAt が無ければリセット表示を出さない")
    }

    // MARK: - JSON との非対称（意図的）

    func testExpiredIsNotShownToHumans() {
        let text = render(report([
            available(.codex, ageSeconds: 10, windows: [
                window(
                    scope: .session, window: .session,
                    resetsAt: now.addingTimeInterval(-3600), expired: true),
            ]),
        ]))
        XCTAssertFalse(text.contains("expired"))
        XCTAssertFalse(text.contains("期限切れ"))
        XCTAssertTrue(text.contains("本日"), "リセット時刻自体は出る（人が判断できる）")
    }
}
