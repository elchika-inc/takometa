import AppKit
import SwiftUI
import TakometaCore

private final class TimerCancellation: UsageCancellable, @unchecked Sendable {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

struct TimerScheduler: UsageScheduler, Sendable {
    var now: Date { Date() }

    func schedule(
        after interval: TimeInterval,
        action: @Sendable @escaping () -> Void
    ) -> any UsageCancellable {
        let workItem = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
        return TimerCancellation(workItem: workItem)
    }
}

@main
struct TakometaApp: App {
    /// Window シーンの宣言側と openWindow(id:) の呼び出し側で共有する。
    /// literal を2か所に置くと、片方だけ変えたときに黙って開かなくなる。
    static let panelWindowID = "takometa-panel"

    @State private var store: UsageStore
    @State private var settingsStore: SettingsStore
    @State private var notificationDispatcher: NotificationDispatcher

    init() {
        let settingsStore = SettingsStore()
        let scheduler = TimerScheduler()
        let providers: [any UsageProvider] = [
            CodexUsageProvider(scheduler: scheduler),
            ClaudeUsageProvider(credentials: ClaudeCredentialsReader()),
        ]
        _store = State(initialValue: UsageStoreFactory.production(
            providers: providers,
            cache: SnapshotCache(),
            scheduler: scheduler,
            notificationSettings: SettingsSupply.notificationSettings(
                from: settingsStore.providers),
            statusProvider: ServiceStatusFetcher()))
        _settingsStore = State(initialValue: settingsStore)
        _notificationDispatcher = State(initialValue: NotificationDispatcher())
    }

    var body: some Scene {
        MenuBarExtra {
            ProviderPopoverView(store: store, settingsStore: settingsStore)
        } label: {
            MenuBarLabelView(store: store, settingsStore: settingsStore)
                .task { store.start() }
                .onChange(of: settingsStore.providers) { _, providers in
                    store.notificationSettings = SettingsSupply.notificationSettings(
                        from: providers)
                }
                .onChange(of: store.pendingNotifications) { _, events in
                    guard !events.isEmpty else { return }
                    notificationDispatcher.send(store.consumePendingNotifications())
                }
                .modifier(FloatingPanelPresenter(
                    windowID: Self.panelWindowID,
                    isPresented: settingsStore.showsFloatingPanel))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                store: store,
                settingsStore: settingsStore,
                notificationDispatcher: notificationDispatcher)
        }

        Window("Takometa", id: Self.panelWindowID) {
            ProviderPopoverView(store: store, settingsStore: settingsStore)
                .onDisappear {
                    settingsStore.updateShowsFloatingPanel(false)
                }
        }
        .windowLevel(.floating)
        .windowResizability(.contentSize)
    }
}

@MainActor
func presentFloatingPanel(activate: () -> Void, open: () -> Void) {
    activate()
    open()
}

/// 設定を正本として窓の開閉を追従させる。openWindow / dismissWindow は
/// View の Environment からしか取れないため、label 側へ寄せている。
private struct FloatingPanelPresenter: ViewModifier {
    let windowID: String
    let isPresented: Bool

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content
            .task {
                if isPresented { showPanel() }
            }
            .onChange(of: isPresented, initial: false) { _, shows in
                if shows {
                    showPanel()
                } else {
                    dismissWindow(id: windowID)
                }
            }
    }

    private func showPanel() {
        presentFloatingPanel(
            activate: { NSApp.activate(ignoringOtherApps: true) },
            open: { openWindow(id: windowID) })
    }
}
