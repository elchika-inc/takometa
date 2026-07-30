import CryptoKit
import XCTest
@testable import TakometaCore

final class HistoryPointTests: XCTestCase {
    private func key(_ provider: ProviderID, _ scope: RateLimitScope, _ kind: WindowKind?) -> String {
        HistoryWindowKey.make(provider: provider, scope: scope, kind: kind)
    }

    func testSessionAndWeeklyAllHaveNoSuffix() {
        XCTAssertEqual(key(.codex, .session, .session), "codex|session|session")
        XCTAssertEqual(key(.claude, .weeklyAll, .weekly), "claude|weekly|weeklyAll")
    }

    func testNilKindIsNone() {
        XCTAssertEqual(key(.codex, .session, nil), "codex|none|session")
    }

    func testOtherKindIncludesMinutes() {
        XCTAssertEqual(key(.codex, .session, .other(minutes: 1440)), "codex|other1440|session")
    }

    // MARK: - N-1: 生識別子を含めない

    func testModelScopeHidesIdentifier() {
        let k = key(.claude, .model(id: "secret-model-id", displayName: "Secret Display"), .weekly)
        XCTAssertFalse(k.contains("secret-model-id"))
        XCTAssertFalse(k.contains("Secret Display"))
        XCTAssertTrue(k.hasPrefix("claude|weekly|model|"))
        XCTAssertEqual(k.split(separator: "|").last?.count, 8, "8桁の16進サフィックス")
    }

    func testModelScopeUsesFirstEightHexDigitsOfSHA256() {
        let input = "abc"
        let cryptoKitPrefix = SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(8)

        XCTAssertEqual(String(cryptoKitPrefix), "ba7816bf")

        let k = key(.claude, .model(id: input, displayName: "表示名"), .weekly)
        XCTAssertEqual(k, "claude|weekly|model|ba7816bf")

        let suffix = k.split(separator: "|").last ?? ""
        XCTAssertTrue(suffix.allSatisfy { $0.isHexDigit })
    }

    func testOtherScopeHidesRaw() {
        let k = key(.codex, .other("secret_raw_key"), .weekly)
        XCTAssertFalse(k.contains("secret_raw_key"))
        XCTAssertTrue(k.hasPrefix("codex|weekly|other|"))
        XCTAssertEqual(k.split(separator: "|").last?.count, 8)
    }

    // MARK: - 安定性（48時間の追跡キーとして使うため）

    func testSameAssociatedValueGivesSameKey() {
        let a = key(.claude, .model(id: "m1", displayName: "D"), .weekly)
        let b = key(.claude, .model(id: "m1", displayName: "D"), .weekly)
        XCTAssertEqual(a, b)
    }

    func testDifferentAssociatedValueGivesDifferentKey() {
        let a = key(.claude, .model(id: "m1", displayName: "D"), .weekly)
        let b = key(.claude, .model(id: "m2", displayName: "D"), .weekly)
        XCTAssertNotEqual(a, b)
    }

    func testNilModelIDDifferentiatesDisplayNames() {
        let a = key(.claude, .model(id: nil, displayName: "A"), .weekly)
        let b = key(.claude, .model(id: nil, displayName: "B"), .weekly)
        XCTAssertNotEqual(a, b)
    }

    func testOtherScopeDifferentiatesRawValues() {
        let a = key(.codex, .other("rawA"), .weekly)
        let b = key(.codex, .other("rawB"), .weekly)
        XCTAssertNotEqual(a, b)
    }

    func testIdTakesPrecedenceOverDisplayName() {
        // id があれば id を使う。id が nil のときだけ displayName
        let withID = key(.claude, .model(id: "m1", displayName: "X"), .weekly)
        let sameIDOtherName = key(.claude, .model(id: "m1", displayName: "Y"), .weekly)
        XCTAssertEqual(withID, sameIDOtherName, "id が同じなら displayName が違ってもキーは同じ")
    }

    func testNilIDFallsBackToDisplayName() {
        let a = key(.claude, .model(id: nil, displayName: "D"), .weekly)
        let b = key(.claude, .model(id: nil, displayName: "D"), .weekly)
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.contains("D"))
    }

    // MARK: - N-1: 既存の通知キーを流用していない

    func testDoesNotMatchNotificationStateKey() {
        // NotificationWindowKey.stateKey は .model を id ?? displayName で展開しており
        // 生識別子を含む。同じ値を返してはならない
        let window = RateLimitWindow(
            id: "w", label: "L",
            scope: .model(id: "raw-id", displayName: "Raw Name"),
            usedPercent: 10, resetsAt: nil, kind: .weekly)
        let historyKey = key(.claude, window.scope, window.kind)
        let notificationKey = NotificationWindowKey.stateKey(provider: .claude, window: window)
        XCTAssertNotEqual(historyKey, notificationKey)
        XCTAssertTrue(notificationKey.contains("raw-id"), "既存キーは生識別子を含む（前提の確認）")
        XCTAssertFalse(historyKey.contains("raw-id"))
    }
}
