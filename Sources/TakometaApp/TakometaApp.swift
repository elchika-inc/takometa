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
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                store: store,
                settingsStore: settingsStore,
                notificationDispatcher: notificationDispatcher)
        }
    }
}
