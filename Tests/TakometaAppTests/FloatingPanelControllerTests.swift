import SwiftUI
import XCTest
@testable import TakometaApp
import TakometaCore

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
            makeContent: { AnyView(Text("panel")) })
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
}
