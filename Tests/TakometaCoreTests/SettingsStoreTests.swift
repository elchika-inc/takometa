import Foundation
import XCTest
@testable import TakometaCore

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testShowsFloatingPanelDefaultsToFalseWhenKeyIsAbsent() throws {
        try withTemporaryDirectory { directory in
            try writeJSON("""
            {"version":1,"displayMode":"full","providerOrder":["codex","claude"],"providers":{}}
            """, in: directory)

            let store = try makeStore(directory: directory)
            XCTAssertFalse(store.showsFloatingPanel)
        }
    }

    func testShowsFloatingPanelRoundTrips() throws {
        try withTemporaryDirectory { directory in
            let store = try makeStore(directory: directory)
            XCTAssertFalse(store.showsFloatingPanel)

            store.updateShowsFloatingPanel(true)

            let saved = try jsonObject(in: directory)
            XCTAssertEqual(saved["showsFloatingPanel"] as? Bool, true)

            let reloaded = try makeStore(directory: directory)
            XCTAssertTrue(reloaded.showsFloatingPanel)
        }
    }

    func testShowsFloatingPanelIgnoresNonBooleanValue() throws {
        try withTemporaryDirectory { directory in
            try writeJSON("""
            {"version":1,"displayMode":"full","showsFloatingPanel":"yes",
             "providerOrder":["codex","claude"],"providers":{}}
            """, in: directory)

            let store = try makeStore(directory: directory)
            XCTAssertFalse(store.showsFloatingPanel)
        }
    }

    func testAbsentFileCreatesDefaultDocument() throws {
        try withTemporaryDirectory { directory in
            let store = try makeStore(directory: directory)

            XCTAssertEqual(store.displayMode, .full)
            XCTAssertEqual(store.providerOrder, ["codex", "claude"])
            XCTAssertEqual(store.providers, [
                "codex": ProviderSettings(),
                "claude": ProviderSettings(),
            ])
            let saved = try jsonObject(in: directory)
            XCTAssertEqual(saved["version"] as? Int, 1)
        }
    }

    func testUpdateSavesAtomicallyAndReloadRoundTrips() throws {
        try withTemporaryDirectory { directory in
            let store = try makeStore(directory: directory)

            store.update(provider: "codex") {
                $0.show = false
                $0.usageThreshold = 73
            }
            store.updateDisplayMode(.balanced)

            XCTAssertNil(store.lastErrorDescription)
            let reloaded = try makeStore(directory: directory)
            XCTAssertEqual(reloaded.displayMode, .balanced)
            XCTAssertEqual(reloaded.providers["codex"]?.show, false)
            XCTAssertEqual(reloaded.providers["codex"]?.usageThreshold, 73)
        }
    }

    func testJSONReadsAllLegacyAndNewDisplayModeStringsAndPersistsCanonicalValue() throws {
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
            try withTemporaryDirectory { directory in
                let displayModeField = rawValue.map { "\"displayMode\":\"\($0)\"," } ?? ""
                try writeJSON("""
                {"version":1,\(displayModeField)"providerOrder":["codex","claude"],"providers":{}}
                """, in: directory)

                let store = try makeStore(directory: directory)
                XCTAssertEqual(store.displayMode, expected, "永続化値: \(rawValue ?? "欠落")")

                // 任意の保存を契機に旧値・未知値も新しい正規値へ置き換える。
                store.update(provider: "codex") { $0.usageThreshold = 80 }
                let saved = try jsonObject(in: directory)
                XCTAssertEqual(saved["displayMode"] as? String, expected.rawValue)

                let reloaded = try makeStore(directory: directory)
                XCTAssertEqual(reloaded.displayMode, expected)
            }
        }
    }

    func testLabelRoundTrips() throws {
        try withTemporaryDirectory { directory in
            let store = try makeStore(directory: directory)
            store.update(provider: "codex") { $0.label = "Codex" }

            let reloaded = try makeStore(directory: directory)
            XCTAssertEqual(reloaded.providers["codex"]?.label, "Codex")
        }
    }

    func testRawLabelRoundTripsWithoutNormalizationInMemoryAndFile() throws {
        try withTemporaryDirectory { directory in
            let rawLabel = "  1234567\u{0000}\u{200B}\u{2028}  "
            let store = try makeStore(directory: directory)

            store.update(provider: "codex") { $0.label = rawLabel }

            let reloaded = try makeStore(directory: directory)
            XCTAssertEqual(reloaded.providers["codex"]?.label, rawLabel)

            let saved = try jsonObject(in: directory)
            let providers = try XCTUnwrap(saved["providers"] as? [String: Any])
            let codex = try XCTUnwrap(providers["codex"] as? [String: Any])
            XCTAssertEqual(codex["label"] as? String, rawLabel)
        }
    }

    func testMissingLabelDefaultsToEmptyAndKeepsOtherFields() throws {
        try withTemporaryDirectory { directory in
            try writeJSON("""
            {
              "version": 1,
              "displayMode": "full",
              "providerOrder": ["codex", "claude"],
              "providers": {
                "codex": { "show": false },
                "claude": {}
              }
            }
            """, in: directory)

            let store = try makeStore(directory: directory)
            XCTAssertEqual(store.providers["codex"]?.label, "")
            XCTAssertEqual(store.providers["codex"]?.show, false)
        }
    }

    func testNonStringLabelFallsBackToEmpty() throws {
        try withTemporaryDirectory { directory in
            try writeJSON("""
            {
              "version": 1,
              "displayMode": "full",
              "providerOrder": ["codex", "claude"],
              "providers": {
                "codex": { "label": 123 },
                "claude": {}
              }
            }
            """, in: directory)

            let store = try makeStore(directory: directory)
            XCTAssertEqual(store.providers["codex"]?.label, "")
        }
    }

    func testSyntaxErrorAndNonObjectRootRegenerateDefaults() throws {
        for invalidJSON in ["{not-json", "[1,2,3]"] {
            try withTemporaryDirectory { directory in
                try writeJSON(invalidJSON, in: directory)

                let store = try makeStore(directory: directory)

                XCTAssertEqual(store.providers["codex"], ProviderSettings())
                XCTAssertEqual(store.providers["claude"], ProviderSettings())
                let saved = try jsonObject(in: directory)
                XCTAssertEqual(saved["version"] as? Int, 1)
                XCTAssertNotNil(saved["providers"] as? [String: Any])
            }
        }
    }

    func testUnknownProviderEntryRemainsDeeplyUnchangedWhenKnownProviderIsSaved() throws {
        try withTemporaryDirectory { directory in
            try writeJSON("""
            {
              "version": 1,
              "displayMode": "full",
              "providerOrder": ["codex", "future", "claude"],
              "rootFuture": {"nested": 9},
              "providers": {
                "codex": {"show": true, "futureFlag": "keep"},
                "claude": {"show": true},
                "future": {
                  "show": "auto",
                  "usageThreshold": {"mode": "adaptive", "target": 72},
                  "endpoint": "https://example.invalid",
                  "nested": {"x": 1, "values": [true, "future"]}
                }
              }
            }
            """, in: directory)
            let original = try jsonObject(in: directory)
            let originalProviders = try XCTUnwrap(original["providers"] as? [String: Any])
            let originalFuture = try XCTUnwrap(originalProviders["future"])

            let store = try makeStore(directory: directory)
            store.update(provider: "codex") { $0.show = false }

            let saved = try jsonObject(in: directory)
            XCTAssertEqual((saved["rootFuture"] as? [String: Any])?["nested"] as? Int, 9)
            let providers = try XCTUnwrap(saved["providers"] as? [String: Any])
            let codex = try XCTUnwrap(providers["codex"] as? [String: Any])
            XCTAssertEqual(codex["show"] as? Bool, false)
            XCTAssertEqual(codex["futureFlag"] as? String, "keep")
            let savedFuture = try XCTUnwrap(providers["future"])
            XCTAssertEqual(
                try canonicalJSONData(savedFuture),
                try canonicalJSONData(originalFuture))
        }
    }

    func testUnknownVersionLoadsKnownValuesButInitAndUpdatesPreserveOriginalBytes() throws {
        try withTemporaryDirectory { directory in
            let original = Data("""
            { "version": 27, "displayMode": "compact", "providerOrder": ["claude"],
              "providers": { "claude": { "show": false, "usageThreshold": 61 } }, "future": true }
            """.utf8)
            try writeData(original, in: directory)

            let store = try makeStore(directory: directory)

            XCTAssertEqual(store.displayMode, .balanced)
            XCTAssertEqual(store.providers["claude"]?.show, false)
            XCTAssertEqual(store.providers["claude"]?.usageThreshold, 61)
            XCTAssertEqual(store.providers["codex"], ProviderSettings())
            XCTAssertEqual(store.providerOrder, ["claude", "codex"])
            XCTAssertEqual(try settingsData(in: directory), original)
            XCTAssertNotNil(store.lastErrorDescription)

            store.update(provider: "claude") { $0.show = true }
            store.updateDisplayMode(.full)

            XCTAssertEqual(store.providers["claude"]?.show, true)
            XCTAssertEqual(store.displayMode, .full)
            XCTAssertEqual(try settingsData(in: directory), original)
            XCTAssertNotNil(store.lastErrorDescription)
        }
    }

    func testVersionTypeMismatchIsUnknownVersionReadOnly() throws {
        try withTemporaryDirectory { directory in
            let original = Data("""
            {"version":"1","displayMode":"balanced","providerOrder":["codex","claude"],
             "providers":{"codex":{"show":false},"claude":{"show":true}}}
            """.utf8)
            try writeData(original, in: directory)

            let store = try makeStore(directory: directory)
            XCTAssertEqual(store.displayMode, .full)
            XCTAssertEqual(store.providers["codex"]?.show, false)
            XCTAssertNotNil(store.lastErrorDescription)
            XCTAssertEqual(try settingsData(in: directory), original)

            store.update(provider: "codex") { $0.show = true }
            XCTAssertEqual(try settingsData(in: directory), original)
        }
    }

    func testProviderOrderNormalizationAppliesAllRulesDeterministically() throws {
        try withTemporaryDirectory { directory in
            let original = Data("""
            {"version":1,"displayMode":"full",
             "providerOrder":["future-z","codex","codex","orphan","future-z"],
             "providers":{
               "codex":{"show":true},
               "future-z":{"show":false},
               "future-a":{"show":true}
             }}
            """.utf8)
            try writeData(original, in: directory)

            let store = try makeStore(directory: directory)

            XCTAssertEqual(store.providerOrder, ["future-z", "codex", "claude", "future-a"])
            XCTAssertEqual(store.providers["claude"], ProviderSettings())
            XCTAssertNil(store.providers["orphan"])
            XCTAssertEqual(try settingsData(in: directory), original)

            store.update(provider: "codex") { $0.show = false }

            let saved = try jsonObject(in: directory)
            XCTAssertEqual(saved["providerOrder"] as? [String], [
                "future-z", "codex", "claude", "future-a",
            ])
        }
    }

    func testSimultaneousKnownAndUnknownComplementsAppendKnownThenSortedUnknown() throws {
        try withTemporaryDirectory { directory in
            try writeJSON("""
            {"version":1,"displayMode":"full","providerOrder":["codex"],
             "providers":{
               "unknown-z":{"show":true},
               "codex":{"show":true},
               "unknown-a":{"show":false}
             }}
            """, in: directory)

            let store = try makeStore(directory: directory)

            XCTAssertEqual(store.providerOrder, ["codex", "claude", "unknown-a", "unknown-z"])
        }
    }

    func testMissingAndTypeMismatchProviderOrderUseFixedKnownOrderThenUnknowns() throws {
        for providerOrderField in ["", "\"providerOrder\": 42,"] {
            try withTemporaryDirectory { directory in
                try writeJSON("""
                {"version":1,"displayMode":"full",\(providerOrderField)
                 "providers":{"unknown":{"show":true},"claude":{"show":true},"codex":{"show":true}}}
                """, in: directory)

                let store = try makeStore(directory: directory)

                XCTAssertEqual(store.providerOrder, ["codex", "claude", "unknown"])
            }
        }
    }

    func testKnownIDAlreadyInOrderButMissingProviderIsDefaultedWithoutDuplicate() throws {
        try withTemporaryDirectory { directory in
            try writeJSON("""
            {"version":1,"displayMode":"full","providerOrder":["claude","codex"],
             "providers":{"codex":{"show":false}}}
            """, in: directory)

            let store = try makeStore(directory: directory)

            XCTAssertEqual(store.providerOrder, ["claude", "codex"])
            XCTAssertEqual(store.providers["claude"], ProviderSettings())
        }
    }

    func testPartialAndWrongTypedFieldsFallbackIndividuallyAndSaveCanonicalValues() throws {
        try withTemporaryDirectory { directory in
            try writeJSON("""
            {"version":1,"displayMode":"full","providerOrder":["codex","orphan"],"rootUnknown":8,
             "providers":{
               "codex":{"show":false,"showSession":"wrong","usageThreshold":64,
                        "dailyEnabled":true,"futureField":"keep"},
               "claude":{"showWeekly":false}
             }}
            """, in: directory)

            let store = try makeStore(directory: directory)

            XCTAssertEqual(store.providers["codex"], ProviderSettings(
                show: false,
                showSession: true,
                usageThreshold: 64,
                dailyEnabled: true))
            XCTAssertEqual(store.providers["claude"]?.showWeekly, false)

            store.update(provider: "codex") { $0.showModel = false }

            let saved = try jsonObject(in: directory)
            XCTAssertEqual(saved["rootUnknown"] as? Int, 8)
            XCTAssertEqual(saved["providerOrder"] as? [String], ["codex", "claude"])
            let providers = try XCTUnwrap(saved["providers"] as? [String: Any])
            let codex = try XCTUnwrap(providers["codex"] as? [String: Any])
            XCTAssertEqual(codex["showSession"] as? Bool, true)
            XCTAssertEqual(codex["futureField"] as? String, "keep")
            XCTAssertNil(codex["showSession"] as? String)
        }
    }

    func testInvalidDisplayModeFallsBackWithoutDroppingOtherDataAndIsReplacedOnSave() throws {
        for invalidDisplayMode in ["\"future\"", "17"] {
            try withTemporaryDirectory { directory in
                try writeJSON("""
                {"version":1,"displayMode":\(invalidDisplayMode),"providerOrder":["codex","claude"],
                 "rootUnknown":"keep","providers":{"codex":{"show":false},"claude":{"show":true}}}
                """, in: directory)

                let store = try makeStore(directory: directory)
                XCTAssertEqual(store.displayMode, .full)
                XCTAssertEqual(store.providers["codex"]?.show, false)

                store.updateDisplayMode(.balanced)

                let saved = try jsonObject(in: directory)
                XCTAssertEqual(saved["displayMode"] as? String, "onePerProvider")
                XCTAssertEqual(saved["rootUnknown"] as? String, "keep")
                let providers = try XCTUnwrap(saved["providers"] as? [String: Any])
                XCTAssertEqual((providers["codex"] as? [String: Any])?["show"] as? Bool, false)
            }
        }
    }

    func testMissingVersionActsAsVersionOneAndCanSave() throws {
        try withTemporaryDirectory { directory in
            try writeJSON("""
            {"displayMode":"compact","providerOrder":["codex","claude"],
             "future":"keep","providers":{"codex":{"show":false},"claude":{"show":true}}}
            """, in: directory)

            let store = try makeStore(directory: directory)
            XCTAssertNil(store.lastErrorDescription)
            XCTAssertEqual(store.displayMode, .balanced)
            XCTAssertEqual(store.providers["codex"]?.show, false)

            store.update(provider: "codex") { $0.show = true }

            let saved = try jsonObject(in: directory)
            XCTAssertEqual(saved["version"] as? Int, 1)
            XCTAssertEqual(saved["future"] as? String, "keep")
            let providers = try XCTUnwrap(saved["providers"] as? [String: Any])
            let codex = try XCTUnwrap(providers["codex"] as? [String: Any])
            XCTAssertEqual(codex["show"] as? Bool, true)
            XCTAssertEqual(codex["showSession"] as? Bool, true)
            XCTAssertEqual(codex["showWeekly"] as? Bool, true)
            XCTAssertEqual(codex["showModel"] as? Bool, true)
            XCTAssertEqual(codex["notificationsEnabled"] as? Bool, false)
            XCTAssertEqual(codex["dailyEnabled"] as? Bool, false)
        }
    }

    func testReadIOErrorUsesDefaultsAndSuppressesWrites() throws {
        try withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = settingsURL(in: directory)
            try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
            let before = try FileManager.default.attributesOfItem(atPath: fileURL.path)

            let store = try makeStore(directory: directory)

            XCTAssertEqual(store.providers["codex"], ProviderSettings())
            XCTAssertNotNil(store.lastErrorDescription)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fileURL.path), [])

            store.update(provider: "codex") { $0.show = false }

            XCTAssertEqual(store.providers["codex"]?.show, false)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fileURL.path), [])
            let after = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            XCTAssertEqual(before[.type] as? FileAttributeType, after[.type] as? FileAttributeType)
        }
    }

    func testSaveFailureRecordsErrorButKeepsInMemoryChanges() throws {
        let parent = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-a-directory".utf8).write(to: parent)

        let store = try makeStore(directory: parent)
        store.update(provider: "codex") { $0.show = false }
        store.updateDisplayMode(.compact)

        XCTAssertEqual(store.providers["codex"]?.show, false)
        XCTAssertEqual(store.displayMode, .compact)
        XCTAssertNotNil(store.lastErrorDescription)
        XCTAssertEqual(try Data(contentsOf: parent), Data("not-a-directory".utf8))
    }

    func testUnknownProviderUpdateIsNoOpAndDoesNotWrite() throws {
        try withTemporaryDirectory { directory in
            let original = Data("""
            {"version":1,"displayMode":"full","providerOrder":["codex","claude","future"],
             "providers":{"codex":{"show":true},"claude":{"show":true},"future":{"show":false}}}
            """.utf8)
            try writeData(original, in: directory)
            let store = try makeStore(directory: directory)

            store.update(provider: "future") { $0.show = true }
            store.update(provider: "absent") { $0.show = false }

            XCTAssertEqual(store.providers["future"]?.show, false)
            XCTAssertNil(store.providers["absent"])
            XCTAssertEqual(try settingsData(in: directory), original)
        }
    }

    func testFiniteJSONThresholdsArePreservedRegardlessOfUIRange() throws {
        try withTemporaryDirectory { directory in
            try writeJSON("""
            {"version":1,"displayMode":"full","providerOrder":["codex","claude"],
             "providers":{
               "codex":{"usageThreshold":1e100,"dailyThreshold":-1},
               "claude":{"usageThreshold":49.9,"dailyThreshold":50.1}
             }}
            """, in: directory)

            let store = try makeStore(directory: directory)

            XCTAssertEqual(store.providers["codex"]?.usageThreshold, 1e100)
            XCTAssertEqual(store.providers["codex"]?.dailyThreshold, -1)
            XCTAssertEqual(store.providers["claude"]?.usageThreshold, 49.9)
            XCTAssertEqual(store.providers["claude"]?.dailyThreshold, 50.1)
        }
    }

    func testThresholdBoundariesAndArbitraryInRangeValuesArePreserved() throws {
        for (usageThreshold, dailyThreshold) in [(50.0, 5.0), (95.0, 50.0), (94.25, 49.75)] {
            try withTemporaryDirectory { directory in
                try writeJSON("""
                {"version":1,"displayMode":"full","providerOrder":["codex","claude"],
                 "providers":{
                   "codex":{"usageThreshold":\(usageThreshold),"dailyThreshold":\(dailyThreshold)},
                   "claude":{}
                 }}
                """, in: directory)

                let store = try makeStore(directory: directory)

                XCTAssertEqual(store.providers["codex"]?.usageThreshold, usageThreshold)
                XCTAssertEqual(store.providers["codex"]?.dailyThreshold, dailyThreshold)
            }
        }
    }

    func testMenuBarLineCountDefaultsToOneAndRoundTrips() throws {
        try withTemporaryDirectory { directory in
            let store = try makeStore(directory: directory)
            XCTAssertEqual(store.menuBarLineCount, .one)

            store.updateMenuBarLineCount(.two)

            let reloaded = try makeStore(directory: directory)
            XCTAssertEqual(reloaded.menuBarLineCount, .two)
            let saved = try jsonObject(in: directory)
            XCTAssertEqual(saved["menuBarLineCount"] as? String, "two")
        }
    }

    func testMissingMenuBarLineCountUsesOne() throws {
        try withTemporaryDirectory { directory in
            try writeJSON("""
            {
              "version": 1,
              "displayMode": "full",
              "providerOrder": ["codex", "claude"],
              "providers": { "codex": {}, "claude": {} }
            }
            """, in: directory)

            let store = try makeStore(directory: directory)
            XCTAssertEqual(store.menuBarLineCount, .one)
        }
    }

    func testInvalidMenuBarLineCountUsesOne() throws {
        for invalidValue in ["\"three\"", "2", "true"] {
            try withTemporaryDirectory { directory in
                try writeJSON("""
                {
                  "version": 1,
                  "displayMode": "full",
                  "providerOrder": ["codex", "claude"],
                  "menuBarLineCount": \(invalidValue),
                  "providers": { "codex": {}, "claude": {} }
                }
                """, in: directory)

                let store = try makeStore(directory: directory)
                XCTAssertEqual(store.menuBarLineCount, .one)
            }
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func makeStore(directory: URL) throws -> SettingsStore {
        let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return SettingsStore(directory: directory, defaults: defaults)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStoreTests.\(UUID().uuidString)", isDirectory: true)
    }

    private func settingsURL(in directory: URL) -> URL {
        directory.appendingPathComponent("provider-settings.json", isDirectory: false)
    }

    private func writeJSON(_ json: String, in directory: URL) throws {
        try writeData(Data(json.utf8), in: directory)
    }

    private func writeData(_ data: Data, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: settingsURL(in: directory))
    }

    private func settingsData(in directory: URL) throws -> Data {
        try Data(contentsOf: settingsURL(in: directory))
    }

    private func jsonObject(in directory: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: settingsData(in: directory)) as? [String: Any])
    }

    private func canonicalJSONData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

