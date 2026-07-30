import AppKit
import SwiftUI
import TakometaCore

struct ProviderPopoverView: View {
    let store: UsageStore
    let settingsStore: SettingsStore
    var codexStateOverride: UsageStore.ProviderState? = nil
    var claudeStateOverride: UsageStore.ProviderState? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(orderedProviders.enumerated()), id: \.element) { index, provider in
                if index > 0 {
                    Divider()
                }
                ProviderSectionView(
                    provider: provider,
                    store: store,
                    kindOrder: settingsStore.providers[provider.rawValue]?.windowKindOrder
                        ?? WindowKindCategory.defaultOrder,
                    stateOverride: stateOverride(for: provider))
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("バージョン \(appVersion)")
                    Text("ビルド \(buildCommit)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()
                SettingsLink {
                    Label("設定", systemImage: "gearshape")
                }
                Button("終了", systemImage: "power") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var orderedProviders: [ProviderID] {
        settingsStore.providerOrder.compactMap(ProviderID.init(rawValue:))
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "不明"
    }

    private var buildCommit: String {
        Bundle.main.infoDictionary?["TakometaBuildCommit"] as? String ?? "不明"
    }

    private func stateOverride(for provider: ProviderID) -> UsageStore.ProviderState? {
        provider == .codex ? codexStateOverride : claudeStateOverride
    }
}

private struct ProviderSectionView: View {
    let provider: ProviderID
    let store: UsageStore
    let kindOrder: [WindowKindCategory]
    var stateOverride: UsageStore.ProviderState? = nil

    private var state: UsageStore.ProviderState {
        stateOverride ?? store.states[provider] ?? UsageStore.ProviderState()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            serviceStatusRow

            Text(provider == .codex ? "Codex" : "Claude")
                .font(.headline)

            if let snapshot = state.snapshot, !snapshot.windows.isEmpty {
                let orderedWindows = WindowKindOrdering.sorted(
                    snapshot.windows,
                    order: kindOrder,
                    category: { windowKindCategory(for: $0.scope) })
                ForEach(orderedWindows) { window in
                    windowRow(window)
                    if window.id != orderedWindows.last?.id {
                        Divider()
                    }
                }
            } else {
                ContentUnavailableView(
                    "使用量を取得できません",
                    systemImage: "questionmark.circle",
                    description: Text("値を補完せず、取得できるまで -- と表示します"))
            }

            Divider()
            freshnessFooter

            HStack {
                Button("更新", systemImage: "arrow.clockwise") {
                    store.refresh(provider: provider, userInitiated: true)
                }
                Spacer()
            }
        }
    }

    /// 障害状況の行。正常時と未取得時は何も出さない（N-5）
    @ViewBuilder
    private var serviceStatusRow: some View {
        if let status = state.serviceStatus,
           let message = ServiceStatusText.message(for: status, provider: provider) {
            switch status {
            case .degraded:
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color(nsColor: .systemOrange))
            case .unknown:
                // 障害そのものではなく「切り分けができない」ことを伝えるだけなので控えめに
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .normal:
                EmptyView()
            }
        }
    }

    private func windowRow(_ window: RateLimitWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                Spacer()
                Text("\(Int(window.usedPercent.rounded(.down)))% used")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(isCritical(window) ? Color.red : Color.primary)
            }

            if let resetsAt = window.resetsAt {
                Text("リセット: \(RelativeDateText.text(for: resetsAt, now: Date()))")
                    .foregroundStyle(.secondary)
            }

            // 平均が出せないときは行ごと出さない（直近だけを出さない）。
            // 平均・直近・相対時刻の基準時刻を揃える
            let now = Date()
            if let pace = UsagePace.calculate(
                window: window,
                freshness: state.freshness,
                now: now) {
                let recent = store.recentPace(for: window, provider: provider, now: now)
                if let text = PaceText.description(
                    pace,
                    recent: recent,
                    now: now) {
                    Text(text)
                        .foregroundStyle(
                            PaceText.requiresAttention(pace, recent: recent)
                                ? Color.orange : Color.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var freshnessFooter: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let fetchedAt = state.snapshot?.fetchedAt {
                Text("最終取得: \(RelativeDateText.text(for: fetchedAt, now: Date(), includesSeconds: true))")
                    .foregroundStyle(.secondary)
            }

            switch state.freshness {
            case .fresh:
                Label("最新", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .stale:
                Label("前回取得値を表示中", systemImage: "clock")
                    .foregroundStyle(.secondary)
                errorReason
            case .unavailable:
                Label("現在利用できません", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                errorReason
            case .authenticationRequired:
                Label("再ログインが必要です", systemImage: "lock")
                    .foregroundStyle(.secondary)
                if provider == .codex {
                    Text("ターミナルで `codex login` を実行してください。")
                } else {
                    Text("Claude Code で再ログインしてください。")
                    Text("Takometa は使用量取得のため、Claude Code の資格情報を Keychain から読み取り専用で利用します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var errorReason: some View {
        if let reason = state.lastErrorDescription {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func isCritical(_ window: RateLimitWindow) -> Bool {
        guard window.usedPercent >= 100 else { return false }
        let isFrozen = state.freshness == .stale || state.freshness == .authenticationRequired
        return !isFrozen || window.resetsAt.map { $0 > Date() } != false
    }
}

private struct IntegratedProviderPreviewPanel: View {
    @State private var store: UsageStore
    @State private var settingsStore: SettingsStore

    init() {
        let scheduler = TimerScheduler()
        let previewID = UUID().uuidString
        let suiteName = "TakometaPreview.\(previewID)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Preview用UserDefaultsを作成できません")
        }
        defaults.removePersistentDomain(forName: suiteName)
        _store = State(initialValue: UsageStore(
            providers: [],
            cache: SnapshotCache(),
            scheduler: scheduler))
        _settingsStore = State(initialValue: SettingsStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "TakometaPreview.\(previewID)",
                isDirectory: true),
            defaults: defaults))
    }

    var body: some View {
        let codexState = ProviderPreviewFixtures.state(
            provider: .codex,
            freshness: .fresh)
        let claudeState = ProviderPreviewFixtures.state(
            provider: .claude,
            freshness: .authenticationRequired,
            windows: [])
        VStack(spacing: 16) {
            MenuBarLabelView(
                store: store,
                settingsStore: settingsStore,
                codexStateOverride: codexState,
                claudeStateOverride: claudeState)
                .padding(8)
                .background(.bar)
            ProviderPopoverView(
                store: store,
                settingsStore: settingsStore,
                codexStateOverride: codexState,
                claudeStateOverride: claudeState)
        }
        .padding()
    }
}

private enum ProviderPreviewFixtures {
    static func state(
        provider: ProviderID,
        freshness: Freshness,
        windows: [RateLimitWindow] = standardWindows,
        error: String? = nil
    ) -> UsageStore.ProviderState {
        let snapshot = windows.isEmpty ? nil : UsageSnapshot(
            provider: provider,
            windows: windows,
            fetchedAt: Date().addingTimeInterval(-60),
            source: provider == .codex ? .codexAppServer : .claudeOAuth)
        return UsageStore.ProviderState(
            snapshot: snapshot,
            freshness: freshness,
            lastErrorDescription: error)
    }

    static var standardWindows: [RateLimitWindow] {
        let now = Date()
        return [
            RateLimitWindow(
                id: "session", label: "5 hours", scope: .session,
                usedPercent: 34, resetsAt: now.addingTimeInterval(4 * 3600),
                kind: .session),
            RateLimitWindow(
                id: "weekly", label: "Weekly (all models)", scope: .weeklyAll,
                usedPercent: 52, resetsAt: now.addingTimeInterval(6 * 86400),
                kind: .weekly),
            RateLimitWindow(
                id: "fable", label: "Fable weekly",
                scope: .model(id: "fable", displayName: "Fable"),
                usedPercent: 78, resetsAt: now.addingTimeInterval(6 * 86400),
                kind: .weekly),
        ]
    }

}

#Preview("統合ポップオーバー - Light") {
    IntegratedProviderPreviewPanel()
        .preferredColorScheme(.light)
}

#Preview("統合ポップオーバー - Dark") {
    IntegratedProviderPreviewPanel()
        .preferredColorScheme(.dark)
}
