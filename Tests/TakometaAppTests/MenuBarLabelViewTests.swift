import XCTest
@testable import TakometaApp
import TakometaCore

@MainActor
final class MenuBarLabelViewTests: XCTestCase {
    func testMenuBarInputPreservesAuthenticationRequiredWithoutSnapshot() {
        let input = menuBarInput(from: UsageStore.ProviderState(
            snapshot: nil,
            freshness: .authenticationRequired))

        XCTAssertTrue(input.windows.isEmpty)
        XCTAssertEqual(input.freshness, .authenticationRequired)
    }
}
