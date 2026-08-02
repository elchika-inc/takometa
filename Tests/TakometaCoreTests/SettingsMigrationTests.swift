import Foundation
import XCTest
@testable import TakometaCore

@MainActor
final class SettingsMigrationTests: XCTestCase {
    func testLegacyDisplayModeStringsMigrateOneStepUp() {
        XCTAssertEqual(DisplayMode.fromPersistedValue("compact"), .balanced)
        XCTAssertEqual(DisplayMode.fromPersistedValue("balanced"), .full)
        XCTAssertEqual(DisplayMode.fromPersistedValue("full"), .full)
    }

    func testNewDisplayModeStringsRoundTrip() {
        XCTAssertEqual(DisplayMode.fromPersistedValue("onePerProvider"), .balanced)
        XCTAssertEqual(DisplayMode.fromPersistedValue("icon"), .compact)
    }

    func testUnknownAndMissingDisplayModeFallBackToFull() {
        XCTAssertEqual(DisplayMode.fromPersistedValue("unknown"), .full)
        XCTAssertEqual(DisplayMode.fromPersistedValue(nil), .full)
    }

    func testDisplayModeMigrationIsIdempotent() {
        for legacy in ["compact", "balanced", "full"] {
            let once = DisplayMode.fromPersistedValue(legacy)
            let twice = DisplayMode.fromPersistedValue(once.rawValue)
            XCTAssertEqual(once, twice, "\(legacy) の移行が冪等でない")
        }
    }

    func testMigrateFromUserDefaultsReadsSavesAndReloadsAllDisplayModeStrings() throws {
        let cases: [(String?, DisplayMode)] = [
            ("compact", .balanced),
            ("balanced", .full),
            ("full", .full),
            ("onePerProvider", .balanced),
            ("icon", .compact),
            ("future", .full),
            (nil, .full),
        ]

        for (rawValue, expected) in cases {
            let (defaults, suiteName) = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            if let rawValue {
                defaults.set(rawValue, forKey: NotificationSettingsLoader.displayModeKey)
            }

            let store = SettingsStore(directory: directory, defaults: defaults)

            XCTAssertEqual(store.displayMode, expected, "永続化値: \(rawValue ?? "欠落")")
            let saved = try jsonObject(in: directory)
            XCTAssertEqual(saved["displayMode"] as? String, expected.rawValue)
            XCTAssertEqual(
                SettingsStore(directory: directory, defaults: defaults).displayMode, expected,
                "再読込でモードが移動した: \(rawValue ?? "欠落")")
        }
    }

