import ServiceManagement
import SwiftUI
import TakometaCore

enum SettingsTab: Hashable {
    case general
    case provider(String)
}

struct SettingsView: View {
    let store: UsageStore
    let settingsStore: SettingsStore
    let notificationDispatcher: NotificationDispatcher
    var observedWindowsOverride: [ProviderID: [RateLimitWindow]] = [:]

    @State private var selectedTab: SettingsTab
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var alertMessage: String?
    @State private var notificationSettingsGuidance: Set<ProviderID> = []

    init(
        store: UsageStore,
        settingsStore: SettingsStore,
        notificationDispatcher: NotificationDispatcher,
        initialTab: SettingsTab = .general,
        observedWindowsOverride: [ProviderID: [RateLimitWindow]] = [:]
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.notificationDispatcher = notificationDispatcher
        self.observedWindowsOverride = observedWindowsOverride
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let settingsError = settingsStore.lastErrorDescription {
                Label(settingsError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top)
            }

            TabView(selection: $selectedTab) {
                generalTab
                    .tabItem { Label("全般", systemImage: "gearshape") }
                    .tag(SettingsTab.general)

                ForEach(orderedProviders, id: \.rawValue) { provider in
                    providerTab(provider: provider)
                        .tabItem {
                            Label(providerDisplayName(provider), systemImage: providerIcon(provider))
                        }
                        .tag(SettingsTab.provider(provider.rawValue))
                }
            }
        }
        .padding()
        .frame(width: 520, height: 640)
        .onAppear {
            loginItemStatus = SMAppService.mainApp.status
            Task { await notificationDispatcher.refreshAuthorizationStatus() }
        }
        .alert("設定を変更できません", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "不明なエラー")
            }
    }

    private var orderedProviders: [ProviderID] {
        settingsStore.providerOrder.compactMap(ProviderID.init(rawValue:))
    }

    private var generalTab: some View {
        Form {
            Section("表示") {
                Picker("メニューバー表示", selection: displayModeBinding) {
                    Text("Full").tag(DisplayMode.full)
                    Text("Balanced").tag(DisplayMode.balanced)
                    Text("Compact").tag(DisplayMode.compact)
                }
                .pickerStyle(.segmented)

                Picker("メニューバーの行数", selection: menuBarLineCountBinding) {
                    Text("1行").tag(MenuBarLineCount.one)
                    Text("2行").tag(MenuBarLineCount.two)
                }
                .disabled(settingsStore.displayMode == .compact)

                if settingsStore.displayMode == .compact {
                    Text("Compact はアイコンのみのため行数は適用されません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("起動") {
                Toggle("ログイン時に Takometa を開く", isOn: Binding(
                    get: { loginItemStatus == .enabled },
                    set: { enabled in updateLaunchAtLogin(enabled) }))
            }

            Section("Claude Keychain") {
                Text("Takometa は使用量取得のため、Claude Code の資格情報を Keychain から読み取り専用で利用します。資格情報の更新・削除・ログアウトは行いません。")
                    .foregroundStyle(.secondary)
            }

            Section("表示順") {
                List {
                    ForEach(settingsStore.providerOrder, id: \.self) { providerID in
                        Text(providerDisplayName(providerID))
                    }
                    .onMove { source, destination in
                        var order = settingsStore.providerOrder
                        order.move(fromOffsets: source, toOffset: destination)
                        settingsStore.updateProviderOrder(order)
                    }
                }
                .frame(height: 120)
            }
        }
        .formStyle(.grouped)
    }

    private func providerTab(provider: ProviderID) -> some View {
        let settings = providerSettings(for: provider)
        let visibleKinds = visibleWindowKinds(for: provider)

        return Form {
            Section("表示") {
                Toggle("表示する", isOn: providerBinding(for: provider, \.show))

                ForEach(WindowKindCategory.allCases.filter(visibleKinds.contains), id: \.self) {
                    kind in
                    Toggle(
                        windowKindLabel(kind),
                        isOn: windowKindBinding(for: provider, kind: kind))
                        .disabled(
                            !settings.show
                                || WindowKindRowRules.isToggleDisabled(
                                    for: kind,
                                    visibleKinds: visibleKinds,
                                    settings: settings))
                }
            }

            Section("枠種別の表示順") {
                List {
                    ForEach(orderedVisibleKinds(for: provider), id: \.self) { kind in
                        Text(windowKindOrderLabel(kind))
                    }
                    .onMove { source, destination in
                        var visible = orderedVisibleKinds(for: provider)
                        visible.move(fromOffsets: source, toOffset: destination)
                        settingsStore.updateWindowKindOrder(
                            provider: provider.rawValue, visibleReordered: visible)
                    }
                }
                .frame(height: 120)

                Text("並べ替えの内容によっては、メニューバーに H / W の目印が追加されます")
                    .foregroundStyle(.secondary)
            }

            Section("表示ラベル") {
                TextField(
                    provider == .codex ? "CX" : "CL",
                    text: labelBinding(for: provider))
                Text("空欄で既定（\(provider == .codex ? "CX" : "CL")）に戻ります")
                    .foregroundStyle(.secondary)
            }

            Section("通知") {
                Toggle(
                    "通知を有効にする",
                    isOn: notificationsEnabledBinding(for: provider))

                Stepper(
                    "使用率閾値: \(thresholdText(settings.usageThreshold))%",
                    value: providerBinding(for: provider, \.usageThreshold),
                    in: 50...95,
                    step: 5)
                    .disabled(!settings.notificationsEnabled)

                Toggle(
                    "1日の消費量を通知する",
                    isOn: providerBinding(for: provider, \.dailyEnabled))
                    .disabled(!settings.notificationsEnabled)

                Stepper(
                    "日次閾値: \(thresholdText(settings.dailyThreshold))%",
                    value: providerBinding(for: provider, \.dailyThreshold),
                    in: 5...50,
                    step: 5)
                    .disabled(!settings.notificationsEnabled || !settings.dailyEnabled)

                if shouldShowNotificationSettingsGuidance(for: provider) {
                    Text("通知を許可するには「システム設定 > 通知 > Takometa」を開いてください。")
                        .foregroundStyle(.secondary)
                }

                if let error = notificationDispatcher.lastErrorDescription {
                    Text(error)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var displayModeBinding: Binding<DisplayMode> {
        Binding(
            get: { settingsStore.displayMode },
            set: { settingsStore.updateDisplayMode($0) })
    }

    private var menuBarLineCountBinding: Binding<MenuBarLineCount> {
        Binding(
            get: { settingsStore.menuBarLineCount },
            set: { settingsStore.updateMenuBarLineCount($0) })
    }

    private func thresholdText(_ value: Double) -> String {
        String(format: "%g", value)
    }

    private func providerBinding<Value>(
        for provider: ProviderID,
        _ keyPath: WritableKeyPath<ProviderSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { providerSettings(for: provider)[keyPath: keyPath] },
            set: { value in
                settingsStore.update(provider: provider.rawValue) {
                    $0[keyPath: keyPath] = value
                }
            })
    }

    private func labelBinding(for provider: ProviderID) -> Binding<String> {
        Binding(
            get: { providerSettings(for: provider).label },
            set: { newValue in
                settingsStore.update(provider: provider.rawValue) {
                    $0.label = String(newValue.prefix(6))
                }
            })
    }

    private func windowKindBinding(
        for provider: ProviderID,
        kind: WindowKindCategory
    ) -> Binding<Bool> {
        switch kind {
        case .session:
            providerBinding(for: provider, \.showSession)
        case .weekly:
            providerBinding(for: provider, \.showWeekly)
        case .model:
            providerBinding(for: provider, \.showModel)
        }
    }

    private func providerSettings(for provider: ProviderID) -> ProviderSettings {
        settingsStore.providers[provider.rawValue] ?? ProviderSettings()
    }

    private func visibleWindowKinds(for provider: ProviderID) -> Set<WindowKindCategory> {
        let windows = observedWindowsOverride[provider]
            ?? store.states[provider]?.snapshot?.windows
            ?? []
        return WindowKindRowRules.visibleKinds(
            observed: ObservedWindowKinds.observed(in: windows))
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            alertMessage = "ログイン時起動の設定に失敗しました。"
        }
        loginItemStatus = SMAppService.mainApp.status
    }

    private func notificationsEnabledBinding(for provider: ProviderID) -> Binding<Bool> {
        Binding(
            get: { providerSettings(for: provider).notificationsEnabled },
            set: { enabled in updateNotificationsEnabled(enabled, for: provider) })
    }

    private func shouldShowNotificationSettingsGuidance(for provider: ProviderID) -> Bool {
        notificationSettingsGuidance.contains(provider)
            || (providerSettings(for: provider).notificationsEnabled
                && notificationDispatcher.authorizationStatus != nil
                && notificationDispatcher.authorizationStatus != .authorized)
    }

    private func updateNotificationsEnabled(_ enabled: Bool, for provider: ProviderID) {
        guard enabled else {
            setNotificationsEnabled(false, for: provider)
            notificationSettingsGuidance.remove(provider)
            return
        }

        Task {
            let authorized = await notificationDispatcher.requestAuthorization()
            setNotificationsEnabled(authorized, for: provider)
            if authorized {
                notificationSettingsGuidance.remove(provider)
            } else {
                notificationSettingsGuidance.insert(provider)
            }
        }
    }

    private func setNotificationsEnabled(_ enabled: Bool, for provider: ProviderID) {
        settingsStore.update(provider: provider.rawValue) {
            $0.notificationsEnabled = enabled
        }
    }

    private func providerDisplayName(_ provider: ProviderID) -> String {
        switch provider {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    private func providerDisplayName(_ providerID: String) -> String {
        guard let provider = ProviderID(rawValue: providerID) else { return providerID }
        return providerDisplayName(provider)
    }

    private func providerIcon(_ provider: ProviderID) -> String {
        switch provider {
        case .codex: "terminal"
        case .claude: "message"
        }
    }

    private func windowKindLabel(_ kind: WindowKindCategory) -> String {
        switch kind {
        case .session: "5時間枠を表示"
        case .weekly: "週間枠を表示"
        case .model: "モデル固有枠を表示"
        }
    }

    private func windowKindOrderLabel(_ kind: WindowKindCategory) -> String {
        switch kind {
        case .session: "5時間枠"
        case .weekly: "週間枠"
        case .model: "モデル固有枠"
        }
    }

    private func orderedVisibleKinds(for provider: ProviderID) -> [WindowKindCategory] {
        let visible = visibleWindowKinds(for: provider)
        return providerSettings(for: provider).windowKindOrder.filter(visible.contains)
    }
}

private struct SettingsPreview: View {
    @State private var store: UsageStore
    @State private var settingsStore: SettingsStore
    @State private var notificationDispatcher: NotificationDispatcher
    private let initialTab: SettingsTab
    private let observedWindows: [ProviderID: [RateLimitWindow]]

    init(
        initialTab: SettingsTab,
        observedWindows: [ProviderID: [RateLimitWindow]],
        unknownProviderID: String? = nil
    ) {
        let identifier = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TakometaSettingsPreview.\(identifier)",
            isDirectory: true)
        let suiteName = "TakometaSettingsPreview.\(identifier)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let scheduler = TimerScheduler()

        if let unknownProviderID {
            do {
                try SettingsPreviewFixtures.seed(
                    unknownProviderID: unknownProviderID,
                    in: directory)
            } catch {
                preconditionFailure("Preview 用設定の作成に失敗しました: \(error.localizedDescription)")
            }
        }

        _store = State(initialValue: UsageStore(
            providers: [],
            cache: SnapshotCache(directory: directory),
            scheduler: scheduler,
            stateStore: NotificationStateStore(directory: directory),
            baselineStore: DailyBaselineStore(directory: directory)))
        _settingsStore = State(initialValue: SettingsStore(
            directory: directory,
            defaults: defaults))
        _notificationDispatcher = State(initialValue: NotificationDispatcher())
        self.initialTab = initialTab
        self.observedWindows = observedWindows
    }

    var body: some View {
        SettingsView(
            store: store,
            settingsStore: settingsStore,
            notificationDispatcher: notificationDispatcher,
            initialTab: initialTab,
            observedWindowsOverride: observedWindows)
    }
}

private enum SettingsPreviewFixtures {
    static func seed(unknownProviderID: String, in directory: URL) throws {
        let object: [String: Any] = [
            "version": 1,
            "displayMode": DisplayMode.full.rawValue,
            "providerOrder": [
                ProviderID.codex.rawValue,
                unknownProviderID,
                ProviderID.claude.rawValue,
            ],
            "providers": [
                ProviderID.codex.rawValue: [String: Any](),
                ProviderID.claude.rawValue: [String: Any](),
                unknownProviderID: [String: Any](),
            ],
        ]
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(
            to: directory.appendingPathComponent("provider-settings.json"),
            options: .atomic)
    }

    static var codexWithoutSession: [RateLimitWindow] {
        [
            RateLimitWindow(
                id: "weekly", label: "Weekly", scope: .weeklyAll,
                usedPercent: 40, resetsAt: nil),
            RateLimitWindow(
                id: "model", label: "Model", scope: .model(id: "model", displayName: "Model"),
                usedPercent: 30, resetsAt: nil),
        ]
    }
}

#Preview("全般（通常）- Light") {
    SettingsPreview(initialTab: .general, observedWindows: [:])
        .preferredColorScheme(.light)
}

#Preview("全般（通常）- Dark") {
    SettingsPreview(initialTab: .general, observedWindows: [:])
        .preferredColorScheme(.dark)
}

#Preview("全般（未知プロバイダー）- Light") {
    SettingsPreview(
        initialTab: .general,
        observedWindows: [:],
        unknownProviderID: "test-provider")
        .preferredColorScheme(.light)
}

#Preview("全般（未知プロバイダー）- Dark") {
    SettingsPreview(
        initialTab: .general,
        observedWindows: [:],
        unknownProviderID: "test-provider")
        .preferredColorScheme(.dark)
}

#Preview("Codex（5時間枠未観測）- Light") {
    SettingsPreview(
        initialTab: .provider(ProviderID.codex.rawValue),
        observedWindows: [.codex: SettingsPreviewFixtures.codexWithoutSession])
        .preferredColorScheme(.light)
}

#Preview("Codex（5時間枠未観測）- Dark") {
    SettingsPreview(
        initialTab: .provider(ProviderID.codex.rawValue),
        observedWindows: [.codex: SettingsPreviewFixtures.codexWithoutSession])
        .preferredColorScheme(.dark)
}

#Preview("Claude（観測ゼロ）- Light") {
    SettingsPreview(
        initialTab: .provider(ProviderID.claude.rawValue),
        observedWindows: [.claude: []])
        .preferredColorScheme(.light)
}

#Preview("Claude（観測ゼロ）- Dark") {
    SettingsPreview(
        initialTab: .provider(ProviderID.claude.rawValue),
        observedWindows: [.claude: []])
        .preferredColorScheme(.dark)
}