extension SettingsStoreTests {
    func testUpdateProviderOrderRoundTripsThroughSavedFile() throws {
        try withTemporaryDirectory { directory in
            let store = try makeStore(directory: directory)

            store.updateProviderOrder(["claude", "codex"])

            XCTAssertEqual(store.providerOrder, ["claude", "codex"])
            XCTAssertEqual(
                try jsonObject(in: directory)["providerOrder"] as? [String],
                ["claude", "codex"])
            XCTAssertEqual(try makeStore(directory: directory).providerOrder, ["claude", "codex"])
        }
    }

    func testUpdateProviderOrderKeepsOnlyFirstDuplicateOccurrence() throws {
        try withTemporaryDirectory { directory in
            let store = try makeStore(directory: directory)

            store.updateProviderOrder(["claude", "claude", "codex", "claude"])

            XCTAssertEqual(store.providerOrder, ["claude", "codex"])
            XCTAssertEqual(
                try jsonObject(in: directory)["providerOrder"] as? [String],
                ["claude", "codex"])
        }
    }

    func testUpdateProviderOrderAppendsMissingKnownIDsDeterministically() throws {
        try withTemporaryDirectory { directory in
            let store = try makeStore(directory: directory)

            store.updateProviderOrder(["claude"])

            XCTAssertEqual(store.providerOrder, ["claude", "codex"])
            XCTAssertEqual(
                try jsonObject(in: directory)["providerOrder"] as? [String],
                ["claude", "codex"])
        }
    }

