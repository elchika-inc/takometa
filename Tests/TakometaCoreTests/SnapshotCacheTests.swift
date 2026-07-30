import XCTest
@testable import TakometaCore

final class SnapshotCacheTests: XCTestCase {
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func snapshot() -> UsageSnapshot {
        UsageSnapshot(
            provider: .claude,
            windows: [RateLimitWindow(
                id: "claude.weekly", label: "Weekly",
                scope: .model(id: nil, displayName: "Fable"),
                usedPercent: 42,
                resetsAt: Date(timeIntervalSince1970: 1_800_003_600),
                severity: "normal", isActive: true, kind: .weekly)],
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: .claudeOAuth)
    }

    func testSaveLoadRoundTrip() throws {
        try withTemporaryDirectory { directory in
            let cache = SnapshotCache(directory: directory)
            let expected = snapshot()
            try cache.save(expected)
            XCTAssertEqual(cache.load(provider: .claude), expected)
        }
    }

    func testMissingProviderReturnsNil() throws {
        try withTemporaryDirectory { directory in
            XCTAssertNil(SnapshotCache(directory: directory).load(provider: .codex))
        }
    }

    func testCorruptedJSONReturnsNil() throws {
        try withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try Data("not-json".utf8).write(to: directory.appendingPathComponent("claude.json"))
            XCTAssertNil(SnapshotCache(directory: directory).load(provider: .claude))
        }
    }

    func testSavedJSONContainsNoCredentialFieldNames() throws {
        try withTemporaryDirectory { directory in
            let cache = SnapshotCache(directory: directory)
            try cache.save(snapshot())
            let text = try String(
                contentsOf: directory.appendingPathComponent("claude.json"),
                encoding: .utf8)
            XCTAssertFalse(text.contains("accessToken"))
            XCTAssertFalse(text.contains("Authorization"))
            XCTAssertFalse(text.localizedCaseInsensitiveContains("token"))
        }
    }
}
