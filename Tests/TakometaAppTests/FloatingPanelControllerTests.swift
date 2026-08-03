import SwiftUI
import XCTest
@testable import TakometaApp
import TakometaCore

private struct FloatingPanelTestProvider: UsageProvider {
    let id: ProviderID = .codex
    let normalInterval: TimeInterval = 300

    func fetch() async throws -> UsageSnapshot {
        throw UsageFetchError.transient(reason: "test")
    }

    func updates() -> AsyncStream<UsageSnapshot> {
        AsyncStream { $0.finish() }
    }
}

@MainActor
final class FloatingPanelControllerTests: XCTestCase {
    private func makeStore() throws -> (SettingsStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "FloatingPanelControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (SettingsStore(directory: directory, defaults: defaults), directory)
    }

    private func makeController(store: SettingsStore) -> FloatingPanelController {
        FloatingPanelController(
            settingsStore: store,
            makeContent: { _ in AnyView(Text("panel").fixedSize()) })
    }

    func testUserCloseWritesBackFalse() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.updateShowsFloatingPanel(true)
        let controller = makeController(store: store)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertFalse(store.showsFloatingPanel)
    }

    func testCloseDuringTerminationDoesNotWriteBack() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.updateShowsFloatingPanel(true)
        let controller = makeController(store: store)

        // アプリ終了に伴う close はユーザーの意思表示ではないので、
        // 「開いたまま終了 → 再起動で復元」を壊してはならない（Issue #11 欠陥B）
        NotificationCenter.default.post(
            name: NSApplication.willTerminateNotification, object: nil)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertTrue(store.showsFloatingPanel)
    }

    func testHideDoesNotWriteBack() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.updateShowsFloatingPanel(true)
        let controller = makeController(store: store)

        // 設定変更に追従して隠しただけのときは windowWillClose を経由しない。
        // 書き戻すと「隠す → false になる → onChange で再度 hide」の循環に見えるうえ、
        // 表示に戻したときの状態が壊れる
        controller.show()
        controller.hide()

        XCTAssertTrue(store.showsFloatingPanel)
    }

    func testShownPanelIsConfiguredForAllSpacesAndStaysWithoutActivation() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(store: store)

        controller.show()
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? NSPanel }.first {
            $0.title == "Takometa"
        })
        defer { panel.orderOut(nil) }

        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(panel.hidesOnDeactivate)
    }

    func testRefreshContentSizeRestoresHostingMeasuredSize() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(store: store)

        controller.show()
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? NSPanel }.first {
            $0.title == "Takometa"
        })
        defer { panel.orderOut(nil) }
        let hosting = try XCTUnwrap(
            panel.contentViewController as? NSHostingController<AnyView>)
        let expected = hosting.sizeThatFits(in: CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude))
        panel.setContentSize(NSSize(width: 1, height: 1))

        controller.refreshContentSize()

        XCTAssertEqual(panel.contentLayoutRect.width, expected.width, accuracy: 0.01)
        XCTAssertEqual(panel.contentLayoutRect.height, expected.height, accuracy: 0.01)
    }

    func testUsageStateChangeRefreshesProviderCardsHeight() async throws {
        let (settingsStore, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(directory: directory.appendingPathComponent("cache"))
        try cache.save(UsageSnapshot(
            provider: .codex,
            windows: [
                RateLimitWindow(
                    id: "session", label: "session", scope: .session,
                    usedPercent: 20, resetsAt: nil, kind: .session),
                RateLimitWindow(
                    id: "weekly", label: "weekly", scope: .weeklyAll,
                    usedPercent: 40, resetsAt: nil, kind: .weekly),
            ],
            fetchedAt: Date(),
            source: .codexAppServer))
        let usageStore = UsageStore(
            providers: [FloatingPanelTestProvider()],
            cache: cache,
            scheduler: TimerScheduler())
        let controller = FloatingPanelController(
            settingsStore: settingsStore,
            observeContentChanges: {
                observeProviderCardsPanelChanges(
                    store: usageStore, settingsStore: settingsStore)
            }
        ) { _ in
            providerCardsPanelContent(
                store: usageStore, settingsStore: settingsStore)
        }

        controller.show()
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? NSPanel }.first {
            $0.title == "Takometa"
        })
        defer { panel.orderOut(nil) }
        let initialHeight = panel.contentLayoutRect.height
        XCTAssertGreaterThan(initialHeight, 0)

        usageStore.start()
        try await waitUntil { panel.contentLayoutRect.height > initialHeight }

        XCTAssertGreaterThan(panel.contentLayoutRect.height, initialHeight)
    }

    func testProviderVisibilityChangeRefreshesProviderCardsWidth() async throws {
        let (settingsStore, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let usageStore = UsageStore(
            providers: [FloatingPanelTestProvider()],
            cache: SnapshotCache(directory: directory.appendingPathComponent("cache")),
            scheduler: TimerScheduler())
        let controller = FloatingPanelController(
            settingsStore: settingsStore,
            observeContentChanges: {
                observeProviderCardsPanelChanges(
                    store: usageStore, settingsStore: settingsStore)
            }
        ) { _ in
            providerCardsPanelContent(
                store: usageStore, settingsStore: settingsStore)
        }

        controller.show()
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? NSPanel }.first {
            $0.title == "Takometa"
        })
        defer { panel.orderOut(nil) }
        let initialWidth = panel.contentLayoutRect.width

        settingsStore.update(provider: ProviderID.codex.rawValue) { $0.show = false }
        try await waitUntil { panel.contentLayoutRect.width < initialWidth }

        XCTAssertLessThan(panel.contentLayoutRect.width, initialWidth)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
