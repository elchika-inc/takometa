import XCTest
@testable import TakometaCore

final class ServiceStatusDecoderTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/status/\(name)", withExtension: "json"),
            "fixture が見つからない: \(name)")
        return try Data(contentsOf: url)
    }

    private func json(_ components: [(String, String)]) -> Data {
        let items = components
            .map { "{\"name\":\"\($0.0)\",\"status\":\"\($0.1)\"}" }
            .joined(separator: ",")
        return Data("{\"components\":[\(items)]}".utf8)
    }

    private func decode(_ data: Data, _ name: String) -> ServiceStatus {
        ServiceStatusDecoder.decode(data, componentName: name)
    }

    // MARK: - 実 fixture（両プロバイダー・N-11）

    func testOpenAIFixtureDecodes() throws {
        // OpenAI は description キーを持たない。非 Optional でデコードすると
        // ここだけが必ず落ち、Codex の障害表示が恒久的に unknown になる
        XCTAssertEqual(decode(try fixture("openai_components"), "Codex API"), .normal)
    }

    func testClaudeFixtureDecodes() throws {
        XCTAssertEqual(decode(try fixture("claude_components"), "Claude Code"), .normal)
    }

    // MARK: - 異常系（N-4）

    func testKnownDegradedValues() {
        for raw in ["degraded_performance", "partial_outage", "major_outage", "under_maintenance"] {
            XCTAssertEqual(
                decode(json([("Target", raw)]), "Target"), .degraded(raw: raw),
                "\(raw) は degraded で生の値を保持する")
        }
    }

    func testUnknownStatusIsDegradedNotNormal() {
        // 両者は別実装なので、片方だけが新しい値を返しうる（N-4）
        XCTAssertEqual(
            decode(json([("Target", "something_new")]), "Target"),
            .degraded(raw: "something_new"))
    }

    // MARK: - fail-closed（N-3）

    func testMissingComponentIsUnknown() {
        // 最も静かに壊れる経路。名前が変わった瞬間から永久に正常と表示し続けるのを防ぐ
        XCTAssertEqual(decode(json([("Other", "operational")]), "Target"), .unknown)
    }

    func testEmptyComponentsIsUnknown() {
        XCTAssertEqual(decode(json([]), "Target"), .unknown)
    }

    func testBrokenJSONIsUnknown() {
        XCTAssertEqual(decode(Data("{ broken".utf8), "Target"), .unknown)
    }

    func testComponentsNotAnArrayIsUnknown() {
        XCTAssertEqual(
            decode(Data("{\"components\":\"nope\"}".utf8), "Target"), .unknown)
    }

    func testPartialNameDoesNotMatch() {
        XCTAssertEqual(decode(json([("Codex APIs", "operational")]), "Codex API"), .unknown)
        XCTAssertEqual(decode(json([("Codex", "operational")]), "Codex API"), .unknown)
    }

    // MARK: - 同名重複（N-3・OpenAI の Login が実際に2件ある）

    func testDuplicateNamesTakeWorstStatus() {
        // first(where:) だと配列順に依存し、障害を隠す
        XCTAssertEqual(
            decode(json([("T", "operational"), ("T", "major_outage")]), "T"),
            .degraded(raw: "major_outage"))
        // 順序を入れ替えても同じ
        XCTAssertEqual(
            decode(json([("T", "major_outage"), ("T", "operational")]), "T"),
            .degraded(raw: "major_outage"))
    }

    func testDuplicateNamesSeverityOrder() {
        // major_outage > partial_outage > degraded_performance > under_maintenance > 未知 > operational
        XCTAssertEqual(
            decode(json([("T", "under_maintenance"), ("T", "major_outage")]), "T"),
            .degraded(raw: "major_outage"))
        XCTAssertEqual(
            decode(json([("T", "partial_outage"), ("T", "degraded_performance")]), "T"),
            .degraded(raw: "partial_outage"))
        XCTAssertEqual(
            decode(json([("T", "unknown_value"), ("T", "under_maintenance")]), "T"),
            .degraded(raw: "under_maintenance"), "既知の異常を未知より優先する")
        XCTAssertEqual(
            decode(json([("T", "operational"), ("T", "unknown_value")]), "T"),
            .degraded(raw: "unknown_value"), "未知は operational より優先する")
    }

    func testDuplicateAllOperationalIsNormal() {
        XCTAssertEqual(decode(json([("T", "operational"), ("T", "operational")]), "T"), .normal)
    }
}