    func testUpdateProviderOrderExcludesOrphanIDs() throws {
        try withTemporaryDirectory { directory in
            let store = try makeStore(directory: directory)

            store.updateProviderOrder(["orphan", "claude", "codex"])

            XCTAssertEqual(store.providerOrder, ["claude", "codex"])
            XCTAssertEqual(
                try jsonObject(in: directory)["providerOrder"] as? [String],
                ["claude", "codex"])
        }
    }

    func testUpdateProviderOrderPreservesReorderedUnknownProvider() throws {
        try withTemporaryDirectory { directory in
            try writeJSON("""
            {"version":1,"displayMode":"full","providerOrder":["codex","future","claude"],
             "providers":{"codex":{},"claude":{},"future":{"show":"auto"}}}
            """, in: directory)
            let store = try makeStore(directory: directory)

            store.updateProviderOrder(["future", "claude", "codex"])

            XCTAssertEqual(store.providerOrder, ["future", "claude", "codex"])
            XCTAssertEqual(
                try jsonObject(in: directory)["providerOrder"] as? [String],
                ["future", "claude", "codex"])
            XCTAssertEqual(
                try makeStore(directory: directory).providerOrder,
                ["future", "claude", "codex"])
        }
    }

    func testUpdateProviderOrderInReadOnlyModeUpdatesMemoryWithoutWriting() throws {
        try withTemporaryDirectory { directory in
            let original = Data("""
            {"version":27,"displayMode":"full","providerOrder":["codex","claude"],
             "providers":{"codex":{},"claude":{}}}
            """.utf8)
            try writeData(original, in: directory)
            let store = try makeStore(directory: directory)

            store.updateProviderOrder(["claude"])

            XCTAssertEqual(store.providerOrder, ["claude", "codex"])
            XCTAssertEqual(try settingsData(in: directory), original)
        }
    }
}

