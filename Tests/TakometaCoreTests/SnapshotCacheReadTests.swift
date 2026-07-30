import XCTest
@testable import TakometaCore

final class SnapshotCacheReadTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SnapshotCacheReadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, provider: ProviderID) throws {
        let url = directory.appendingPathComponent("\(provider.rawValue).json", isDirectory: false)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    func testAbsentWhenFileDoesNotExist() {
        let cache = SnapshotCache(directory: directory)
        XCTAssertEqual(cache.read(provider: .codex), .absent)
    }

    func testLoadedWhenSavedSnapshotExists() throws {
        let cache = SnapshotCache(directory: directory)
        let snapshot = UsageSnapshot(
            provider: .codex,
            windows: [],
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: .codexAppServer)
        try cache.save(snapshot)
        XCTAssertEqual(cache.read(provider: .codex), .loaded(snapshot))
    }

    func testUnreadableWhenJSONIsBroken() throws {
        try write("{ this is not json", provider: .codex)
        let cache = SnapshotCache(directory: directory)
        XCTAssertEqual(cache.read(provider: .codex), .unreadable)
    }

    func testUnreadableWhenSnapshotProviderDoesNotMatchFileProvider() throws {
        let snapshot = UsageSnapshot(
            provider: .claude,
            windows: [],
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: .claudeOAuth)
        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        try write(json, provider: .codex)

        let cache = SnapshotCache(directory: directory)
        XCTAssertEqual(cache.read(provider: .codex), .unreadable)
    }

    func testUnreadableWhenScopeDiscriminatorIsUnknown() throws {
        // 将来 case を足した版のアプリが書いたキャッシュを旧版が読む経路
        let json = """
        {
          "provider": "codex",
          "fetchedAt": 800000000,
          "source": "codexAppServer",
          "windows": [
            {
              "id": "x", "label": "y",
              "scope": { "case": "futureScopeAddedLater" },
              "usedPercent": 10
            }
          ]
        }
        """
        try write(json, provider: .codex)
        let cache = SnapshotCache(directory: directory)
        XCTAssertEqual(cache.read(provider: .codex), .unreadable)
    }

    func testExistingLoadBehaviorIsUnchanged() throws {
        // N-9: 既存 API の挙動を変えない（壊れた JSON では nil）
        try write("{ broken", provider: .claude)
        let cache = SnapshotCache(directory: directory)
        XCTAssertNil(cache.load(provider: .claude))
    }
}
