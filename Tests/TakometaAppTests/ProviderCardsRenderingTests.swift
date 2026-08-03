import SwiftUI
import XCTest
@testable import TakometaApp
import TakometaCore

@MainActor
final class ProviderCardsRenderingTests: XCTestCase {
    private func render(_ card: ProviderCard) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: ProviderCardView(card: card).fixedSize())
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff))
    }

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

    func testCardRendersNonEmptyImage() throws {
        let rep = try render(ProviderCard(
            name: "Codex",
            ring: .gauge(percent: 53, style: .warning),
            rows: [ProviderCard.Row(label: "1w", percent: 53, style: .warning)],
            isStale: false))

        XCTAssertGreaterThan(rep.pixelsWide, 0)
        XCTAssertGreaterThan(maxAlpha(rep), 0.5)
    }

    func testStaleCardIsDimmed() throws {
        let card = ProviderCard(
            name: "Codex",
            ring: .gauge(percent: 53, style: .normal),
            rows: [], isStale: false)
        let staleCard = ProviderCard(
            name: "Codex",
            ring: .gauge(percent: 53, style: .normal),
            rows: [], isStale: true)

        let fresh = maxAlpha(try render(card))
        let stale = maxAlpha(try render(staleCard))

        // 多層 View では opacity が層ごとに掛かり合成で累積するため、
        // fresh × 0.6 の厳密一致は成立しない（不透明背景 0.6 の上に文字 0.51 が
        // 重なると合成アルファは約 0.80 になる）。減光が適用されていることを
        // 上下の境界で固定する: 減光なし(=fresh)より確実に薄く、消えてはいない
        XCTAssertGreaterThan(fresh, 0.95, "fresh カードの背景が不透明で描かれていない")
        XCTAssertLessThan(stale, fresh * 0.9, "stale カードに減光が効いていない")
        XCTAssertGreaterThan(stale, fresh * 0.5, "stale カードが薄すぎる（読めない）")
    }
}
