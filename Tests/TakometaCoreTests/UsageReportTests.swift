import XCTest
@testable import TakometaCore

final class UsageReportTests: XCTestCase {
    private var directory: URL!

    /// 基準時刻。すべてのテストでこれを `now` として使う
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UsageReportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var cache: SnapshotCache { SnapshotCache(directory: directory) }

    private func save(
        provider: ProviderID,
        windows: [RateLimitWindow] = [],
        fetchedAt: Date,
        source: UsageSource = .codexAppServer
    ) throws {
        try cache.save(UsageSnapshot(
            provider: provider, windows: windows, fetchedAt: fetchedAt, source: source))
    }

    private func writeBroken(provider: ProviderID) throws {
        let url = directory.appendingPathComponent("\(provider.rawValue).json", isDirectory: false)
        try Data("{ broken".utf8).write(to: url, options: .atomic)
    }

    /// 出力 JSON を辞書として取り出す
    private func encodedObject(now: Date) throws -> [String: Any] {
        let built = UsageReportBuilder.build(cache: cache, now: now)
        let data = try UsageReportJSON.encode(built.report)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func providers(in object: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(object["providers"] as? [[String: Any]])
    }

    private func provider(
        _ id: String, in object: [String: Any]
    ) throws -> [String: Any] {
        let match = try providers(in: object).first { $0["id"] as? String == id }
        return try XCTUnwrap(match, "provider \(id) が列挙されていない")
    }

    // MARK: - プロバイダーの列挙（N-3b）

    func testBothProvidersAreListedWhenBothCachesExist() throws {
        try save(provider: .codex, fetchedAt: now.addingTimeInterval(-142))
        try save(provider: .claude, fetchedAt: now.addingTimeInterval(-10), source: .claudeOAuth)

        let object = try encodedObject(now: now)
        XCTAssertEqual(try providers(in: object).count, 2)
        XCTAssertEqual(try provider("codex", in: object)["available"] as? Bool, true)
        XCTAssertEqual(try provider("claude", in: object)["available"] as? Bool, true)
    }

    func testMissingProviderIsStillListedAsAbsent() throws {
        try save(provider: .codex, fetchedAt: now.addingTimeInterval(-142))

        let object = try encodedObject(now: now)
        XCTAssertEqual(try providers(in: object).count, 2, "配列から消してはいけない")
        let claude = try provider("claude", in: object)
        XCTAssertEqual(claude["available"] as? Bool, false)
        XCTAssertEqual(claude["reason"] as? String, "absent")
        XCTAssertNil(claude["fetchedAt"], "available: false なら fetchedAt を出さない")
        XCTAssertNil(claude["windows"])
    }

    func testAllProvidersAbsentWhenNoCache() throws {
        let object = try encodedObject(now: now)
        XCTAssertEqual(try providers(in: object).count, 2)
        for entry in try providers(in: object) {
            XCTAssertEqual(entry["available"] as? Bool, false)
            XCTAssertEqual(entry["reason"] as? String, "absent")
        }
    }

    func testBrokenCacheIsUnreadableNotAbsent() throws {
        try writeBroken(provider: .codex)

        let object = try encodedObject(now: now)
        let codex = try provider("codex", in: object)
        XCTAssertEqual(codex["available"] as? Bool, false)
        XCTAssertEqual(codex["reason"] as? String, "unreadable", "absent と区別する（N-10）")
    }

    func testBrokenCacheDoesNotSuppressHealthyProvider() throws {
        try writeBroken(provider: .codex)
        try save(provider: .claude, fetchedAt: now.addingTimeInterval(-10), source: .claudeOAuth)

        let object = try encodedObject(now: now)
        XCTAssertEqual(try provider("claude", in: object)["available"] as? Bool, true, "fail-open")
        XCTAssertEqual(try provider("codex", in: object)["available"] as? Bool, false)
    }

    // MARK: - 警告（N-10）

    func testUnreadableEmitsWarningWithoutPathOrException() throws {
        try writeBroken(provider: .codex)

        let built = UsageReportBuilder.build(cache: cache, now: now)
        XCTAssertEqual(built.warnings.count, 1)
        let warning = try XCTUnwrap(built.warnings.first)
        XCTAssertTrue(warning.contains("codex"))
        XCTAssertTrue(warning.contains("unreadable"))
        XCTAssertFalse(warning.contains("/"), "ファイルパスを含めない（N-2）")
        XCTAssertFalse(warning.lowercased().contains("error"), "例外メッセージを含めない")
    }

    func testAbsentDoesNotEmitWarning() throws {
        let built = UsageReportBuilder.build(cache: cache, now: now)
        XCTAssertTrue(built.warnings.isEmpty, "不在は異常ではないので警告しない")
    }

    func testEmptyWindowsEmitWarningWithoutPath() throws {
        try save(provider: .codex, windows: [], fetchedAt: now)

        let built = UsageReportBuilder.build(cache: cache, now: now)
        XCTAssertEqual(built.warnings.count, 1)
        let warning = try XCTUnwrap(built.warnings.first)
        XCTAssertTrue(warning.contains("codex"))
        XCTAssertTrue(warning.contains("枠"))
        XCTAssertFalse(warning.contains("/"), "ファイルパスを含めない（N-2）")
    }

    // MARK: - 時刻と鮮度

    func testAgeSecondsIsElapsedSeconds() throws {
        try save(provider: .codex, fetchedAt: now.addingTimeInterval(-142))

        let codex = try provider("codex", in: try encodedObject(now: now))
        XCTAssertEqual(codex["ageSeconds"] as? Int, 142)
        XCTAssertEqual(codex["fetchedAt"] as? String, "2027-01-15T07:57:38Z")
    }

    func testAgeSecondsIsClampedToZeroWhenFetchedAtIsInFuture() throws {
        // システム時刻の巻き戻り（N-7）
        try save(provider: .codex, fetchedAt: now.addingTimeInterval(3600))

        let codex = try provider("codex", in: try encodedObject(now: now))
        XCTAssertEqual(codex["ageSeconds"] as? Int, 0)
    }

    func testFreshnessIsNotEmitted() throws {
        try save(provider: .codex, fetchedAt: now.addingTimeInterval(-142))

        let data = try UsageReportJSON.encode(
            UsageReportBuilder.build(cache: cache, now: now).report)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("freshness"), "N-4")
        XCTAssertFalse(text.contains("\"stale\""), "N-4")
        XCTAssertFalse(text.contains("\"fresh\""), "N-4")
    }

