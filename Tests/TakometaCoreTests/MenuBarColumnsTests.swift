import XCTest
@testable import TakometaCore

final class MenuBarColumnsTests: XCTestCase {
    private func col(_ title: String, _ value: String) -> MenuBarColumn {
        MenuBarColumn(title: title, value: value, style: .normal)
    }

    func testAccessibilityTextJoinsTitleAndValue() {
        let columns = MenuBarColumns(groups: [[col("5h", "34"), col("1w", "52")]])
        XCTAssertEqual(columns.accessibilityText, "5h 34 1w 52")
    }

    func testAccessibilityTextOmitsValueWhenBlank() {
        // ラベル列と "--" 列は value が空白1文字。title のみを出す
        let columns = MenuBarColumns(groups: [[col("CX", " "), col("--", " ")]])
        XCTAssertEqual(columns.accessibilityText, "CX --")
    }

    func testAccessibilityTextIncludesFreshnessMark() {
        // マーク列は title が空白1文字なので value のみが出る
        let columns = MenuBarColumns(groups: [[col("CX", " "), col("1w", "52"), col(" ", "⏱")]])
        XCTAssertEqual(columns.accessibilityText, "CX 1w 52 ⏱")
    }

    func testAccessibilityTextSeparatesGroupsWithTwoSpaces() {
        let columns = MenuBarColumns(groups: [
            [col("CX", " "), col("5h", "34"), col("1w", "52"), col("他", "+1"), col(" ", "⏱")],
            [col("CL", " "), col("1w", "20")],
        ])
        XCTAssertEqual(columns.accessibilityText, "CX 5h 34 1w 52 他 +1 ⏱  CL 1w 20")
    }

    func testAccessibilityTextOfEmptyGroupsIsEmpty() {
        XCTAssertEqual(MenuBarColumns(groups: []).accessibilityText, "")
    }

    func testMetricsFitWithinMenuBarHeight() {
        // N-7: 行の高さをフォントサイズへ詰める前提で、合計がメニューバー高さ 22pt に収まる。
        // 詰めありの実測: 8/14=22pt（採用）・9/13=22pt・10/13=23pt（超過）
        let total = MenuBarColumnsMetrics.titleFontSize + MenuBarColumnsMetrics.valueFontSize
        XCTAssertLessThanOrEqual(total, 22, "詰めても 22pt を超えないこと")
    }

    func testTitleIsSmallerThanValue() {
        // 上段は枠の名前、下段は使用率。数値の可読性を優先して下段を大きくする
        XCTAssertLessThan(
            MenuBarColumnsMetrics.titleFontSize,
            MenuBarColumnsMetrics.valueFontSize)
    }
}
