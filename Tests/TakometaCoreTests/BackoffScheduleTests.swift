import XCTest
@testable import TakometaCore

final class BackoffScheduleTests: XCTestCase {
    func testFetchBackoffIntervals() {
        XCTAssertEqual(BackoffSchedule.interval(consecutiveFailures: 0, normalInterval: 300), 300)
        XCTAssertEqual(BackoffSchedule.interval(consecutiveFailures: 1, normalInterval: 60), 60)
        XCTAssertEqual(BackoffSchedule.interval(consecutiveFailures: 1, normalInterval: 300), 60)
        XCTAssertEqual(BackoffSchedule.interval(consecutiveFailures: 2, normalInterval: 60), 120)
        XCTAssertEqual(BackoffSchedule.interval(consecutiveFailures: 3, normalInterval: 60), 300)
        XCTAssertEqual(BackoffSchedule.interval(consecutiveFailures: 4, normalInterval: 60), 900)
        XCTAssertEqual(BackoffSchedule.interval(consecutiveFailures: 10, normalInterval: 60), 900)
    }

    func testRestartBackoffDelays() {
        XCTAssertEqual(RestartBackoff.delay(attempt: 1), 1)
        XCTAssertEqual(RestartBackoff.delay(attempt: 2), 2)
        XCTAssertEqual(RestartBackoff.delay(attempt: 3), 4)
        XCTAssertEqual(RestartBackoff.delay(attempt: 4), 8)
        XCTAssertEqual(RestartBackoff.delay(attempt: 5), 16)
        XCTAssertEqual(RestartBackoff.delay(attempt: 6), 32)
        XCTAssertEqual(RestartBackoff.delay(attempt: 7), 60)
        XCTAssertEqual(RestartBackoff.delay(attempt: 10), 60)
    }
}