    func testMigrateBuildsDocumentFromAllSixteenKeysAndDisplayMode() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: NotificationSettingsLoader.showCodexKey)
        defaults.set(false, forKey: NotificationSettingsLoader.showClaudeKey)
        defaults.set(false, forKey: NotificationSettingsLoader.codexShowSessionKey)
        defaults.set(false, forKey: NotificationSettingsLoader.codexShowWeeklyKey)
        defaults.set(false, forKey: NotificationSettingsLoader.codexShowModelKey)
        defaults.set(false, forKey: NotificationSettingsLoader.claudeShowSessionKey)
        defaults.set(false, forKey: NotificationSettingsLoader.claudeShowWeeklyKey)
        defaults.set(false, forKey: NotificationSettingsLoader.claudeShowModelKey)
        defaults.set(true, forKey: NotificationSettingsLoader.codexNotificationsEnabledKey)
        defaults.set(71.0, forKey: NotificationSettingsLoader.codexUsageThresholdKey)
        defaults.set(true, forKey: NotificationSettingsLoader.codexDailyEnabledKey)
        defaults.set(11.0, forKey: NotificationSettingsLoader.codexDailyThresholdKey)
        defaults.set(true, forKey: NotificationSettingsLoader.claudeNotificationsEnabledKey)
        defaults.set(92.0, forKey: NotificationSettingsLoader.claudeUsageThresholdKey)
        defaults.set(true, forKey: NotificationSettingsLoader.claudeDailyEnabledKey)
        defaults.set(37.0, forKey: NotificationSettingsLoader.claudeDailyThresholdKey)
        defaults.set(DisplayMode.compact.rawValue, forKey: NotificationSettingsLoader.displayModeKey)

        let document = NotificationSettingsLoader.migrate(from: defaults)

        XCTAssertEqual(document.version, 1)
        XCTAssertEqual(document.displayMode, .compact)
        XCTAssertEqual(document.providerOrder, ["codex", "claude"])
        XCTAssertEqual(document.providers["codex"], ProviderSettings(
            show: false,
            showSession: false,
            showWeekly: false,
            showModel: false,
            notificationsEnabled: true,
            usageThreshold: 71,
            dailyEnabled: true,
            dailyThreshold: 11))
        XCTAssertEqual(document.providers["claude"], ProviderSettings(
            show: false,
            showSession: false,
            showWeekly: false,
            showModel: false,
            notificationsEnabled: true,
            usageThreshold: 92,
            dailyEnabled: true,
            dailyThreshold: 37))
    }

    func testMigrateUsesProviderSettingsDefaultsForMissingKeys() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: NotificationSettingsLoader.codexShowWeeklyKey)
        defaults.set(true, forKey: NotificationSettingsLoader.claudeNotificationsEnabledKey)

        let document = NotificationSettingsLoader.migrate(from: defaults)
        var expectedCodex = ProviderSettings()
        expectedCodex.showWeekly = false
        var expectedClaude = ProviderSettings()
        expectedClaude.notificationsEnabled = true

        XCTAssertEqual(document.displayMode, .full)
        XCTAssertEqual(document.providers["codex"], expectedCodex)
        XCTAssertEqual(document.providers["claude"], expectedClaude)
    }

    func testMigrateUsesProviderSettingsDefaultsForWrongTypedValues() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("false", forKey: NotificationSettingsLoader.showCodexKey)
        defaults.set(0, forKey: NotificationSettingsLoader.codexShowSessionKey)
        defaults.set("true", forKey: NotificationSettingsLoader.codexNotificationsEnabledKey)
        defaults.set("75", forKey: NotificationSettingsLoader.codexUsageThresholdKey)
        defaults.set(1, forKey: NotificationSettingsLoader.codexDailyEnabledKey)
        defaults.set(true, forKey: NotificationSettingsLoader.codexDailyThresholdKey)

        let document = NotificationSettingsLoader.migrate(from: defaults)

        XCTAssertEqual(document.providers["codex"], ProviderSettings())
    }

    func testMigratePreservesFiniteThresholdsAndFallsBackForNonFiniteThresholds() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(1e100, forKey: NotificationSettingsLoader.codexUsageThresholdKey)
        defaults.set(-Double.infinity, forKey: NotificationSettingsLoader.codexDailyThresholdKey)
        defaults.set(Double.infinity, forKey: NotificationSettingsLoader.claudeUsageThresholdKey)
        defaults.set(50.1, forKey: NotificationSettingsLoader.claudeDailyThresholdKey)

        let document = NotificationSettingsLoader.migrate(from: defaults)

        XCTAssertEqual(document.providers["codex"]?.usageThreshold, 1e100)
        XCTAssertEqual(document.providers["codex"]?.dailyThreshold, ProviderSettings().dailyThreshold)
        XCTAssertEqual(document.providers["claude"]?.usageThreshold, ProviderSettings().usageThreshold)
        XCTAssertEqual(document.providers["claude"]?.dailyThreshold, 50.1)
    }

    func testSettingsStoreMigratesOnlyWhenJSONIsAbsent() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        setAllMigrationValues(in: defaults)
        let missingDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: missingDirectory) }

        let migrated = SettingsStore(directory: missingDirectory, defaults: defaults)

        let migratedCodex = ProviderSettings(
            show: false,
            showSession: false,
            showWeekly: false,
            showModel: false,
            notificationsEnabled: true,
            usageThreshold: 71,
            dailyEnabled: true,
            dailyThreshold: 11)
        let migratedClaude = ProviderSettings(
            show: false,
            showSession: false,
            showWeekly: false,
            showModel: false,
            notificationsEnabled: true,
            usageThreshold: 92,
            dailyEnabled: true,
            dailyThreshold: 37)
        XCTAssertEqual(migrated.displayMode, .balanced)
        XCTAssertEqual(migrated.providerOrder, ["codex", "claude"])
        XCTAssertEqual(migrated.providers["codex"], migratedCodex)
        XCTAssertEqual(migrated.providers["claude"], migratedClaude)
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsURL(in: missingDirectory).path))
        let saved = try jsonObject(in: missingDirectory)
        XCTAssertEqual(saved["version"] as? Int, 1)
        XCTAssertEqual(saved["displayMode"] as? String, DisplayMode.balanced.rawValue)
        XCTAssertEqual(saved["providerOrder"] as? [String], ["codex", "claude"])
        let reloaded = SettingsStore(directory: missingDirectory, defaults: defaults)
        XCTAssertEqual(reloaded.providers["codex"], migratedCodex)
        XCTAssertEqual(reloaded.providers["claude"], migratedClaude)

        let existingDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: existingDirectory) }
        try writeJSON("""
        {"version":1,"displayMode":"compact","providerOrder":["claude","codex"],"providers":{
          "codex":{"show":true,"showSession":true,"showWeekly":true,"showModel":true,
                   "notificationsEnabled":false,"usageThreshold":80,"dailyEnabled":false,"dailyThreshold":20},
          "claude":{"show":false,"showSession":true,"showWeekly":false,"showModel":true,
                    "notificationsEnabled":false,"usageThreshold":66,"dailyEnabled":true,"dailyThreshold":33}
        }}
        """, in: existingDirectory)

        let loaded = SettingsStore(directory: existingDirectory, defaults: defaults)

        XCTAssertEqual(loaded.displayMode, .balanced)
        XCTAssertEqual(loaded.providerOrder, ["claude", "codex"])
        XCTAssertEqual(loaded.providers["codex"], ProviderSettings())
        XCTAssertEqual(loaded.providers["claude"], ProviderSettings(
            show: false,
            showSession: true,
            showWeekly: false,
            showModel: true,
            notificationsEnabled: false,
            usageThreshold: 66,
            dailyEnabled: true,
            dailyThreshold: 33))
    }

    func testCorruptExistingJSONDoesNotMigrateDefaultsAndRegeneratesDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        setAllMigrationValues(in: defaults)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeJSON("{not-json", in: directory)

        let store = SettingsStore(directory: directory, defaults: defaults)

        XCTAssertEqual(store.displayMode, .full)
        XCTAssertEqual(store.providers["codex"], ProviderSettings())
        XCTAssertEqual(store.providers["claude"], ProviderSettings())
        let saved = try jsonObject(in: directory)
        XCTAssertEqual(saved["version"] as? Int, 1)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "SettingsMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func setAllMigrationValues(in defaults: UserDefaults) {
        defaults.set(false, forKey: NotificationSettingsLoader.showCodexKey)
        defaults.set(false, forKey: NotificationSettingsLoader.showClaudeKey)
        defaults.set(false, forKey: NotificationSettingsLoader.codexShowSessionKey)
        defaults.set(false, forKey: NotificationSettingsLoader.codexShowWeeklyKey)
        defaults.set(false, forKey: NotificationSettingsLoader.codexShowModelKey)
        defaults.set(false, forKey: NotificationSettingsLoader.claudeShowSessionKey)
        defaults.set(false, forKey: NotificationSettingsLoader.claudeShowWeeklyKey)
        defaults.set(false, forKey: NotificationSettingsLoader.claudeShowModelKey)
        defaults.set(true, forKey: NotificationSettingsLoader.codexNotificationsEnabledKey)
        defaults.set(71.0, forKey: NotificationSettingsLoader.codexUsageThresholdKey)
        defaults.set(true, forKey: NotificationSettingsLoader.codexDailyEnabledKey)
        defaults.set(11.0, forKey: NotificationSettingsLoader.codexDailyThresholdKey)
        defaults.set(true, forKey: NotificationSettingsLoader.claudeNotificationsEnabledKey)
        defaults.set(92.0, forKey: NotificationSettingsLoader.claudeUsageThresholdKey)
        defaults.set(true, forKey: NotificationSettingsLoader.claudeDailyEnabledKey)
        defaults.set(37.0, forKey: NotificationSettingsLoader.claudeDailyThresholdKey)
        defaults.set(DisplayMode.balanced.rawValue, forKey: NotificationSettingsLoader.displayModeKey)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsMigrationTests.\(UUID().uuidString)", isDirectory: true)
    }

    private func settingsURL(in directory: URL) -> URL {
        directory.appendingPathComponent("provider-settings.json", isDirectory: false)
    }

    private func writeJSON(_ json: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: settingsURL(in: directory))
    }

    private func jsonObject(in directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL(in: directory))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
