import XCTest
@testable import TakometaCore

/// CLI 出力に非公開の符牒が漏れないことを検査する（N-2c）。
///
/// 判定規則は `scripts/make-release.sh` の V-6 と一致させる:
/// - `#` で始まる行と空行を除外する（awk 'NF && $0 !~ /^[[:space:]]*#/'）
/// - 大小文字を区別する部分一致（grep -aFq）
///
/// **テストコードに符牒をリテラルで書かない**。書くとテストファイル自体が検出語を
/// 含むことになる。実 fixture をデコーダに通して入力を得る。
final class CodenameLeakTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CodenameLeakTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 検出語リストを V-6 と同じ規則で読む。
    /// 読めない・0語はテスト失敗（fail-closed）——網が外れたまま緑になるのを防ぐ
    private func codenameTerms() throws -> [String] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "codename-identifiers", withExtension: "txt"),
            "検出語リストが見つからない（fail-closed）")
        let text = try String(contentsOf: url, encoding: .utf8)
        let terms = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }
        XCTAssertFalse(terms.isEmpty, "検出語が0語（fail-closed）")
        return terms
    }

    /// 符牒を含む窓を持つスナップショットを実 fixture から作る。
    ///
    /// Claude の fixture は使えない——符牒がトップレベルの未知キーにあり windows に載らない。
    private func snapshotWithCodenames() throws -> UsageSnapshot {
        // 既存テストと同じ読み方（パスを resource 名に含める形式）
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/codex/multi_bucket", withExtension: "json"),
            "codex の fixture が見つからない")
        let decoded = try CodexRateLimitsDecoder.decode(try Data(contentsOf: url))
        return UsageSnapshot(
            provider: .codex, windows: decoded.windows,
            fetchedAt: now.addingTimeInterval(-142), source: .codexAppServer)
    }

    private func matches(_ terms: [String], in text: String) -> [String] {
        terms.filter { text.contains($0) }
    }

    func testInputActuallyContainsCodenames() throws {
        // vacuous pass の防止: 入力に符牒が無ければ、下のテストは何も検査していない
        let terms = try codenameTerms()
        let encoder = JSONEncoder()
        let inputJSON = try XCTUnwrap(
            String(data: try encoder.encode(try snapshotWithCodenames()), encoding: .utf8))
        XCTAssertFalse(
            matches(terms, in: inputJSON).isEmpty,
            "入力に検出語が1つも無い。この fixture では漏洩テストが空振りする")
    }

    func testJSONOutputHasNoCodenames() throws {
        let terms = try codenameTerms()
        let cache = SnapshotCache(directory: directory)
        try cache.save(try snapshotWithCodenames())

        let data = try UsageReportJSON.encode(
            UsageReportBuilder.build(cache: cache, now: now).report)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let leaked = matches(terms, in: text)
        XCTAssertTrue(leaked.isEmpty, "JSON 出力に検出語が \(leaked.count) 件漏れている（N-2c）")
    }

    func testHumanOutputHasNoCodenames() throws {
        let terms = try codenameTerms()
        let cache = SnapshotCache(directory: directory)
        try cache.save(try snapshotWithCodenames())

        let text = UsageReportText.render(
            UsageReportBuilder.build(cache: cache, now: now).report,
            now: now,
            calendar: Self.fixedCalendar,
            locale: Locale(identifier: "ja_JP"))
        let leaked = matches(terms, in: text)
        XCTAssertTrue(leaked.isEmpty, "人間向け出力に検出語が \(leaked.count) 件漏れている（N-2c）")
    }

    static var fixedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }
}
