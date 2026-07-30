import Foundation
import Observation
import OSLog

@Observable
@MainActor
public final class UsageStore {
    public struct ProviderState: Sendable, Equatable {
        public var snapshot: UsageSnapshot?
        public var freshness: Freshness
        public var lastErrorDescription: String?
        public var consecutiveFailures: Int
        /// 障害状況。nil = 未取得（「取得できません」とは区別する・N-5）
        public var serviceStatus: ServiceStatus?

        public init(
            snapshot: UsageSnapshot? = nil,
            freshness: Freshness = .unavailable,
            lastErrorDescription: String? = nil,
            consecutiveFailures: Int = 0,
            serviceStatus: ServiceStatus? = nil
        ) {
            self.snapshot = snapshot
            self.freshness = freshness
            self.lastErrorDescription = lastErrorDescription
            self.consecutiveFailures = consecutiveFailures
            self.serviceStatus = serviceStatus
        }
    }

    public private(set) var states: [ProviderID: ProviderState]
    public private(set) var revision = 0
    public var notificationSettings: [ProviderID: NotificationSettings]
    public private(set) var pendingNotifications: [NotificationEvent] = []

    @ObservationIgnored private let providers: [ProviderID: any UsageProvider]
    @ObservationIgnored private let cache: SnapshotCache
    @ObservationIgnored private let scheduler: any UsageScheduler
    @ObservationIgnored private let statusProvider: (any ServiceStatusProviding)?
    @ObservationIgnored private let historyStore: any UsageHistoryStoring
    @ObservationIgnored private let historyLogger = Logger(
        subsystem: "Takometa", category: "UsageHistory")
    @ObservationIgnored private let stateStore: NotificationStateStore
    @ObservationIgnored private let baselineStore: DailyBaselineStore
    @ObservationIgnored private let notificationCalendar: Calendar
    @ObservationIgnored private var notificationState: NotificationState
    @ObservationIgnored private var dailyBaselines: [String: DailyBaseline]
    @ObservationIgnored private var fetching: Set<ProviderID> = []
    @ObservationIgnored private var scheduledFetches: [ProviderID: any UsageCancellable] = [:]
    @ObservationIgnored private var redReevaluations: [ProviderID: any UsageCancellable] = [:]
    @ObservationIgnored private var hasStarted = false
    /// 最小間隔のゲート。発行を決めた時点で打刻する（完了時ではない・N-8）
    @ObservationIgnored private var lastStatusAttempt: [ProviderID: Date] = [:]

    /// 障害状況の最小取得間隔。Codex の normalInterval（300秒）と同値にしない
    private static let statusMinimumInterval: TimeInterval = 240
    /// 記録の最小間隔（ハートビート）
    private static let historyHeartbeat: TimeInterval = 15 * 60