extension SettingsStoreTests {
    func testWindowKindOrderIsPerProviderAndRoundTrips() throws {
        try withTemporaryDirectory { directory in
            let store = try makeStore(directory: directory)
            XCTAssertEqual(
                store.providers["codex"]?.windowKindOrder, WindowKindCategory.defaultOrder)

            store.updateWindowKindOrder(
                provider: "codex", visibleReordered: [.model, .session, .weekly])

            let reloaded = try makeStore(directory: directory)
            XCTAssertEqual(reloaded.providers["codex"]?.windowKindOrder, [.model, .session, .weekly])
            XCTAssertEqual(
                reloaded.providers["claude"]?.windowKindOrder, WindowKindCategory.defaultOrder)
            let saved = try jsonObject(in: directory)
            let providers = saved["providers"] as? [String: Any]
            let codex = providers?["codex"] as? [String: Any]
            XCTAssertEqual(codex?["windowKindOrder"] as? [String], ["model", "session", "weekly"])
        }
    }

    func testUpdateWindowKindOrderReflectsVisibleSubsetKeepingHidden() throws {
        try withTemporaryDirectory { directory in
            let store = try makeStore(directory: directory)
            // 既定 [session, weekly, model] のうち weekly/model のみ表示中とみなす
            store.updateWindowKindOrder(provider: "codex", visibleReordered: [.model, .weekly])

            XCTAssertEqual(store.providers["codex"]?.windowKindOrder, [.session, .model, .weekly])
        }
    }

