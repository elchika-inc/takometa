import AppKit
import XCTest
@testable import TakometaApp

@MainActor
final class ProviderLogoViewTests: XCTestCase {
    func testClaudeLogoAssetLoads() {
        let url = ProviderLogoView.claudeLogoURL
        XCTAssertNotNil(url)
        XCTAssertNotNil(url.flatMap { NSImage(contentsOf: $0) })
    }
}