    public init(
        providers: [any UsageProvider],
        cache: SnapshotCache,
        scheduler: any UsageScheduler,
        notificationSettings: [ProviderID: NotificationSettings] = [:],
        stateStore: NotificationStateStore = NotificationStateStore(),
        baselineStore: DailyBaselineStore = DailyBaselineStore(),
        notificationCalendar: Calendar = .current,
        statusProvider: (any ServiceStatusProviding)? = nil,
        historyStore: any UsageHistoryStoring = InMemoryUsageHistoryStore()
    ) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.cache = cache
        self.scheduler = scheduler
        self.statusProvider = statusProvider
        self.historyStore = historyStore
        self.notificationSettings = notificationSettings
        self.stateStore = stateStore
        self.baselineStore = baselineStore
        self.notificationCalendar = notificationCalendar
        self.notificationState = stateStore.load()
        self.dailyBaselines = baselineStore.load()
        self.states = Dictionary(uniqueKeysWithValues: providers.map {
            ($0.id, ProviderState())
        })
    }

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true

        for provider in providers.values {
            if let snapshot = cache.load(provider: provider.id) {
                states[provider.id] = ProviderState(snapshot: snapshot, freshness: .stale)
                scheduleRedReevaluation(for: provider.id)
            }
            subscribeToUpdates(from: provider)
            refresh(provider: provider.id)
        }
    }

    public func refresh(provider id: ProviderID, userInitiated: Bool = false) {
        guard let provider = providers[id] else { return }
        if userInitiated {
            provider.resetKeychainSuspension()
        }
        guard !fetching.contains(id) else { return }
        fetching.insert(id)
        scheduledFetches[id]?.cancel()
        scheduledFetches[id] = nil
        Task { [weak self] in
            await self?.performFetch(provider)
        }
    }

    private func performFetch(_ provider: any UsageProvider) async {
        // status は使用量の成否に関わらず取得する（切り分けが目的なので、
        // 使用量が取れないときこそ必要）。冒頭で起動して並行に走らせる
        async let status = fetchStatusIfDue(provider.id)
        // 4つの早期離脱はこの中に閉じる。出口を1つに保つ（N-13）
        await runUsageFetch(provider)
        // runUsageFetch の後に置く。前へ動かすと使用量の表示が
        // status のタイムアウト分だけ待たされる（N-14）。
        // applyStatus は非 async なので外側に await を付けない（警告になる）
        applyStatus(await status, to: provider.id)
    }

    private func runUsageFetch(_ provider: any UsageProvider) async {
        do {
            let snapshot = try await provider.fetch()
            fetching.remove(provider.id)
            guard snapshot.provider == provider.id else {
                handleFailure(
                    .transient(reason: "Provider ID が一致しない応答"),
                    provider: provider)
                return
            }
            guard !snapshot.windows.isEmpty else {
                handleFailure(
                    .transient(reason: "妥当なウィンドウが無い応答"),
                    provider: provider)
                return
            }
            handleSuccess(snapshot, provider: provider, reschedule: true)
        } catch let error as UsageFetchError {
            fetching.remove(provider.id)
            handleFailure(error, provider: provider)
        } catch {
            fetching.remove(provider.id)
            handleFailure(
                .transient(reason: "取得失敗: \(String(describing: type(of: error)))"),
                provider: provider)
        }
    }

    /// 最小間隔を見て、必要なら status を取得する。skip 時は nil。
    /// **発行を決めた直後・await の前に打刻する**——完了時に打刻すると、
    /// 待っている間 fetching が空なので更新ボタンの連打がそのまま連打になる（N-8）
    private func fetchStatusIfDue(_ id: ProviderID) async -> ServiceStatus? {
        guard let statusProvider else { return nil }
        if let last = lastStatusAttempt[id],
           scheduler.now.timeIntervalSince(last) < Self.statusMinimumInterval {
            return nil
        }
        lastStatusAttempt[id] = scheduler.now
        return await statusProvider.fetch(for: id)
    }

    /// await 後に states を読み直して該当フィールドのみ更新する。
    /// await 前に捕捉した ProviderState を書き戻すと、その間に届いた更新を巻き戻す（N-12）
    private func applyStatus(_ status: ServiceStatus?, to id: ProviderID) {
        guard let status else { return }
        var state = states[id] ?? ProviderState()
        state.serviceStatus = status
        states[id] = state
    }

    private func subscribeToUpdates(from provider: any UsageProvider) {
        Task { [weak self] in
            for await snapshot in provider.updates() {
                guard let self else { return }
                guard snapshot.provider == provider.id, !snapshot.windows.isEmpty else { continue }
                self.handleSuccess(snapshot, provider: provider, reschedule: false)
            }
        }
    }

    private func handleSuccess(
        _ snapshot: UsageSnapshot,
        provider: any UsageProvider,
        reschedule: Bool
    ) {
        var state = states[provider.id] ?? ProviderState()
        state.snapshot = snapshot
        state.freshness = .fresh
        state.lastErrorDescription = nil
        state.consecutiveFailures = 0
        var persistenceErrors: [String] = []
        do {
            try cache.save(snapshot)
        } catch {
            persistenceErrors.append(
                "キャッシュ保存失敗: \(String(describing: type(of: error)))")
        }

        let previousNotificationState = notificationState
        let previousBaselines = dailyBaselines
        let evaluation = NotificationRuleEngine.evaluate(
            snapshot: snapshot,
            freshness: .fresh,
            state: notificationState,
            baselines: dailyBaselines,
            settings: notificationSettings[snapshot.provider] ?? NotificationSettings(),
            now: scheduler.now,
            calendar: notificationCalendar)
        notificationState = evaluation.newState
        dailyBaselines = evaluation.newBaselines
        pendingNotifications.append(contentsOf: evaluation.events)

        if notificationState != previousNotificationState {
            do {
                try stateStore.save(notificationState)
            } catch {
                persistenceErrors.append(
                    "通知状態保存失敗: \(String(describing: type(of: error)))")
            }
        }
        if notificationSettings.values.contains(where: \.dailyEnabled),
           dailyBaselines != previousBaselines {
            do {
                try baselineStore.save(dailyBaselines)
            } catch {
                persistenceErrors.append(
                    "日次基準点保存失敗: \(String(describing: type(of: error)))")
            }
        }
        state.lastErrorDescription = persistenceErrors.isEmpty
            ? nil
            : persistenceErrors.joined(separator: " / ")
        states[provider.id] = state
        recordHistory(snapshot)
        scheduleRedReevaluation(for: provider.id)
        if reschedule {
            scheduleNextFetch(for: provider, after: provider.normalInterval)
        }
    }

    /// 変化時のみ＋15分ハートビート。時刻は scheduler.now（N-11）
    private func recordHistory(_ snapshot: UsageSnapshot) {
        let now = scheduler.now
        for window in snapshot.windows {
            let key = HistoryWindowKey.make(
                provider: snapshot.provider, scope: window.scope, kind: window.kind)
            let existing = historyStore.points(for: key)
            let shouldRecord: Bool
            if let last = existing.last {
                shouldRecord = last.usedPercent != window.usedPercent
                    || now.timeIntervalSince(last.at) >= Self.historyHeartbeat
            } else {
                shouldRecord = true
            }
            guard shouldRecord else { continue }
            do {
                try historyStore.append(
                    HistoryPoint(
                        at: now, resetsAt: window.resetsAt, usedPercent: window.usedPercent),
                    key: key, now: now)
            } catch {
                // 使用量の取得・表示・通知に影響させない。lastErrorDescription にも混ぜない
                // （あれは handleFailure が上書きする単一スロットで、原因が区別できなくなる）
                historyLogger.warning("使用量履歴を保存できませんでした")
            }
        }
    }

    /// 直近ペース。view はこれを呼び、ストアに直接触らない（N-14）。
    public func recentPace(
        for window: RateLimitWindow, provider: ProviderID, now: Date
    ) -> Double? {
        let key = HistoryWindowKey.make(
            provider: provider, scope: window.scope, kind: window.kind)
        return RecentBurnRate.calculate(points: historyStore.points(for: key), now: now)
    }

    public func consumePendingNotifications() -> [NotificationEvent] {
        let events = pendingNotifications
        pendingNotifications.removeAll()
        return events
    }

    private func handleFailure(
        _ error: UsageFetchError,
        provider: any UsageProvider
    ) {
        var state = states[provider.id] ?? ProviderState()
        state.consecutiveFailures += 1
        state.lastErrorDescription = reason(for: error)
        switch error {
        case .authenticationRequired:
            state.freshness = .authenticationRequired
        case .transient, .unrecoverable:
            if state.freshness != .authenticationRequired {
                state.freshness = state.snapshot == nil ? .unavailable : .stale
            }
        }
        states[provider.id] = state
        scheduleRedReevaluation(for: provider.id)
        scheduleNextFetch(
            for: provider,
            after: BackoffSchedule.interval(
                consecutiveFailures: state.consecutiveFailures,
                normalInterval: provider.normalInterval))
    }

    private func scheduleNextFetch(
        for provider: any UsageProvider,
        after interval: TimeInterval
    ) {
        scheduledFetches[provider.id]?.cancel()
        scheduledFetches[provider.id] = scheduler.schedule(after: interval) { [weak self] in
            Task { @MainActor in
                self?.refresh(provider: provider.id)
            }
        }
    }

    private func scheduleRedReevaluation(for providerID: ProviderID) {
        redReevaluations[providerID]?.cancel()
        redReevaluations[providerID] = nil
        guard let reset = states[providerID]?.snapshot?.windows
            .filter({ $0.usedPercent >= 100 && $0.resetsAt.map { $0 > scheduler.now } == true })
            .compactMap(\.resetsAt)
            .min()
        else { return }

        let interval = reset.timeIntervalSince(scheduler.now)
        redReevaluations[providerID] = scheduler.schedule(after: interval) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.revision += 1
                self.scheduleRedReevaluation(for: providerID)
            }
        }
    }

    private func reason(for error: UsageFetchError) -> String {
        switch error {
        case .authenticationRequired(let reason),
             .unrecoverable(let reason),
             .transient(let reason):
            return reason
        }
    }
}
