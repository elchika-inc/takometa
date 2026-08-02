import SwiftUI
import XCTest
@testable import TakometaApp
import TakometaCore

/// stale の減光がメニューバーの描画経路（ImageRenderer）で実際に効くことを
/// 画素で固定する（#6）。`opacity` は View 修飾子なので型検査では守れず、
/// 描画結果を測らないと回帰に気づけない。
@MainActor
final class MenuBarIconsRenderingTests: XCTestCase {
    private func render(isStale: Bool, style: SegmentStyle = .normal) throws -> NSBitmapImageRep {
        let icon = MenuBarIcon(
            glyph: .gauge(.mid), style: style, isStale: isStale,
            accessibilityText: "test")
        let renderer = ImageRenderer(
            content: MenuBarIconsView(icons: MenuBarIcons(icons: [icon])).fixedSize())
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff))
    }

    /// 不透明度は描画済み画素のアルファ値に現れる。色（外観モード依存）ではなく
    /// アルファで測ることで、ライト/ダークのどちらで実行されても判定が揺れない
    private func maxAlpha(_ rep: NSBitmapImageRep) -> Double {
        var best = 0.0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                best = max(best, Double(color.alphaComponent))
            }
        }
        return best
    }

    func testStaleIconIsDimmedThroughImageRenderer() throws {
        let fresh = maxAlpha(try render(isStale: false))
        let stale = maxAlpha(try render(isStale: true))

        // fresh の上限は 1.0 ではない: .primary（labelColor）は素で約 85% アルファを
        // 持つ。絶対値ではなく stale との比率で opacity 0.45 の適用を固定する
        XCTAssertGreaterThan(fresh, 0.8, "fresh アイコンの描画が薄すぎる")
        XCTAssertEqual(stale, fresh * 0.45, accuracy: 0.05,
                       "stale アイコンに opacity 0.45 が効いていない")
    }

    func testStaleDimmingAppliesToWarningStyleToo() throws {
        let freshWarning = maxAlpha(try render(isStale: false, style: .warning))
        let staleWarning = maxAlpha(try render(isStale: true, style: .warning))

        XCTAssertEqual(staleWarning, freshWarning * 0.45, accuracy: 0.05)
    }
}
