import XCTest
@testable import TakometaCore

final class WindowKindTests: XCTestCase {
    func testSessionFrom300Minutes() {
        XCTAssertEqual(WindowKind(durationMinutes: 300), .session)
    }
    func testWeeklyFrom10080Minutes() {
        XCTAssertEqual(WindowKind(durationMinutes: 10080), .weekly)
    }
    func testOtherFromUnknownDuration() {
        XCTAssertEqual(WindowKind(durationMinutes: 1440), .other(minutes: 1440))
    }
}