    // MARK: - 全体

    func testSchemaVersionAndGeneratedAt() throws {
        let object = try encodedObject(now: now)
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["generatedAt"] as? String, "2027-01-15T08:00:00Z")
    }

    func testSourceIsEmittedForAvailableProvider() throws {
        try save(provider: .claude, fetchedAt: now, source: .claudeOAuth)
        XCTAssertEqual(
            try provider("claude", in: try encodedObject(now: now))["source"] as? String,
            "claudeOAuth")
    }

    func testNoSecretsOrPathsInOutput() throws {
        try save(provider: .codex, fetchedAt: now.addingTimeInterval(-142))

        let data = try UsageReportJSON.encode(
            UsageReportBuilder.build(cache: cache, now: now).report)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in ["token", "Authorization", "Bearer", "/Users/", "Application Support"] {
            XCTAssertFalse(text.contains(forbidden), "\(forbidden) が出力に含まれる（N-2）")
        }
    }

    func testHasUsableWindowReflectsWhetherAnyWindowExists() throws {
        XCTAssertFalse(
            UsageReportBuilder.build(cache: cache, now: now).report.hasUsableWindow)

        try save(provider: .codex, windows: [makeWindow(scope: .session)], fetchedAt: now)
        XCTAssertTrue(
            UsageReportBuilder.build(cache: cache, now: now).report.hasUsableWindow)
    }

    func testEmptyWindowsRemainAvailableButAreNotUsable() throws {
        try save(provider: .codex, windows: [], fetchedAt: now)

        let built = UsageReportBuilder.build(cache: cache, now: now)
        let codex = try provider("codex", in: try encodedObject(now: now))
        XCTAssertEqual(codex["available"] as? Bool, true)
        XCTAssertTrue(try XCTUnwrap(codex["windows"] as? [[String: Any]]).isEmpty)
        XCTAssertFalse(built.report.hasUsableWindow)
    }

    func testOneNonemptyProviderMakesReportUsable() throws {
        try save(provider: .codex, windows: [], fetchedAt: now)
        try save(
            provider: .claude,
            windows: [makeWindow(scope: .weeklyAll)],
            fetchedAt: now,
            source: .claudeOAuth)

        XCTAssertTrue(
            UsageReportBuilder.build(cache: cache, now: now).report.hasUsableWindow)
    }

    // MARK: - 窓の変換

    private func window(
        _ index: Int, ofProvider id: String, in object: [String: Any]
    ) throws -> [String: Any] {
        let windows = try XCTUnwrap(
            try provider(id, in: object)["windows"] as? [[String: Any]])
        return try XCTUnwrap(windows[safe: index], "窓 \(index) が無い")
    }

    private func makeWindow(
        scope: RateLimitScope,
        usedPercent: Double = 10,
        resetsAt: Date? = nil,
        isActive: Bool? = nil,
        kind: WindowKind? = nil
    ) -> RateLimitWindow {
        // id / label には任意の値を入れてよい（出力に出ないことを別テストで検証する）
        RateLimitWindow(
            id: "test-id", label: "test-label", scope: scope,
            usedPercent: usedPercent, resetsAt: resetsAt,
            isActive: isActive, kind: kind)
    }

    func testScopeAndWindowAreSeparateFields() throws {
        try save(
            provider: .codex,
            windows: [makeWindow(scope: .model(id: nil, displayName: "x"), kind: .weekly)],
            fetchedAt: now)

        let w = try window(0, ofProvider: "codex", in: try encodedObject(now: now))
        XCTAssertEqual(w["scope"] as? String, "model")
        XCTAssertEqual(w["window"] as? String, "weekly")
    }

    func testSessionAndWeeklyAllScopes() throws {
        try save(
            provider: .codex,
            windows: [
                makeWindow(scope: .session, kind: .session),
                makeWindow(scope: .weeklyAll, kind: .weekly),
            ],
            fetchedAt: now)

        let object = try encodedObject(now: now)
        XCTAssertEqual(try window(0, ofProvider: "codex", in: object)["scope"] as? String, "session")
        XCTAssertEqual(
            try window(1, ofProvider: "codex", in: object)["scope"] as? String, "weeklyAll")
        XCTAssertNil(
            try window(0, ofProvider: "codex", in: object)["index"],
            "session / weeklyAll に index は出ない")
    }

    func testWindowKeyIsOmittedWhenKindIsNil() throws {
        try save(
            provider: .codex,
            windows: [makeWindow(scope: .other("raw-key"), kind: nil)],
            fetchedAt: now)

        let w = try window(0, ofProvider: "codex", in: try encodedObject(now: now))
        XCTAssertNil(w["window"], "kind が nil なら window キーごと省略する（\"other\" へ潰さない）")
        XCTAssertNil(w["windowMinutes"])
    }

    func testWindowMinutesIsEmittedForOtherKind() throws {
        try save(
            provider: .codex,
            windows: [makeWindow(scope: .session, kind: .other(minutes: 1440))],
            fetchedAt: now)

        let w = try window(0, ofProvider: "codex", in: try encodedObject(now: now))
        XCTAssertEqual(w["window"] as? String, "other")
        XCTAssertEqual(w["windowMinutes"] as? Int64, 1440)
    }

    func testIndexFollowsArrayOrder() throws {
        try save(
            provider: .codex,
            windows: [
                makeWindow(scope: .model(id: nil, displayName: "a"), usedPercent: 1),
                makeWindow(scope: .model(id: nil, displayName: "b"), usedPercent: 2),
            ],
            fetchedAt: now)

        let object = try encodedObject(now: now)
        XCTAssertEqual(try window(0, ofProvider: "codex", in: object)["index"] as? Int, 1)
        XCTAssertEqual(try window(0, ofProvider: "codex", in: object)["usedPercent"] as? Double, 1)
        XCTAssertEqual(try window(1, ofProvider: "codex", in: object)["index"] as? Int, 2)
        XCTAssertEqual(try window(1, ofProvider: "codex", in: object)["usedPercent"] as? Double, 2)
    }

    func testModelAndOtherCountersAreIndependent() throws {
        // 1つのカウンタで数える実装だと other が #2 になり、この検証だけが落ちる
        try save(
            provider: .codex,
            windows: [
                makeWindow(scope: .model(id: nil, displayName: "a")),
                makeWindow(scope: .other("k")),
                makeWindow(scope: .model(id: nil, displayName: "b")),
            ],
            fetchedAt: now)

        let object = try encodedObject(now: now)
        XCTAssertEqual(try window(0, ofProvider: "codex", in: object)["index"] as? Int, 1)
        XCTAssertEqual(try window(1, ofProvider: "codex", in: object)["index"] as? Int, 1)
        XCTAssertEqual(try window(2, ofProvider: "codex", in: object)["index"] as? Int, 2)
        XCTAssertEqual(try window(1, ofProvider: "codex", in: object)["scope"] as? String, "other")
    }

    func testExpiredIsTrueWhenResetsAtIsPast() throws {
        try save(
            provider: .codex,
            windows: [makeWindow(scope: .session, resetsAt: now.addingTimeInterval(-1))],
            fetchedAt: now)

        let w = try window(0, ofProvider: "codex", in: try encodedObject(now: now))
        XCTAssertEqual(w["expired"] as? Bool, true)
    }

    func testExpiredIsFalseAndNotOmittedWhenResetsAtIsFuture() throws {
        try save(
            provider: .codex,
            windows: [makeWindow(scope: .session, resetsAt: now.addingTimeInterval(3600))],
            fetchedAt: now)

        let w = try window(0, ofProvider: "codex", in: try encodedObject(now: now))
        XCTAssertEqual(w["expired"] as? Bool, false, "false を省略しない")
    }

    func testResetsAtAndExpiredAreOmittedWhenNil() throws {
        try save(
            provider: .codex,
            windows: [makeWindow(scope: .session, resetsAt: nil)],
            fetchedAt: now)

        let w = try window(0, ofProvider: "codex", in: try encodedObject(now: now))
        XCTAssertNil(w["resetsAt"])
        XCTAssertNil(w["expired"], "resetsAt が無いなら expired も出さない")
    }

    func testIsActiveIsEmittedOnlyWhenPresent() throws {
        try save(
            provider: .claude,
            windows: [
                makeWindow(scope: .session, isActive: true),
                makeWindow(scope: .weeklyAll, isActive: nil),
            ],
            fetchedAt: now, source: .claudeOAuth)

        let object = try encodedObject(now: now)
        XCTAssertEqual(try window(0, ofProvider: "claude", in: object)["isActive"] as? Bool, true)
        XCTAssertNil(try window(1, ofProvider: "claude", in: object)["isActive"])
    }

    func testUsedPercentIsNotRounded() throws {
        try save(
            provider: .codex,
            windows: [makeWindow(scope: .session, usedPercent: 66.310000000000002)],
            fetchedAt: now)

        let w = try window(0, ofProvider: "codex", in: try encodedObject(now: now))
        let percent = try XCTUnwrap(w["usedPercent"] as? Double)
        XCTAssertEqual(percent, 66.310000000000002, accuracy: 0.000000001)
    }

    func testRawIdentifiersAreNotEmittedAsKeys() throws {
        try save(
            provider: .codex,
            windows: [makeWindow(scope: .model(id: "model-id", displayName: "Display Name"))],
            fetchedAt: now)

        let data = try UsageReportJSON.encode(
            UsageReportBuilder.build(cache: cache, now: now).report)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("test-id"), "RateLimitWindow.id を出さない（N-2b）")
        XCTAssertFalse(text.contains("test-label"), "RateLimitWindow.label を出さない（N-2b）")
        XCTAssertFalse(text.contains("Display Name"), "displayName を出さない（N-2b）")
        XCTAssertFalse(text.contains("model-id"), "model の id を出さない（N-2b）")
        XCTAssertFalse(text.contains("displayName"))
        XCTAssertFalse(text.contains("modelName"))
        XCTAssertFalse(text.contains("\"label\""))
        XCTAssertFalse(text.contains("\"id\" : \"test"))
    }

    func testOtherScopeRawValueIsNotEmitted() throws {
        try save(
            provider: .codex,
            windows: [makeWindow(scope: .other("secret_bucket_key"))],
            fetchedAt: now)

        let data = try UsageReportJSON.encode(
            UsageReportBuilder.build(cache: cache, now: now).report)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("secret_bucket_key"), "生の raw を出さない（N-2b）")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
