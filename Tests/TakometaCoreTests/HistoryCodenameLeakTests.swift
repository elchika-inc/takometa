import XCTest
@testable import TakometaCore

/// 履歴ファイルに非公開の符牒が漏れないことを検査する（N-1）。
///
/// 判定規則は `scripts/make-release.sh` の V-6 と一致させる:
/// - `#` で始まる行と空行を除外する
/// - 大小文字を区別する部分一致
///
/// **テストコードに符牒をリテラルで書かない。** 実 fixture をデコーダに通して入力を得る。
@MainActor
final class HistoryCodenameLeakTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private lazy var directory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryLeak-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }()

    /// V-6 と同じ規則で検出語を読む。読めない・0語はテスト失敗（fail-closed）
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

    /// 符牒を含む窓を実 fixture から作る
    private func windowsWithCodenames() throws -> [RateLimitWindow] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/codex/multi_bucket", withExtension: "json"),
            "codex の fixture が見つからない")
        return try CodexRateLimitsDecoder.decode(try Data(contentsOf: url)).windows
    }

    private func matches(_ terms: [String], in text: String) -> [String] {
        terms.filter { text.contains($0) }
    }

    func testInputActuallyContainsCodenames() throws {
        // vacuous pass の防止: 入力に符牒が無ければ下のテストは何も検査していない
        let terms = try codenameTerms()
        let windows = try windowsWithCodenames()
        let encoded = try XCTUnwrap(
            String(data: try JSONEncoder().encode(windows), encoding: .utf8))
        XCTAssertFalse(
            matches(terms, in: encoded).isEmpty,
            "入力に検出語が1つも無い。この fixture では漏洩テストが空振りする")
    }

    func testHistoryFileHasNoCodenames() throws {
        let terms = try codenameTerms()
        let store = FileUsageHistoryStore(directory: directory)
        for window in try windowsWithCodenames() {
            let key = HistoryWindowKey.make(
                provider: .codex, scope: window.scope, kind: window.kind)
            try store.append(
                HistoryPoint(at: base, resetsAt: window.resetsAt, usedPercent: window.usedPercent),
                key: key, now: base)
        }

        let file = directory.appendingPathComponent("usage-history.json", isDirectory: false)
        let text = try XCTUnwrap(String(data: try Data(contentsOf: file), encoding: .utf8))
        let leaked = matches(terms, in: text)
        XCTAssertTrue(leaked.isEmpty, "履歴ファイルに検出語が \(leaked.count) 件漏れている（N-1）")
    }
}
