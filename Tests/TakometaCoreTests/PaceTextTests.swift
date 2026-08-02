import XCTest
@testable import TakometaCore

final class PaceTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pace(
        average: Double, projected: Date?, lasts: Bool
    ) -> UsagePace {
        UsagePace(
            averagePercentPerHour: average, projectedLimitAt: projected, willLastToReset: lasts)
    }

    private func text(_ pace: UsagePace?, recent: Double?) -> String? {
        PaceText.description(
            pace, recent: recent, now: now,
            calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "ja_JP"))
    }

    func testAverageAndRecentAreBothShown() {
        let result = text(pace(average: 3.2, projected: nil, lasts: true), recent: 8.1)
        XCTAssertEqual(result?.contains("平均 3.2%/h"), true)
        XCTAssertEqual(result?.contains("直近 8.1%/h"), true)
    }

    func testRecentNilShowsAverageOnly() {
        // 「直近 --」のような欠測表示はしない（N-4）
        let result = text(pace(average: 3.2, projected: nil, lasts: true), recent: nil)
        XCTAssertEqual(result?.contains("平均 3.2%/h"), true)
        XCTAssertEqual(result?.contains("直近"), false)
    }

    func testAverageNilGivesNilEvenWithRecent() {
        // 平均が算出できないときは行ごと出さない（直近だけを出さない）
        XCTAssertNil(text(nil, recent: 8.1))
    }

    func testProjectionUsesAverageNotRecent() {
        // N-7: 上限到達予測は平均から。直近を渡しても予測の文言が変わらない
        let projected = now.addingTimeInterval(3600)
        let withRecent = text(pace(average: 3.2, projected: projected, lasts: false), recent: 99.0)
        let withoutRecent = text(pace(average: 3.2, projected: projected, lasts: false), recent: nil)
        let projectionText = RelativeDateText.text(
            for: projected, now: now,
            calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "ja_JP"))
        XCTAssertEqual(withRecent?.contains(projectionText), true)
        XCTAssertEqual(withoutRecent?.contains(projectionText), true)
    }

    func testLastsToResetWording() {
        let result = text(pace(average: 3.2, projected: nil, lasts: true), recent: 8.1)
        XCTAssertEqual(result?.contains("リセットまで持つ見込み"), true)
    }

    func testZeroRecentIsShown() {
        // 0.0%/h は真値なので隠さない
        let result = text(pace(average: 3.2, projected: nil, lasts: true), recent: 0.0)
        XCTAssertEqual(result?.contains("直近 0.0%/h"), true)
    }

    // 実績（平均・直近）と見通し（予測・持つ見込み）を別の行にする。
    // 1行に連結すると幅360のポップオーバーで末尾が切り詰められ、
    // 上限到達予測の日時が読めなくなる（#9）。
    func testProjectionIsPlacedOnItsOwnLine() throws {
        let projected = now.addingTimeInterval(3600)
        let result = try XCTUnwrap(
            text(pace(average: 3.2, projected: projected, lasts: false), recent: 8.1))
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)

        // 添字ではなく first / last で取り出す。行数が想定と違うときに
        // クラッシュさせず、他のテストを巻き込まないようにする
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.first, "平均 3.2%/h・直近 8.1%/h")
        XCTAssertEqual(lines.last?.hasPrefix("上限到達予測 "), true)
    }

    func testLastsToResetWordingIsPlacedOnItsOwnLine() throws {
        let result = try XCTUnwrap(
            text(pace(average: 3.2, projected: nil, lasts: true), recent: 8.1))
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.first, "平均 3.2%/h・直近 8.1%/h")
        XCTAssertEqual(lines.last, "リセットまで持つ見込み")
    }

    // 予測も見込みも出せないときは実績だけの1行。空行を作らない
    func testAverageOnlyStaysSingleLine() throws {
        let result = try XCTUnwrap(
            text(pace(average: 3.2, projected: nil, lasts: false), recent: nil))

        XCTAssertEqual(result, "平均 3.2%/h")
        XCTAssertEqual(result.contains("\n"), false)
    }

    func testAttentionWhenRecentIsFasterThanAverage() {
        let value = pace(average: 3.2, projected: nil, lasts: true)

        XCTAssertTrue(PaceText.requiresAttention(value, recent: 8.1))
    }

    func testNoAttentionWhenRecentMatchesAverageAndLastsToReset() {
        let value = pace(average: 3.2, projected: nil, lasts: true)

        XCTAssertFalse(PaceText.requiresAttention(value, recent: 3.2))
    }

    func testExistingAttentionIsPreservedWithoutRecent() {
        let value = pace(average: 3.2, projected: now, lasts: false)

        XCTAssertTrue(PaceText.requiresAttention(value, recent: nil))
    }
}
