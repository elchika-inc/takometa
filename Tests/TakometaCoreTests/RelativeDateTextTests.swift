import Foundation
import XCTest
@testable import TakometaCore

final class RelativeDateTextTests: XCTestCase {
    private let locale = Locale(identifier: "ja_JP")

    private func calendar(timeZone identifier: String = "Asia/Tokyo") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.locale = locale
        return calendar
    }

    private func date(
        _ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int, _ ss: Int = 0,
        in calendar: Calendar
    ) -> Date {
        var components = DateComponents()
        components.year = y
        components.month = m
        components.day = d
        components.hour = hh
        components.minute = mm
        components.second = ss
        return calendar.date(from: components)!
    }

    private func format(
        _ target: Date,
        now: Date,
        calendar: Calendar,
        includesSeconds: Bool = false
    ) -> String {
        RelativeDateText.text(
            for: target,
            now: now,
            calendar: calendar,
            locale: locale,
            includesSeconds: includesSeconds)
    }

    // MARK: - 相対表記

    func testSameDayUsesTodayPrefix() {
        let cal = calendar()
        let now = date(2026, 7, 28, 14, 5, in: cal)
        XCTAssertEqual(format(date(2026, 7, 28, 16, 20, in: cal), now: now, calendar: cal), "本日 16:20")
    }

    func testEarlierSameDayUsesTodayPrefix() {
        let cal = calendar()
        let now = date(2026, 7, 28, 14, 5, in: cal)
        XCTAssertEqual(format(date(2026, 7, 28, 9, 3, in: cal), now: now, calendar: cal), "本日 9:03")
    }

    func testNextDayUsesTomorrowPrefix() {
        let cal = calendar()
        let now = date(2026, 7, 28, 14, 5, in: cal)
        XCTAssertEqual(format(date(2026, 7, 29, 9, 0, in: cal), now: now, calendar: cal), "明日 9:00")
    }

    func testPreviousDayUsesYesterdayPrefix() {
        let cal = calendar()
        let now = date(2026, 7, 28, 14, 5, in: cal)
        XCTAssertEqual(format(date(2026, 7, 27, 23, 30, in: cal), now: now, calendar: cal), "昨日 23:30")
    }

    func testJustBeforeMidnightIsStillToday() {
        let cal = calendar()
        let now = date(2026, 7, 28, 14, 5, in: cal)
        XCTAssertEqual(format(date(2026, 7, 28, 23, 59, in: cal), now: now, calendar: cal), "本日 23:59")
    }

    func testMidnightIsTomorrow() {
        let cal = calendar()
        let now = date(2026, 7, 28, 23, 59, in: cal)
        XCTAssertEqual(format(date(2026, 7, 29, 0, 0, in: cal), now: now, calendar: cal), "明日 0:00")
    }

    func testMonthBoundaryIsHandledByCalendar() {
        let cal = calendar()
        let now = date(2026, 7, 31, 22, 0, in: cal)
        XCTAssertEqual(format(date(2026, 8, 1, 1, 0, in: cal), now: now, calendar: cal), "明日 1:00")
    }

    func testYearBoundaryIsHandledByCalendar() {
        let cal = calendar()
        let now = date(2026, 12, 31, 22, 0, in: cal)
        XCTAssertEqual(format(date(2027, 1, 1, 1, 0, in: cal), now: now, calendar: cal), "明日 1:00")
    }

    func testLeapDayIsHandledByCalendar() {
        let cal = calendar()
        let now = date(2028, 2, 28, 22, 0, in: cal)
        XCTAssertEqual(format(date(2028, 2, 29, 1, 0, in: cal), now: now, calendar: cal), "明日 1:00")
    }

    // MARK: - 絶対日付（従来書式の維持）

    func testTwoDaysAheadKeepsAbbreviatedDateFormat() {
        let cal = calendar()
        let now = date(2026, 7, 28, 14, 5, in: cal)
        XCTAssertEqual(
            format(date(2026, 7, 30, 12, 0, in: cal), now: now, calendar: cal),
            "2026年7月30日 12:00")
    }

    func testTwoDaysBehindKeepsAbbreviatedDateFormat() {
        let cal = calendar()
        let now = date(2026, 7, 28, 14, 5, in: cal)
        XCTAssertEqual(
            format(date(2026, 7, 26, 12, 0, in: cal), now: now, calendar: cal),
            "2026年7月26日 12:00")
    }

    func testAbsoluteDateWithSecondsKeepsStandardTimeFormat() {
        let cal = calendar()
        let now = date(2026, 7, 28, 14, 5, in: cal)
        XCTAssertEqual(
            format(
                date(2026, 7, 20, 14, 5, 32, in: cal),
                now: now, calendar: cal, includesSeconds: true),
            "2026年7月20日 14:05:32")
    }

    // MARK: - 秒の有無

    func testSecondsAreIncludedWhenRequested() {
        let cal = calendar()
        let now = date(2026, 7, 28, 14, 5, in: cal)
        XCTAssertEqual(
            format(
                date(2026, 7, 28, 14, 5, 32, in: cal),
                now: now, calendar: cal, includesSeconds: true),
            "本日 14:05:32")
    }

    func testSecondsAreOmittedByDefault() {
        let cal = calendar()
        let now = date(2026, 7, 28, 14, 5, in: cal)
        XCTAssertEqual(
            format(date(2026, 7, 28, 14, 5, 32, in: cal), now: now, calendar: cal),
            "本日 14:05")
    }

    // MARK: - DST（00:00 に切り替わるタイムゾーン）

    /// Havana は DST 開始日の 00:00 が存在せず `startOfDay` が 01:00 を返す。
    /// 日数差分で判定すると 23 時間を「0日」と数えて誤判定する。
    func testDSTMidnightTransitionDoesNotMislabelNextDayAsToday() {
        let cal = calendar(timeZone: "America/Havana")
        let now = date(2026, 3, 8, 23, 59, in: cal)
        let target = date(2026, 3, 9, 0, 1, in: cal)

        XCTAssertTrue(
            format(target, now: now, calendar: cal).hasPrefix("明日"),
            "DST 境界で翌日が本日と誤判定されている")
    }

    /// 同じく 47 時間を「1日」と数えて 2 日後を「明日」と誤判定しないこと。
    func testDSTMidnightTransitionDoesNotMislabelTwoDaysAheadAsTomorrow() {
        let cal = calendar(timeZone: "America/Havana")
        let now = date(2026, 3, 8, 12, 0, in: cal)
        let target = date(2026, 3, 10, 12, 0, in: cal)

        let text = format(target, now: now, calendar: cal)
        XCTAssertFalse(text.hasPrefix("明日"), "DST 境界で 2 日後が明日と誤判定されている")
        XCTAssertFalse(text.hasPrefix("本日"))
    }

    /// DST が 02:00 に切り替わるタイムゾーンでも当日判定が保たれること。
    func testDSTAfternoonTransitionKeepsSameDayAsToday() {
        let cal = calendar(timeZone: "America/Los_Angeles")
        let now = date(2026, 3, 8, 12, 0, in: cal)
        let target = date(2026, 3, 8, 20, 0, in: cal)

        XCTAssertTrue(format(target, now: now, calendar: cal).hasPrefix("本日"))
    }

    /// 秋の DST（fall-back・1時間が重複する日）でも判定が保たれること。
    func testDSTFallBackKeepsSameDayAsToday() {
        let cal = calendar(timeZone: "America/Havana")
        let now = date(2026, 11, 1, 12, 0, in: cal)
        let target = date(2026, 11, 1, 20, 0, in: cal)

        XCTAssertTrue(format(target, now: now, calendar: cal).hasPrefix("本日"))
    }

    func testDSTFallBackDoesNotMislabelNextDay() {
        let cal = calendar(timeZone: "America/Havana")
        let now = date(2026, 11, 1, 22, 0, in: cal)
        let target = date(2026, 11, 2, 1, 0, in: cal)

        XCTAssertTrue(format(target, now: now, calendar: cal).hasPrefix("明日"))
    }
}
