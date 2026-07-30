import XCTest

/// view がディスクへ直接触っていないことを検査する（N-14）。
///
/// view は別ターゲット（`TakometaApp`・executable）でテスト対象に入らないため、
/// ソースファイル本体を読んで検査する。**`CodenameLeakTests` の `Bundle.module`
/// 経由は使えない**——あれはリソース登録された txt を読む形で、
/// 別ターゲットの Swift ソースはリソースに含まれない。
final class ViewSourceTests: XCTestCase {
    func testPopoverDoesNotTouchHistoryStore() throws {
        // Tests/TakometaCoreTests/ViewSourceTests.swift → リポジトリルート
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TakometaCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ルート
        let source = root
            .appendingPathComponent("Sources/TakometaApp/ProviderPopoverView.swift")
        // 読めなければテスト失敗（fail-closed）。パス移動に気づけるようにする
        let text = try String(contentsOf: source, encoding: .utf8)
        for forbidden in ["UsageHistoryStore", "FileUsageHistoryStore", "HistoryWindowKey"] {
            XCTAssertFalse(
                text.contains(forbidden),
                "\(forbidden) を view から参照しない。UsageStore.recentPace を経由する（N-14）")
        }
    }
}
