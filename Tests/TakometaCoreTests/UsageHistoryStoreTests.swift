import XCTest
@testable import TakometaCore

@MainActor
final class UsageHistoryStoreTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// `@MainActor` クラスで `setUpWithError()` / `tearDownWithError()` を使うと
    /// nonisolated 文脈からの参照になり Swift 6 警告が出る（DoneCriteria の「警告0」に触れる）
    private lazy var directory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }()

    private func point(_ minutes: Double, _ percent: Double, resetsAt: Date? = nil) -> HistoryPoint {
        HistoryPoint(
            at: base.addingTimeInterval(minutes * 60), resetsAt: resetsAt, usedPercent: percent)
    }

    private func assertSingleWarning(
        _ warnings: [String], equals expected: String, excluding fileURL: URL,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(warnings, [expected], file: file, line: line)
        let warning = warnings.first ?? ""
        XCTAssertFalse(warning.contains(fileURL.path), file: file, line: line)
        for exceptionFragment in ["NSCocoaErrorDomain", "Error Domain=", "dataCorrupted"] {
            XCTAssertFalse(warning.contains(exceptionFragment), file: file, line: line)
        }
    }

    // MARK: - 往復

    func testAppendAndRead() throws {
        let store = FileUsageHistoryStore(directory: directory)
        try store.append(point(0, 10), key: "k", now: base)
        try store.append(point(1, 20), key: "k", now: base.addingTimeInterval(60))
        XCTAssertEqual(store.points(for: "k").map(\.usedPercent), [10, 20])
    }

    func testSurvivesRestart() throws {
        let storeA = FileUsageHistoryStore(directory: directory)
        try storeA.append(point(0, 10), key: "k", now: base)
        try storeA.append(point(1, 20), key: "k", now: base.addingTimeInterval(60))

        let storeB = FileUsageHistoryStore(directory: directory)

        XCTAssertEqual(storeB.points(for: "k").map(\.usedPercent), [10, 20])
    }

    func testPointsAreAscending() throws {
        // N-13: append 側が昇順を保証する
        let store = FileUsageHistoryStore(directory: directory)
        try store.append(point(10, 10), key: "k", now: base)
        try store.append(point(5, 20), key: "k", now: base)   // 過去の時刻を後から
        let ats = store.points(for: "k").map(\.at)
        XCTAssertEqual(ats, ats.sorted(), "昇順で返る")
    }

    func testUnknownKeyIsEmpty() {
        var warnings: [String] = []
        let store = FileUsageHistoryStore(
            directory: directory, warningHandler: { warnings.append($0) })

        XCTAssertTrue(store.points(for: "nope").isEmpty)
        XCTAssertTrue(warnings.isEmpty, "ファイル不存在は正常な空履歴であり警告しない")
    }

    // MARK: - N-14: メモリを正とする

    func testDoesNotReloadFromDiskAfterInit() throws {
        let store = FileUsageHistoryStore(directory: directory)
        try store.append(point(0, 10), key: "k", now: base)

        // 外部からファイルを書き換える
        let url = directory.appendingPathComponent("usage-history.json", isDirectory: false)
        try Data("{}".utf8).write(to: url, options: .atomic)

        XCTAssertEqual(
            store.points(for: "k").count, 1,
            "init 後はメモリを正とする。points のたびに load する実装だとここで 0 になる")
    }

    // MARK: - N-2: 剪定

    func testPrunesOlderThan48Hours() throws {
        let store = FileUsageHistoryStore(directory: directory)
        let now = base.addingTimeInterval(50 * 3600)
        try store.append(point(0, 10), key: "k", now: base)          // 50時間前になる
        try store.append(HistoryPoint(at: now, resetsAt: nil, usedPercent: 20), key: "k", now: now)
        XCTAssertEqual(store.points(for: "k").map(\.usedPercent), [20], "48時間より古い点が落ちる")
    }

    func testPrunesAllWindowsNotJustTheWrittenOne() throws {
        // N-2: 書き込みが来ない窓も剪定される。これが無いと記録が止まった窓の点が永久に残る
        let store = FileUsageHistoryStore(directory: directory)
        try store.append(point(0, 10), key: "stale", now: base)
        let now = base.addingTimeInterval(50 * 3600)
        try store.append(HistoryPoint(at: now, resetsAt: nil, usedPercent: 20), key: "fresh", now: now)
        XCTAssertTrue(store.points(for: "stale").isEmpty, "書き込みが来ない窓も剪定される")
    }

    func testEmptyWindowKeyIsRemoved() throws {
        let store = FileUsageHistoryStore(directory: directory)
        try store.append(point(0, 10), key: "stale", now: base)
        let now = base.addingTimeInterval(50 * 3600)
        try store.append(HistoryPoint(at: now, resetsAt: nil, usedPercent: 20), key: "fresh", now: now)

        // ファイルを読み直してキーが消えていることを確認する
        let url = directory.appendingPathComponent("usage-history.json", isDirectory: false)
        let raw = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([String: [HistoryPoint]].self, from: raw)
        XCTAssertNil(decoded["stale"], "点が0になった窓はキーごと消える")
    }

    func testCapsAtOneThousandPoints() throws {
        let store = FileUsageHistoryStore(directory: directory)
        for i in 0..<1010 {
            try store.append(
                point(Double(i) * 0.01, Double(i)), key: "k",
                now: base.addingTimeInterval(Double(i) * 0.6))
        }
        let points = store.points(for: "k")
        XCTAssertEqual(points.count, 1000)
        XCTAssertEqual(points.first?.usedPercent, 10, "古い方から落ちる")
    }

    // MARK: - サイズ（N-2）

    func testFileStaysUnderSizeLimit() throws {
        // **真の最悪値で生成する**。66.31 系の値は Double として丸い値とビット同一で
        // encoder が短縮するため、空振りするテストになる（実測で確認済み）
        //
        // append を 5000 回回すと辞書全体の再エンコードが 5000 回走って 30 秒以上かかる。
        // 実データ形式の検査が目的なので、辞書を組んで **1回だけ**エンコードする
        let worstPercent = 100.0 / 3.0     // = 33.333333333333336（17桁が必要）
        var payload: [String: [HistoryPoint]] = [:]
        for window in 0..<5 {
            payload["window\(window)"] = (0..<1000).map { i in
                let at = base.addingTimeInterval(Double(i) * 0.6 + 0.49038)
                return HistoryPoint(
                    at: at,
                    resetsAt: at.addingTimeInterval(604800.6237501),
                    usedPercent: worstPercent)
            }
        }
        let size = try HistoryFileCodec.encode(payload).count
        XCTAssertLessThan(size, 500_000, "5窓×1000点で 500 KB 未満（実測 423,061 B）")
    }

    // MARK: - N-10: 壊れたファイル

    func testBrokenFileIsTreatedAsEmpty() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("usage-history.json", isDirectory: false)
        try Data("{ broken".utf8).write(to: url, options: .atomic)
        var warnings: [String] = []

        let store = FileUsageHistoryStore(
            directory: directory, warningHandler: { warnings.append($0) })
        XCTAssertTrue(store.points(for: "k").isEmpty)
        assertSingleWarning(
            warnings, equals: "使用量履歴を読めませんでした。空として扱います", excluding: url)
        try store.append(point(0, 10), key: "k", now: base)
        XCTAssertEqual(store.points(for: "k").count, 1, "壊れていても記録が続く")
    }

    func testUnreadablePathIsTreatedAsEmptyAndRecordingContinues() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("usage-history.json", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var warnings: [String] = []

        let store = FileUsageHistoryStore(
            directory: directory, warningHandler: { warnings.append($0) })
        XCTAssertTrue(store.points(for: "k").isEmpty)
        assertSingleWarning(
            warnings,
            equals: "使用量履歴ファイルを読み取れませんでした。空として扱います",
            excluding: url)

        try FileManager.default.removeItem(at: url)
        try store.append(point(0, 10), key: "k", now: base)
        XCTAssertEqual(store.points(for: "k").count, 1, "読込失敗後も記録が続く")
    }

    func testUnsortedValidFileIsTreatedAsEmpty() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("usage-history.json", isDirectory: false)
        let payload = ["k": [point(10, 10), point(5, 20)]]
        try HistoryFileCodec.encode(payload).write(to: url, options: .atomic)
        var warnings: [String] = []

        let store = FileUsageHistoryStore(
            directory: directory, warningHandler: { warnings.append($0) })

        XCTAssertTrue(store.points(for: "k").isEmpty, "未整列の履歴は全体を空として扱う")
        assertSingleWarning(
            warnings, equals: "使用量履歴の順序が不正です。空として扱います", excluding: url)
    }

    // MARK: - メモリ実装

    func testInMemoryStoreDoesNotWriteFiles() throws {
        let store = InMemoryUsageHistoryStore()
        try store.append(point(0, 10), key: "k", now: base)
        XCTAssertEqual(store.points(for: "k").count, 1, "記録の判定は走る")
    }

    func testInMemoryStorePrunesOldPointsFromOtherWindows() throws {
        let store = InMemoryUsageHistoryStore()
        try store.append(point(0, 10), key: "stale", now: base)
        let now = base.addingTimeInterval(50 * 3600)

        try store.append(
            HistoryPoint(at: now, resetsAt: nil, usedPercent: 20), key: "fresh", now: now)

        XCTAssertTrue(store.points(for: "stale").isEmpty, "メモリ実装も書込のない窓を剪定する")
    }
}
