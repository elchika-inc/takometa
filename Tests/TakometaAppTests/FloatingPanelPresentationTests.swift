import SwiftUI
import XCTest
@testable import TakometaApp

@MainActor
final class FloatingPanelPresentationTests: XCTestCase {
    // 旧 testPresentationActivatesApplicationBeforeOpeningWindow は削除した。
    // activate→open の順序契約は Window シーン時代のもので、NSPanel 化
    // （FloatingPanelController）によりアクティベーション自体が不要になった。
    // 新しい表示契約は FloatingPanelControllerTests が固定する。

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
