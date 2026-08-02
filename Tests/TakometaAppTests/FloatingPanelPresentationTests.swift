import SwiftUI
import XCTest
@testable import TakometaApp

@MainActor
final class FloatingPanelPresentationTests: XCTestCase {
    func testPresentationActivatesApplicationBeforeOpeningWindow() {
        var events: [String] = []

        presentFloatingPanel(
            activate: { events.append("activate") },
            open: { events.append("open") })

        XCTAssertEqual(events, ["activate", "open"])
    }

    func testToggleButtonFitsIconOnlyWidthForBothStates() throws {
        for isPresented in [false, true] {
            let renderer = ImageRenderer(content: FloatingPanelToggleButton(
                isPresented: isPresented,
                action: {}).fixedSize())
            renderer.scale = 1

            let image = try XCTUnwrap(renderer.nsImage)
            XCTAssertLessThanOrEqual(image.size.width, 44)
        }
    }
}
