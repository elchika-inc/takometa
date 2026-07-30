import XCTest
@testable import TakometaCore

final class ServiceStatusTextTests: XCTestCase {
    private func message(_ status: ServiceStatus, _ provider: ProviderID) -> String? {
        ServiceStatusText.message(for: status, provider: provider)
    }

    func testNormalShowsNothing() {
        XCTAssertNil(message(.normal, .codex))
        XCTAssertNil(message(.normal, .claude))
    }

    func testUnknownIsSameForBothProviders() {
        XCTAssertEqual(message(.unknown, .codex), "障害情報を取得できません")
        XCTAssertEqual(message(.unknown, .claude), "障害情報を取得できません")
    }

    func testDegradedMessagesForCodex() {
        XCTAssertEqual(
            message(.degraded(raw: "degraded_performance"), .codex),
            "OpenAI で機能低下が発生しています")
        XCTAssertEqual(
            message(.degraded(raw: "partial_outage"), .codex),
            "OpenAI で一部の障害が発生しています")
        XCTAssertEqual(
            message(.degraded(raw: "major_outage"), .codex),
            "OpenAI で障害が発生しています")
        XCTAssertEqual(
            message(.degraded(raw: "under_maintenance"), .codex),
            "OpenAI はメンテナンス中です")
        XCTAssertEqual(
            message(.degraded(raw: "something_new"), .codex),
            "OpenAI で異常が報告されています")
    }

    func testDegradedMessagesForClaude() {
        XCTAssertEqual(
            message(.degraded(raw: "degraded_performance"), .claude),
            "Anthropic で機能低下が発生しています")
        XCTAssertEqual(
            message(.degraded(raw: "major_outage"), .claude),
            "Anthropic で障害が発生しています")
        XCTAssertEqual(
            message(.degraded(raw: "under_maintenance"), .claude),
            "Anthropic はメンテナンス中です")
    }

    func testMaintenanceIsNotCalledOutage() {
        // テンプレート合成だと「障害が発生しています（メンテナンス中）」になる
        let text = try? XCTUnwrap(message(.degraded(raw: "under_maintenance"), .codex))
        XCTAssertEqual(text?.contains("障害"), false)
    }

    func testRawValueIsNotLeakedIntoMessage() {
        // 生の status 文字列をそのまま出さない（英語が UI へ出ない）
        let text = try? XCTUnwrap(message(.degraded(raw: "something_new"), .codex))
        XCTAssertEqual(text?.contains("something_new"), false)
    }
}
