import XCTest
@testable import TakometaCore

final class RecentBurnRateTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private var now: Date { base.addingTimeInterval(30 * 60) }
    private var windowA: Date { base.addingTimeInterval(86400) }
    private var windowB: Date { base.addingTimeInterval(200_000) }

    private func p(_ minutes: Double, _ percent: Double, _ resetsAt: Date?) -> HistoryPoint {
        HistoryPoint(
            at: base.addingTimeInterval(minutes * 60), resetsAt: resetsAt, usedPercent: percent)
    }

    private func rate(_ points: [HistoryPoint]) -> Double? {
        RecentBurnRate.calculate(points: points, now: now)
    }

    // MARK: - 正常系

    func testNormalThreePoints() {
        XCTAssertEqual(rate([p(0, 40, windowA), p(10, 50, windowA), p(20, 45, windowA)]), 15.0)
    }

    func testUnevenIntervalsUseBothEnds() {
        // 密な区間に引きずられない（最小二乗法ではなく両端の差分）
        XCTAssertEqual(
            rate([p(0, 40, windowA), p(1, 41, windowA), p(2, 42, windowA), p(20, 45, windowA)]),
            15.0)
    }

    // MARK: - resetsAt が nil の扱い（N-5）

    func testNilInMiddleIsSkipped() {
        XCTAssertEqual(rate([p(0, 40, windowA), p(10, 50, nil), p(20, 45, windowA)]), 15.0)
    }

    func testNilAtEndIsSkipped() {
        // 基準を「最新点」にした実装だとここで nil になる
        XCTAssertEqual(rate([p(0, 40, windowA), p(10, 50, windowA), p(20, 45, nil)]), 15.0)
    }

    func testAllNilPassesThrough() {
        // 基準となる非 nil が取れないのでフィルタしない。負値ガードが防御を担う
        XCTAssertEqual(rate([p(0, 40, nil), p(10, 50, nil), p(20, 45, nil)]), 15.0)
    }

    // MARK: - 窓の変化（N-5）

    func testRealResetGivesNil() {
        XCTAssertNil(rate([p(0, 40, windowA), p(10, 50, windowA), p(20, 45, windowB)]))
    }

    func testResetPlusNilAtEndUsesNewWindowOnly() {
        // 基準 = windowB（10分の点）。20分(nil) は境界でない。0分(windowA) で停止
        // 残る2点 40% → 45% / 10分 = 30.0
        XCTAssertEqual(rate([p(0, 90, windowA), p(10, 40, windowB), p(20, 45, nil)]), 30.0)
    }

    func testReturningToPreviousWindowUsesOnlyTrailingContiguousSegment() {
        XCTAssertEqual(
            rate([
                p(0, 10, windowA), p(5, 15, windowA),
                p(10, 30, windowB), p(15, 35, windowB),
                p(20, 50, windowA), p(30, 55, windowA),
            ]),
            30.0)
    }

    // MARK: - 順序（N-13）

    func testReverseOrderGivesNil() {
        XCTAssertNil(rate([p(20, 45, windowA), p(10, 50, windowA), p(0, 40, windowA)]))
    }

    func testShuffledGivesNil() {
        // abs を使わないだけでは倒せない。手順0の昇順チェックが要る
        XCTAssertNil(rate([p(0, 40, windowA), p(20, 45, windowA), p(10, 50, windowA)]))
    }

    // MARK: - nil になる条件（N-4 / N-12）

    func testEmptyGivesNil() { XCTAssertNil(rate([])) }

    func testSinglePointGivesNil() { XCTAssertNil(rate([p(0, 40, windowA)])) }

    func testSpanUnderFiveMinutesGivesNil() {
        XCTAssertNil(rate([p(0, 40, windowA), p(3, 50, windowA)]))
    }

    func testNegativeSlopeGivesNil() {
        XCTAssertNil(rate([p(0, 50, windowA), p(20, 40, windowA)]))
    }

    func testOnlyOldPointsGivesNil() {
        XCTAssertNil(rate([p(-90, 40, windowA), p(-80, 50, windowA)]))
    }

    // MARK: - 境界

    func testZeroSlopeIsReturnedNotNil() {
        // 直近1時間まったく消費していない状態は真値。guard slope > 0 と書くと nil に倒れる
        XCTAssertEqual(rate([p(0, 40, windowA), p(20, 40, windowA)]), 0.0)
    }

    func testExactlyFiveMinutesIsIncluded() {
        XCTAssertEqual(rate([p(0, 40, windowA), p(5, 45, windowA)]), 60.0)
    }
}
