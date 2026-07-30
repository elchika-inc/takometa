import XCTest
@testable import TakometaCore

final class NotificationPersistenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testStoresRoundTrip() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateStore = NotificationStateStore(directory: directory)
        let baselineStore = DailyBaselineStore(directory: directory)
        let state = NotificationState(windows: [
            "codex|weekly|weeklyAll": .init(
                threshold: .init(firedAt: now, basisResetsAt: now.addingTimeInterval(3600)),
                dailyFiredOn: "2027-01-15"),
        ])
        let baselines = [
            "codex|weekly|weeklyAll": DailyBaseline(
                day: "2027-01-15",
                usedPercent: 12,
                resetsAt: now.addingTimeInterval(3600)),
        ]

        try stateStore.save(state)
        try baselineStore.save(baselines)

        XCTAssertEqual(stateStore.load(), state)
        XCTAssertEqual(baselineStore.load(), baselines)
    }

    func testMissingFilesLoadEmptyValues() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(NotificationStateStore(directory: directory).load(), NotificationState())
        XCTAssertEqual(DailyBaselineStore(directory: directory).load(), [:])
    }

    func testCorruptedFilesLoadEmptyValues() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent("notification-state.json"))
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent("daily-baselines.json"))

        XCTAssertEqual(NotificationStateStore(directory: directory).load(), NotificationState())
        XCTAssertEqual(DailyBaselineStore(directory: directory).load(), [:])
    }

    func testSavedJSONContainsNoCredentialMarkers() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateStore = NotificationStateStore(directory: directory)
        let baselineStore = DailyBaselineStore(directory: directory)

        try stateStore.save(NotificationState(windows: [
            "claude|weekly|weeklyAll": .init(
                limitReached: .init(firedAt: now, basisResetsAt: nil)),
        ]))
        try baselineStore.save([
            "claude|weekly|weeklyAll": DailyBaseline(
                day: "2027-01-15",
                usedPercent: 25,
                resetsAt: nil),
        ])

        for name in ["notification-state.json", "daily-baselines.json"] {
            let text = try String(
                contentsOf: directory.appendingPathComponent(name),
                encoding: .utf8)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("accessToken"))
            XCTAssertFalse(text.localizedCaseInsensitiveContains("Bearer"))
        }
    }

    func testFiredMarkThresholdRoundTrips() throws {
        let state = NotificationState(windows: [
            "codex|weekly|weeklyAll": .init(
                threshold: .init(
                    firedAt: Date(timeIntervalSince1970: 1),
                    basisResetsAt: nil,
                    basisThreshold: 80),
                dailyFiredOn: "2026-07-27",
                dailyBasisThreshold: 20),
        ])
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(NotificationState.self, from: data)

        XCTAssertEqual(decoded.windows["codex|weekly|weeklyAll"]?.threshold?.basisThreshold, 80)
        XCTAssertEqual(decoded.windows["codex|weekly|weeklyAll"]?.dailyBasisThreshold, 20)
    }

    func testLegacyStateWithoutThresholdFieldsDecodesToNil() throws {
        let json = """
        {"windows":{"codex|weekly|weeklyAll":{"threshold":{"firedAt":1,"basisResetsAt":2},"dailyFiredOn":"2026-07-27"}}}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(NotificationState.self, from: json)

        let flags = decoded.windows["codex|weekly|weeklyAll"]
        XCTAssertNotNil(flags?.threshold)
        XCTAssertNil(flags?.threshold?.basisThreshold)
        XCTAssertNil(flags?.dailyBasisThreshold)
        XCTAssertEqual(flags?.dailyFiredOn, "2026-07-27")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
