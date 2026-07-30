import XCTest
@testable import TakometaCore

final class SmokeTests: XCTestCase {
    func testTargetLinks() {
        XCTAssertEqual(TakometaCoreInfo.name, "TakometaCore")
    }
}