    func testUpdateWindowKindOrderIgnoresUnknownProvider() throws {
        try withTemporaryDirectory { directory in
            let store = try makeStore(directory: directory)
            store.updateWindowKindOrder(provider: "future", visibleReordered: [.model])

            XCTAssertNil(store.providers["future"])
        }
    }

    func testMissingWindowKindOrderInProviderUsesDefaultOrder() throws {
        try withTemporaryDirectory { directory in
            try writeJSON("""
            {
              "version": 1,
              "displayMode": "full",
              "providerOrder": ["codex", "claude"],
              "providers": { "codex": { "show": false }, "claude": {} }
            }
            """, in: directory)

            let store = try makeStore(directory: directory)
            XCTAssertEqual(
                store.providers["codex"]?.windowKindOrder, WindowKindCategory.defaultOrder)
            XCTAssertEqual(store.providers["codex"]?.show, false)
        }
    }

    func testWindowKindOrderTypeMismatchUsesDefaultOrder() throws {
        for invalidValue in ["\"model\"", "[1, 2]"] {
            try withTemporaryDirectory { directory in
                try writeJSON("""
                {
                  "version": 1,
                  "displayMode": "full",
                  "providerOrder": ["codex", "claude"],
                  "providers": {
                    "codex": { "windowKindOrder": \(invalidValue) },
                    "claude": {}
                  }
                }
                """, in: directory)

                let store = try makeStore(directory: directory)
                XCTAssertEqual(
                    store.providers["codex"]?.windowKindOrder, WindowKindCategory.defaultOrder)
            }
        }
    }

    func testLoadDoesNotWriteBackNormalizedWindowKindOrder() throws {
        try withTemporaryDirectory { directory in
            try writeJSON("""
            {
              "version": 1,
              "displayMode": "full",
              "providerOrder": ["codex", "claude"],
              "providers": {
                "codex": { "windowKindOrder": ["future", "model"] },
                "claude": {}
              }
            }
            """, in: directory)

            _ = try makeStore(directory: directory)

            let saved = try jsonObject(in: directory)
            let providers = saved["providers"] as? [String: Any]
            let codex = providers?["codex"] as? [String: Any]
            XCTAssertEqual(codex?["windowKindOrder"] as? [String], ["future", "model"])
        }
    }
}
