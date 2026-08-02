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
}
