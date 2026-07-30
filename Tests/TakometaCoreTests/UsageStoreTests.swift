import XCTest
@testable import TakometaCore

private final class FakeCancellable: UsageCancellable, @unchecked Sendable {
    var isCancelled = false
    func cancel() { isCancelled = true }
}

private final class FakeScheduler: UsageScheduler, @unchecked Sendable {
    struct Entry {
        let deadline: Date
        let action: @Sendable () -> Void
        let token: FakeCancellable
    }

    var now: Date
    var entries: [Entry] = []
    var scheduledIntervals: [TimeInterval] = []

    init(now: Date) { self.now = now }

    func schedule(
        after interval: TimeInterval,
        action: @Sendable @escaping () -> Void
    ) -> UsageCancellable {
        let token = FakeCancellable()
        scheduledIntervals.append(interval)
        entries.append(Entry(
            deadline: now.addingTimeInterval(interval), action: action, token: token))
        return token
    }

    func advance(by interval: TimeInterval) {
        now.addTimeInterval(interval)
        while let index = entries.indices
            .filter({ entries[$0].deadline <= now && !entries[$0].token.isCancelled })
            .min(by: { entries[$0].deadline < entries[$1].deadline })
        {
            let entry = entries.remove(at: index)
            entry.action()
        }
    }
}

private final class FakeProvider: UsageProvider, @unchecked Sendable {
    let id: ProviderID
    let normalInterval: TimeInterval
    private let lock = NSLock()
    private var results: [Result<UsageSnapshot, UsageFetchError>]
    private var updateContinuation: AsyncStream<UsageSnapshot>.Continuation?
    private var count = 0
    private var suspensionResetCount = 0
    private var shouldBlockNext = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var throwsGenericError = false

    init(
        id: ProviderID,
        normalInterval: TimeInterval,
        results: [Result<UsageSnapshot, UsageFetchError>]
    ) {
        self.id = id
        self.normalInterval = normalInterval
        self.results = results
    }

    var fetchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var resetCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return suspensionResetCount
    }

    func resetKeychainSuspension() {
        lock.lock()
        suspensionResetCount += 1
        lock.unlock()
    }

    func blockNextFetch() {
        lock.lock()
        shouldBlockNext = true
        lock.unlock()
    }

    func resumeBlockedFetch() {
        lock.lock()
        let continuation = blockedContinuation
        blockedContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    struct GenericFailure: Error {}

    func makeThrowGenericError() {
        lock.lock()
        throwsGenericError = true
        lock.unlock()
    }

    func fetch() async throws -> UsageSnapshot {
        let (item, shouldBlock, generic) = takeNextResult()
        if shouldBlock {
            await withCheckedContinuation { continuation in
                lock.lock()
                blockedContinuation = continuation
                lock.unlock()
            }
        }
        if generic { throw GenericFailure() }
        return try item.get()
    }

    private func takeNextResult() -> (Result<UsageSnapshot, UsageFetchError>, Bool, Bool) {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        let shouldBlock = shouldBlockNext
        shouldBlockNext = false
        let generic = throwsGenericError
        let item: Result<UsageSnapshot, UsageFetchError> = results.isEmpty
            ? .failure(.transient(reason: "結果なし"))
            : results.removeFirst()
        return (item, shouldBlock, generic)
    }

    func updates() -> AsyncStream<UsageSnapshot> {
        AsyncStream { continuation in
            lock.lock()
            updateContinuation = continuation
            lock.unlock()
        }
    }

    func push(_ snapshot: UsageSnapshot) {
        lock.lock()
        let continuation = updateContinuation
        lock.unlock()
        continuation?.yield(snapshot)
    }
}

/// 呼び出し回数を数え、完了を任意に遅らせられる status の fake
private final class StatusFake: ServiceStatusProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var result: ServiceStatus
    private var shouldBlock = false
    private var blocked: CheckedContinuation<Void, Never>?
    /// release() が continuation 格納前に呼ばれたときの取りこぼし防止
    private var releaseRequested = false

    init(result: ServiceStatus = .normal) { self.result = result }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func setResult(_ status: ServiceStatus) {
        lock.lock()
        result = status
        lock.unlock()
    }

    func blockNext() {
        lock.lock()
        shouldBlock = true
        lock.unlock()
    }

    func release() {
        lock.lock()
        let continuation = blocked
        blocked = nil
        // fetch がまだ continuation を格納していない場合に備えて latch する。
        // release() は使用量タスク側の信号（freshness == .fresh）で呼ばれるため、
        // status タスクが withCheckedContinuation に到達している保証がない。
        // 取りこぼすと continuation が永久に resume されず fetch が返らない
        if continuation == nil { releaseRequested = true }
        lock.unlock()
        continuation?.resume()
    }

    /// async 文脈で lock を直接触らないための同期ヘルパー（NSLock.lock() は noasync）
    private func takeNext() -> (ServiceStatus, Bool) {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        let block = shouldBlock
        shouldBlock = false
        return (result, block)
    }

    func fetch(for provider: ProviderID) async -> ServiceStatus {
        let (value, block) = takeNext()
        if block {
            await withCheckedContinuation { continuation in
                lock.lock()
                if releaseRequested {
                    // release() が先に呼ばれていた。待たずに進む
                    releaseRequested = false
                    lock.unlock()
                    continuation.resume()
                    return
                }
                blocked = continuation
                lock.unlock()
            }
        }
        return value
    }
}

@MainActor
final class UsageStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        provider: ProviderID = .codex,
        windows: [RateLimitWindow]? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            windows: windows ?? [RateLimitWindow(
                id: "window", label: "Weekly", scope: .weeklyAll,
                usedPercent: 42, resetsAt: now.addingTimeInterval(3600), kind: .weekly)],
            fetchedAt: now,
            source: provider == .codex ? .codexAppServer : .claudeOAuth)
    }

    private func temporaryCache() -> (SnapshotCache, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (SnapshotCache(directory: directory), directory)
    }

    private func waitUntil(
        _ message: String,
        condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail(message)
    }

    func testEmptyWindowsNotSuccess() async {
        let provider = FakeProvider(
            id: .codex, normalInterval: 300,
            results: [.success(snapshot(windows: []))])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(providers: [provider], cache: cache, scheduler: scheduler)

        store.start()
        await waitUntil("空配列の取得完了") { provider.fetchCount == 1 && store.states[.codex]!.consecutiveFailures == 1 }

        XCTAssertEqual(store.states[.codex]?.freshness, .unavailable)
        XCTAssertNil(store.states[.codex]?.snapshot)
        XCTAssertEqual(scheduler.scheduledIntervals.last, 60)
    }

    func testAuthRequiredStickyAcrossTransientFailure() async {
        let provider = FakeProvider(
            id: .claude, normalInterval: 60,
            results: [
                .failure(.authenticationRequired(reason: "再ログインが必要")),
                .failure(.transient(reason: "一時的な通信失敗")),
            ])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(providers: [provider], cache: cache, scheduler: scheduler)

        store.start()
        await waitUntil("認証エラー") { store.states[.claude]?.freshness == .authenticationRequired }
        store.refresh(provider: .claude)
        await waitUntil("一過性エラー") { store.states[.claude]?.consecutiveFailures == 2 }

        XCTAssertEqual(store.states[.claude]?.freshness, .authenticationRequired)
    }

    func testBackoffProgressionAndRecovery() async {
        let provider = FakeProvider(
            id: .codex, normalInterval: 300,
            results: [
                .failure(.transient(reason: "1")),
                .failure(.transient(reason: "2")),
                .success(snapshot()),
            ])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(providers: [provider], cache: cache, scheduler: scheduler)

        store.start()
        await waitUntil("1回目失敗") { store.states[.codex]?.consecutiveFailures == 1 }
        XCTAssertEqual(scheduler.scheduledIntervals.last, 60)
        store.refresh(provider: .codex)
        await waitUntil("2回目失敗") { store.states[.codex]?.consecutiveFailures == 2 }
        XCTAssertEqual(scheduler.scheduledIntervals.last, 120)
        store.refresh(provider: .codex)
        await waitUntil("復帰") { store.states[.codex]?.freshness == .fresh }

        XCTAssertEqual(store.states[.codex]?.consecutiveFailures, 0)
        XCTAssertEqual(scheduler.scheduledIntervals.last, 300)
    }

    func testPushResetsFailureCountWithoutRescheduling() async {
        let provider = FakeProvider(
            id: .codex, normalInterval: 300,
            results: [.failure(.transient(reason: "切断"))])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(providers: [provider], cache: cache, scheduler: scheduler)

        store.start()
        await waitUntil("失敗") { store.states[.codex]?.consecutiveFailures == 1 }
        let scheduleCount = scheduler.scheduledIntervals.count
        provider.push(snapshot())
        await waitUntil("push反映") { store.states[.codex]?.freshness == .fresh }

        XCTAssertEqual(store.states[.codex]?.consecutiveFailures, 0)
        XCTAssertEqual(scheduler.scheduledIntervals.count, scheduleCount)
    }

    func testRedReevaluationScheduledAtResetsAt() async {
        let critical = RateLimitWindow(
            id: "critical", label: "Critical", scope: .session,
            usedPercent: 100, resetsAt: now.addingTimeInterval(120), kind: .session)
        let provider = FakeProvider(
            id: .codex, normalInterval: 300,
            results: [.success(snapshot(windows: [critical]))])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(providers: [provider], cache: cache, scheduler: scheduler)

        store.start()
        await waitUntil("成功") { store.states[.codex]?.freshness == .fresh }
        XCTAssertTrue(scheduler.scheduledIntervals.contains(120))
        scheduler.advance(by: 120)
        await waitUntil("再評価") { store.revision == 1 }
    }

    func testUnavailableVsStaleByPastSuccess() async throws {
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        try cache.save(snapshot())
        let provider = FakeProvider(
            id: .codex, normalInterval: 300,
            results: [.failure(.unrecoverable(reason: "Codex 未導入"))])
        let scheduler = FakeScheduler(now: now)
        let store = UsageStore(providers: [provider], cache: cache, scheduler: scheduler)

        store.start()
        XCTAssertEqual(store.states[.codex]?.freshness, .stale)
        await waitUntil("キャッシュ後の失敗") { store.states[.codex]?.consecutiveFailures == 1 }

        XCTAssertEqual(store.states[.codex]?.freshness, .stale)
        XCTAssertNotNil(store.states[.codex]?.snapshot)
    }

    func testManualRefreshIgnoredWhileFetching() async {
        let provider = FakeProvider(
            id: .codex, normalInterval: 300,
            results: [.success(snapshot())])
        provider.blockNextFetch()
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(providers: [provider], cache: cache, scheduler: scheduler)

        store.refresh(provider: .codex)
        await waitUntil("fetch開始") { provider.fetchCount == 1 }
        store.refresh(provider: .codex)
        await Task.yield()
        XCTAssertEqual(provider.fetchCount, 1)
        provider.resumeBlockedFetch()
        await waitUntil("fetch完了") { store.states[.codex]?.freshness == .fresh }
    }

    func testCacheSaveFailureKeepsFreshAndRecordsError() async {
        let provider = FakeProvider(
            id: .codex, normalInterval: 300,
            results: [.success(snapshot())])
        let scheduler = FakeScheduler(now: now)
        let cache = SnapshotCache(directory: URL(fileURLWithPath: "/dev/null/Takometa"))
        let store = UsageStore(providers: [provider], cache: cache, scheduler: scheduler)

        store.start()
        await waitUntil("成功") { store.states[.codex]?.freshness == .fresh }

        XCTAssertNotNil(store.states[.codex]?.lastErrorDescription)
        XCTAssertEqual(store.states[.codex]?.consecutiveFailures, 0)
    }

    func testEveryFreshSuccessEvaluatesAndPendingNotificationsAreConsumed() async {
        let first = snapshot(windows: [RateLimitWindow(
            id: "first", label: "Weekly", scope: .weeklyAll,
            usedPercent: 70, resetsAt: nil, kind: .weekly)])
        let second = snapshot(windows: [RateLimitWindow(
            id: "second", label: "Weekly", scope: .weeklyAll,
            usedPercent: 85, resetsAt: nil, kind: .weekly)])
        let third = snapshot(windows: [RateLimitWindow(
            id: "third", label: "Weekly", scope: .weeklyAll,
            usedPercent: 90, resetsAt: now.addingTimeInterval(5 * 3600), kind: .weekly)])
        let provider = FakeProvider(
            id: .codex,
            normalInterval: 300,
            results: [.success(first), .success(second), .success(third)])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(
            providers: [provider],
            cache: cache,
            scheduler: scheduler,
            notificationSettings: [.codex: NotificationSettings(enabled: true)],
            stateStore: NotificationStateStore(directory: directory),
            baselineStore: DailyBaselineStore(directory: directory))

        store.start()
        await waitUntil("初回 fresh") { provider.fetchCount == 1 && store.states[.codex]?.freshness == .fresh }
        XCTAssertTrue(store.pendingNotifications.isEmpty)

        store.refresh(provider: .codex)
        await waitUntil("閾値到達") { provider.fetchCount == 2 && store.pendingNotifications.count == 1 }
        store.refresh(provider: .codex)
        await waitUntil("窓更改") { provider.fetchCount == 3 && store.pendingNotifications.count == 2 }

        XCTAssertEqual(store.consumePendingNotifications().count, 2)
        XCTAssertTrue(store.pendingNotifications.isEmpty)
    }

    func testNonFreshResultDoesNotEvaluateNotifications() async {
        let provider = FakeProvider(
            id: .codex,
            normalInterval: 300,
            results: [.failure(.transient(reason: "一時失敗"))])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(
            providers: [provider],
            cache: cache,
            scheduler: scheduler,
            notificationSettings: [.codex: NotificationSettings(enabled: true)],
            stateStore: NotificationStateStore(directory: directory),
            baselineStore: DailyBaselineStore(directory: directory))

        store.start()
        await waitUntil("失敗反映") { store.states[.codex]?.consecutiveFailures == 1 }

        XCTAssertTrue(store.pendingNotifications.isEmpty)
        XCTAssertEqual(NotificationStateStore(directory: directory).load(), NotificationState())
    }

    func testNotificationPersistenceFailuresAreRecordedWithoutDroppingEvents() async throws {
        let provider = FakeProvider(
            id: .codex,
            normalInterval: 300,
            results: [.success(snapshot(windows: [RateLimitWindow(
                id: "weekly", label: "Weekly", scope: .weeklyAll,
                usedPercent: 85, resetsAt: nil, kind: .weekly)]))])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedDirectory = directory.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blockedDirectory)
        let store = UsageStore(
            providers: [provider],
            cache: cache,
            scheduler: scheduler,
            notificationSettings: [.codex: NotificationSettings(
                enabled: true,
                dailyEnabled: true)],
            stateStore: NotificationStateStore(directory: blockedDirectory),
            baselineStore: DailyBaselineStore(directory: blockedDirectory))

        store.start()
        await waitUntil("通知評価") { store.states[.codex]?.freshness == .fresh }

        XCTAssertFalse(store.pendingNotifications.isEmpty)
        XCTAssertTrue(store.states[.codex]?.lastErrorDescription?.contains("通知状態保存失敗") == true)
        XCTAssertTrue(store.states[.codex]?.lastErrorDescription?.contains("日次基準点保存失敗") == true)
    }

    func testOnlyUserInitiatedRefreshResetsKeychainSuspension() async {
        let provider = FakeProvider(
            id: .claude,
            normalInterval: 60,
            results: [
                .success(snapshot(provider: .claude)),
                .success(snapshot(provider: .claude)),
                .success(snapshot(provider: .claude)),
            ])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(providers: [provider], cache: cache, scheduler: scheduler)

        store.start()
        await waitUntil("自動取得") { provider.fetchCount == 1 && store.states[.claude]?.freshness == .fresh }
        XCTAssertEqual(provider.resetCount, 0)

        store.refresh(provider: .claude)
        await waitUntil("明示的な自動扱い取得") {
            provider.fetchCount == 2 && scheduler.scheduledIntervals.count == 2
        }
        XCTAssertEqual(provider.resetCount, 0)

        store.refresh(provider: .claude, userInitiated: true)
        await waitUntil("手動取得") { provider.fetchCount == 3 }
        XCTAssertEqual(provider.resetCount, 1)
    }

    func testUserInitiatedRefreshResetsEvenWhileFetchIsInFlight() async {
        let provider = FakeProvider(
            id: .claude,
            normalInterval: 60,
            results: [.success(snapshot(provider: .claude))])
        provider.blockNextFetch()
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(providers: [provider], cache: cache, scheduler: scheduler)

        store.start()
        await waitUntil("fetch保留") { provider.fetchCount == 1 }
        store.refresh(provider: .claude, userInitiated: true)

        XCTAssertEqual(provider.resetCount, 1)
        XCTAssertEqual(provider.fetchCount, 1)
        provider.resumeBlockedFetch()
        await waitUntil("fetch完了") { store.states[.claude]?.freshness == .fresh }
    }

    func testInjectedStartupSettingsApplyBeforeSettingsViewExists() async {
        let provider = FakeProvider(
            id: .codex,
            normalInterval: 300,
            results: [.success(snapshot(windows: [RateLimitWindow(
                id: "weekly", label: "Weekly", scope: .weeklyAll,
                usedPercent: 85, resetsAt: nil, kind: .weekly)]))])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = [ProviderID.codex: NotificationSettings(enabled: true)]
        let store = UsageStore(
            providers: [provider],
            cache: cache,
            scheduler: scheduler,
            notificationSettings: defaults,
            stateStore: NotificationStateStore(directory: directory),
            baselineStore: DailyBaselineStore(directory: directory))

        store.start()
        await waitUntil("起動時設定で評価") { !store.pendingNotifications.isEmpty }

        guard case .thresholdExceeded(_, _, _, _, let threshold, _) =
            store.pendingNotifications.first
        else { return XCTFail("thresholdExceeded が必要") }
        XCTAssertEqual(threshold, 80)
        XCTAssertEqual(store.notificationSettings[.codex]?.dailyThreshold, 20)
    }

    func testPerProviderSettingsEnableOnlyClaudeNotifications() async {
        let codex = FakeProvider(
            id: .codex,
            normalInterval: 300,
            results: [.success(thresholdSnapshot(provider: .codex))])
        let claude = FakeProvider(
            id: .claude,
            normalInterval: 60,
            results: [.success(thresholdSnapshot(provider: .claude))])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(
            providers: [codex, claude],
            cache: cache,
            scheduler: scheduler,
            notificationSettings: [
                .codex: NotificationSettings(enabled: false),
                .claude: NotificationSettings(enabled: true),
            ],
            stateStore: NotificationStateStore(directory: directory),
            baselineStore: DailyBaselineStore(directory: directory))

        store.start()
        await waitUntil("両プロバイダー取得完了") {
            store.states[.codex]?.freshness == .fresh
                && store.states[.claude]?.freshness == .fresh
        }

        XCTAssertEqual(thresholdEventProviders(in: store.pendingNotifications), [.claude])
        XCTAssertEqual(store.pendingNotifications.count, 1)
    }

    func testPerProviderSettingsEnableOnlyCodexNotifications() async {
        let codex = FakeProvider(
            id: .codex,
            normalInterval: 300,
            results: [.success(thresholdSnapshot(provider: .codex))])
        let claude = FakeProvider(
            id: .claude,
            normalInterval: 60,
            results: [.success(thresholdSnapshot(provider: .claude))])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(
            providers: [codex, claude],
            cache: cache,
            scheduler: scheduler,
            notificationSettings: [
                .codex: NotificationSettings(enabled: true),
                .claude: NotificationSettings(enabled: false),
            ],
            stateStore: NotificationStateStore(directory: directory),
            baselineStore: DailyBaselineStore(directory: directory))

        store.start()
        await waitUntil("両プロバイダー取得完了") {
            store.states[.codex]?.freshness == .fresh
                && store.states[.claude]?.freshness == .fresh
        }

        XCTAssertEqual(thresholdEventProviders(in: store.pendingNotifications), [.codex])
        XCTAssertEqual(store.pendingNotifications.count, 1)
    }

    func testLoaderSettingsComposeWithStorePerProviderEvaluation() async throws {
        let suiteName = "UsageStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            true,
            forKey: NotificationSettingsLoader.claudeNotificationsEnabledKey)
        defaults.set(
            70.0,
            forKey: NotificationSettingsLoader.claudeUsageThresholdKey)

        let codex = FakeProvider(
            id: .codex,
            normalInterval: 300,
            results: [.success(thresholdSnapshot(provider: .codex))])
        let claude = FakeProvider(
            id: .claude,
            normalInterval: 60,
            results: [.success(thresholdSnapshot(provider: .claude))])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let migrated = NotificationSettingsLoader.migrate(from: defaults)
        let loaded = SettingsSupply.notificationSettings(from: migrated.providers)
        let store = UsageStore(
            providers: [codex, claude],
            cache: cache,
            scheduler: scheduler,
            notificationSettings: loaded,
            stateStore: NotificationStateStore(directory: directory),
            baselineStore: DailyBaselineStore(directory: directory))

        store.start()
        await waitUntil("Loader設定で両プロバイダー取得完了") {
            store.states[.codex]?.freshness == .fresh
                && store.states[.claude]?.freshness == .fresh
        }

        XCTAssertEqual(thresholdEventProviders(in: store.pendingNotifications), [.claude])
        guard case .thresholdExceeded(_, _, _, _, let threshold, _) =
            store.pendingNotifications.first
        else { return XCTFail("thresholdExceeded が必要") }
        XCTAssertEqual(threshold, 70)
    }

    func testMissingProviderSettingsKeyDisablesEvaluation() async {
        let provider = FakeProvider(
            id: .claude,
            normalInterval: 60,
            results: [.success(thresholdSnapshot(provider: .claude))])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(
            providers: [provider],
            cache: cache,
            scheduler: scheduler,
            notificationSettings: [.codex: NotificationSettings(enabled: true)],
            stateStore: NotificationStateStore(directory: directory),
            baselineStore: DailyBaselineStore(directory: directory))

        store.start()
        await waitUntil("Claude取得完了") { store.states[.claude]?.freshness == .fresh }

        XCTAssertTrue(store.pendingNotifications.isEmpty)
    }

    func testBaselinePersistenceSkipsWhenBothProvidersDailyDisabled() async throws {
        let key = "codex|weekly|weeklyAll"
        let baseline = DailyBaseline(day: "2027-01-15", usedPercent: 10, resetsAt: nil)
        let provider = FakeProvider(
            id: .codex,
            normalInterval: 300,
            results: [.success(snapshot())])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baselineStore = DailyBaselineStore(directory: directory)
        try baselineStore.save([key: baseline])
        let store = UsageStore(
            providers: [provider],
            cache: cache,
            scheduler: scheduler,
            notificationSettings: [
                .codex: NotificationSettings(enabled: true, dailyEnabled: false),
                .claude: NotificationSettings(enabled: true, dailyEnabled: false),
            ],
            baselineStore: baselineStore)

        store.start()
        await waitUntil("daily無効で取得完了") { store.states[.codex]?.freshness == .fresh }

        XCTAssertEqual(baselineStore.load()[key], baseline)
    }

    func testBaselinePersistenceSavesWhenEitherProviderDailyEnabled() async throws {
        let key = "codex|weekly|weeklyAll"
        let baseline = DailyBaseline(day: "2027-01-15", usedPercent: 10, resetsAt: nil)
        let provider = FakeProvider(
            id: .codex,
            normalInterval: 300,
            results: [.success(snapshot())])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baselineStore = DailyBaselineStore(directory: directory)
        try baselineStore.save([key: baseline])
        let store = UsageStore(
            providers: [provider],
            cache: cache,
            scheduler: scheduler,
            notificationSettings: [
                .codex: NotificationSettings(enabled: true, dailyEnabled: false),
                .claude: NotificationSettings(enabled: true, dailyEnabled: true),
            ],
            baselineStore: baselineStore)

        store.start()
        await waitUntil("片方daily有効で取得完了") {
            store.states[.codex]?.freshness == .fresh
                && baselineStore.load()[key] == nil
        }

        XCTAssertNil(baselineStore.load()[key])
    }

    func testUnchangedBaselinesAreNotPersistedWhenBothProvidersDailyEnabled() async {
        let session = RateLimitWindow(
            id: "session",
            label: "Session",
            scope: .session,
            usedPercent: 40,
            resetsAt: nil,
            kind: .session)
        let provider = FakeProvider(
            id: .codex,
            normalInterval: 300,
            results: [.success(snapshot(windows: [session]))])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(
            providers: [provider],
            cache: cache,
            scheduler: scheduler,
            notificationSettings: [
                .codex: NotificationSettings(enabled: true, dailyEnabled: true),
                .claude: NotificationSettings(enabled: true, dailyEnabled: true),
            ],
            baselineStore: DailyBaselineStore(directory: directory))

        store.start()
        await waitUntil("weekly窓なしで取得完了") { store.states[.codex]?.freshness == .fresh }

        let file = directory.appendingPathComponent("daily-baselines.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Phase 2-N: 障害状況

    private func makeStatusStore(
        results: [Result<UsageSnapshot, UsageFetchError>],
        statusFake: StatusFake?,
        scheduler: FakeScheduler,
        normalInterval: TimeInterval = 300
    ) -> (UsageStore, FakeProvider, URL) {
        let provider = FakeProvider(
            id: .codex, normalInterval: normalInterval, results: results)
        let (cache, directory) = temporaryCache()
        let store = UsageStore(
            providers: [provider],
            cache: cache,
            scheduler: scheduler,
            statusProvider: statusFake)
        return (store, provider, directory)
    }

    /// 初回の status 発行を待ってから、**初回サイクルの完了も待つ**。
    ///
    /// `StatusFake.count` は status を発行した時点で増えるが、その時点では
    /// `runUsageFetch` が未完了で `fetching` に ID が残っている。直後に
    /// `refresh` を呼んでも `guard !fetching.contains(id)` で黙って捨てられ、
    /// 次サイクルも未スケジュールなので `advance` が何も発火しない（flaky の原因）。
    ///
    /// **これが効くのは初回サイクルだけ。** `freshness == .fresh` は初回以降
    /// ずっと真なので、2回目以降のサイクル完了の判定には使えない（遷移を検出しない）。
    /// 2回目以降を待つときは `scheduler.scheduledIntervals.count` を使う。
    private func waitForFirstStatusAndCycle(
        _ fake: StatusFake, _ store: UsageStore
    ) async {
        await waitUntil("初回の status が発行されない") { fake.count == 1 }
        await waitUntil("初回サイクルが完了しない") {
            store.states[.codex]?.freshness == .fresh
        }
    }

    func testNoStatusProviderMeansNoFetch() async {
        // 既定 nil なら HTTP を発行しない（N-9・テストの隔離）
        let scheduler = FakeScheduler(now: now)
        let (store, _, directory) = makeStatusStore(
            results: [.success(snapshot())], statusFake: nil, scheduler: scheduler)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.start()
        await waitUntil("使用量が取得されない") { store.states[.codex]?.freshness == .fresh }
        XCTAssertNil(store.states[.codex]?.serviceStatus)
    }

    func testStatusIsFetchedWhenUsageFails() async {
        let scheduler = FakeScheduler(now: now)
        let fake = StatusFake(result: .degraded(raw: "major_outage"))
        let (store, _, directory) = makeStatusStore(
            results: [.failure(.transient(reason: "失敗"))],
            statusFake: fake, scheduler: scheduler)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.start()
        await waitUntil("使用量失敗時に status が反映されない") {
            store.states[.codex]?.serviceStatus == .degraded(raw: "major_outage")
        }
    }

    func testStatusIsFetchedWhenProviderIDMismatches() async {
        // 早期離脱 1
        let scheduler = FakeScheduler(now: now)
        let fake = StatusFake()
        let (store, _, directory) = makeStatusStore(
            results: [.success(snapshot(provider: .claude))],
            statusFake: fake, scheduler: scheduler)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.start()
        await waitUntil("provider ID 不一致でも status を取得する") { fake.count == 1 }
    }

    func testStatusIsFetchedWhenWindowsAreEmpty() async {
        // 早期離脱 2
        let scheduler = FakeScheduler(now: now)
        let fake = StatusFake()
        let (store, _, directory) = makeStatusStore(
            results: [.success(snapshot(windows: []))],
            statusFake: fake, scheduler: scheduler)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.start()
        await waitUntil("windows 空でも status を取得する") { fake.count == 1 }
    }

    func testStatusIsFetchedWhenGenericErrorThrown() async {
        // 早期離脱 4（汎用 catch）
        let scheduler = FakeScheduler(now: now)
        let fake = StatusFake()
        let (store, provider, directory) = makeStatusStore(
            results: [], statusFake: fake, scheduler: scheduler)
        defer { try? FileManager.default.removeItem(at: directory) }
        provider.makeThrowGenericError()
        store.start()
        await waitUntil("汎用エラーでも status を取得する") { fake.count == 1 }
    }

    func testUsageStateIsSettledBeforeStatusCompletes() async {
        // N-14: applyStatus を前へ動かすとこのテストが落ちる
        let scheduler = FakeScheduler(now: now)
        let fake = StatusFake()
        fake.blockNext()
        let (store, _, directory) = makeStatusStore(
            results: [.success(snapshot())], statusFake: fake, scheduler: scheduler)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.start()

        await waitUntil("status の完了を待たずに使用量が確定していない（applyStatus が前に来ている）") {
            store.states[.codex]?.freshness == .fresh
        }
        XCTAssertNil(store.states[.codex]?.serviceStatus, "status はまだ入っていない")

        fake.release()
        await waitUntil("解放後に status が入らない") {
            store.states[.codex]?.serviceStatus == .normal
        }
    }

    func testStatusDoesNotRollBackSnapshotArrivedDuringAwait() async {
        // N-12: await 中に届いた snapshot を巻き戻さない
        let scheduler = FakeScheduler(now: now)
        let fake = StatusFake()
        fake.blockNext()
        let updated = UsageSnapshot(
            provider: .codex,
            windows: [RateLimitWindow(
                id: "pushed", label: "Pushed", scope: .session,
                usedPercent: 77, resetsAt: nil, kind: .session)],
            fetchedAt: now.addingTimeInterval(10),
            source: .codexAppServer)
        let (store, provider, directory) = makeStatusStore(
            results: [.success(snapshot())], statusFake: fake, scheduler: scheduler)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.start()
        await waitUntil("初回が確定しない") { store.states[.codex]?.freshness == .fresh }

        // status を待っている間に新しい snapshot が届く
        provider.push(updated)
        await waitUntil("push した snapshot が反映されない") {
            store.states[.codex]?.snapshot?.windows.first?.usedPercent == 77
        }

        fake.release()
        await waitUntil("status が入らない") { store.states[.codex]?.serviceStatus == .normal }
        XCTAssertEqual(
            store.states[.codex]?.snapshot?.windows.first?.usedPercent, 77,
            "status の書き戻しで snapshot を巻き戻してはいけない（N-12）")
    }

    func testStatusIsNotFetchedWithinMinimumInterval() async {
        let scheduler = FakeScheduler(now: now)
        let fake = StatusFake()
        // 2回目を判別できる snapshot にする（下記の待機条件で使う）
        let second = UsageSnapshot(
            provider: .codex,
            windows: [RateLimitWindow(
                id: "second", label: "Second", scope: .session,
                usedPercent: 55, resetsAt: nil, kind: .session)],
            fetchedAt: now.addingTimeInterval(1), source: .codexAppServer)
        let (store, _, directory) = makeStatusStore(
            results: [.success(snapshot()), .success(second)],
            statusFake: fake, scheduler: scheduler)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.start()
        await waitForFirstStatusAndCycle(fake, store)

        scheduler.advance(by: 239)
        store.refresh(provider: .codex, userInitiated: true)
        // **2回目のサイクルが store へ反映される**まで待ってから status の発行回数を見る。
        // provider.fetchCount は FakeProvider.fetch() の入口で増えるため、status の
        // 子タスクより先に真になりうる（ゲートを削除しても PASS する空振りになる）。
        // freshness も初回で既に .fresh なので待機条件にならない
        await waitUntil("2回目の使用量取得が反映されない") {
            store.states[.codex]?.snapshot?.windows.first?.usedPercent == 55
        }
        XCTAssertEqual(fake.count, 1, "239秒では発行しない")
    }

    func testStatusIsFetchedAtExactBoundary() async {
        let scheduler = FakeScheduler(now: now)
        let fake = StatusFake()
        let (store, _, directory) = makeStatusStore(
            results: [.success(snapshot()), .success(snapshot())],
            statusFake: fake, scheduler: scheduler)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.start()
        await waitForFirstStatusAndCycle(fake, store)

        scheduler.advance(by: 240)
        store.refresh(provider: .codex, userInitiated: true)
        await waitUntil("経過ちょうど240秒で取得されない（>= の境界）") { fake.count == 2 }
    }

    func testStatusIsFetchedEveryCycleAtCodexInterval() async {
        // 最小間隔 240 < Codex の normalInterval 300 なので隔回スキップしない
        let scheduler = FakeScheduler(now: now)
        let fake = StatusFake()
        let (store, _, directory) = makeStatusStore(
            results: Array(repeating: .success(snapshot()), count: 4),
            statusFake: fake, scheduler: scheduler, normalInterval: 300)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.start()
        await waitForFirstStatusAndCycle(fake, store)

        for expected in 2...3 {
            // 前サイクルの次回分がスケジュールされてから時計を進める。
            // freshness は初回以降ずっと .fresh なのでサイクル完了の判定に使えない
            await waitUntil("次サイクルがスケジュールされない") {
                scheduler.scheduledIntervals.count == expected - 1
            }
            scheduler.advance(by: 300)
            await waitUntil("300秒サイクルの \(expected) 回目で取得されない（隔回スキップ）") {
                fake.count == expected
            }
        }
    }

    func testRepeatedRefreshDoesNotBurstStatusRequests() async {
        // 打刻が完了時だとゲートが機能せず、連打がそのまま連打になる
        let scheduler = FakeScheduler(now: now)
        let fake = StatusFake()
        fake.blockNext()
        let (store, _, directory) = makeStatusStore(
            results: Array(repeating: .success(snapshot()), count: 6),
            statusFake: fake, scheduler: scheduler)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.start()
        // ここは status を blockNext で止めているためサイクルが完了しない。
        // 発行回数だけを待つ（完了を待つと止まる）
        await waitUntil("初回の status が発行されない") { fake.count == 1 }

        for _ in 0..<5 {
            store.refresh(provider: .codex, userInitiated: true)
            await Task.yield()
        }
        XCTAssertEqual(fake.count, 1, "完了前の連打で追加発行してはいけない（発行時打刻）")
        fake.release()
    }

    func testStatusFailureDoesNotAffectUsage() async {
        let scheduler = FakeScheduler(now: now)
        let fake = StatusFake(result: .unknown)
        let (store, _, directory) = makeStatusStore(
            results: [.success(snapshot())], statusFake: fake, scheduler: scheduler)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.start()
        await waitUntil("status が反映されない") {
            store.states[.codex]?.serviceStatus == .unknown
        }
        XCTAssertEqual(store.states[.codex]?.freshness, .fresh, "使用量の表示が壊れない")
        XCTAssertNil(
            store.states[.codex]?.lastErrorDescription, "使用量のエラー欄に混ぜない（N-7）")
    }

    func testProductionFactoryInjectsFileHistoryStore() async throws {
        // 注入漏れ（historyStore を渡さない＝既定のメモリ実装になる）を検出する
        let provider = FakeProvider(
            id: .codex, normalInterval: 300, results: [.success(snapshot())])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyDirectory = directory.appendingPathComponent("history", isDirectory: true)

        let store = UsageStoreFactory.production(
            providers: [provider], cache: cache, scheduler: scheduler,
            historyDirectory: historyDirectory)
        store.start()
        await waitUntil("取得が完了しない") { store.states[.codex]?.freshness == .fresh }

        let file = historyDirectory.appendingPathComponent("usage-history.json")
        await waitUntil("履歴ファイルが作られない（注入漏れ）") {
            FileManager.default.fileExists(atPath: file.path)
        }
    }

    // MARK: - Phase 3-A: 履歴

    private func makeHistoryStore(
        results: [Result<UsageSnapshot, UsageFetchError>],
        history: any UsageHistoryStoring,
        scheduler: FakeScheduler
    ) -> (UsageStore, FakeProvider, URL) {
        let provider = FakeProvider(id: .codex, normalInterval: 300, results: results)
        let (cache, directory) = temporaryCache()
        let store = UsageStore(
            providers: [provider], cache: cache, scheduler: scheduler,
            historyStore: history)
        return (store, provider, directory)
    }

    private func historyKey(_ window: RateLimitWindow) -> String {
        HistoryWindowKey.make(provider: .codex, scope: window.scope, kind: window.kind)
    }

    func testHistoryRecordsFirstPoint() async {
        let scheduler = FakeScheduler(now: now)
        let history = InMemoryUsageHistoryStore()
        let snap = snapshot()
        let (store, _, directory) = makeHistoryStore(
            results: [.success(snap)], history: history, scheduler: scheduler)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.start()
        await waitUntil("初回が記録されない") {
            history.points(for: self.historyKey(snap.windows[0])).count == 1
        }

        XCTAssertEqual(
            history.points(for: historyKey(snap.windows[0])).first?.at,
            scheduler.now,
            "記録時刻は scheduler.now を使う")
    }

    func testHistorySkipsUnchangedWithinHeartbeat() async {
        let scheduler = FakeScheduler(now: now)
        let history = InMemoryUsageHistoryStore()
        let snap = snapshot()
        let second = UsageSnapshot(
            provider: .codex, windows: snap.windows,
            fetchedAt: now.addingTimeInterval(300), source: .codexAppServer)
        let (store, _, directory) = makeHistoryStore(
            results: [.success(snap), .success(second)], history: history, scheduler: scheduler)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.start()
        await waitUntil("初回が記録されない") {
            history.points(for: self.historyKey(snap.windows[0])).count == 1
        }

        scheduler.now.addTimeInterval(300)
        store.refresh(provider: .codex, userInitiated: true)
        await waitUntil("2回目の取得が反映されない") {
            store.states[.codex]?.snapshot?.fetchedAt == second.fetchedAt
        }
        XCTAssertEqual(
            history.points(for: historyKey(snap.windows[0])).count, 1,
            "変化なし・15分未満では記録しない")
    }

    func testHistoryRecordsHeartbeatAfterFifteenMinutes() async {
        let scheduler = FakeScheduler(now: now)
        let history = InMemoryUsageHistoryStore()
        let snap = snapshot()
        let second = UsageSnapshot(
            provider: .codex, windows: snap.windows,
            fetchedAt: now.addingTimeInterval(1), source: .codexAppServer)
        let (store, _, directory) = makeHistoryStore(
            results: [.success(snap), .success(second)], history: history, scheduler: scheduler)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.start()
        await waitUntil("初回が記録されない") {
            history.points(for: self.historyKey(snap.windows[0])).count == 1
        }

        scheduler.now.addTimeInterval(15 * 60)
        store.refresh(provider: .codex, userInitiated: true)
        await waitUntil("2回目の取得が反映されない") {
            store.states[.codex]?.snapshot?.fetchedAt == second.fetchedAt
        }
        let points = history.points(for: historyKey(snap.windows[0]))
        XCTAssertEqual(points.count, 2, "変化なしでも15分で記録する")
        XCTAssertEqual(points.last?.at, scheduler.now, "記録時刻は scheduler.now を使う")
    }

    func testHistoryRecordsWhenPercentChanges() async {
        let scheduler = FakeScheduler(now: now)
        let history = InMemoryUsageHistoryStore()
        let snap = snapshot()
        let firstWindow = snap.windows[0]
        let changedWindow = RateLimitWindow(
            id: firstWindow.id,
            label: firstWindow.label,
            scope: firstWindow.scope,
            usedPercent: firstWindow.usedPercent + 1,
            resetsAt: firstWindow.resetsAt,
            kind: firstWindow.kind)
        let second = UsageSnapshot(
            provider: .codex, windows: [changedWindow],
            fetchedAt: now.addingTimeInterval(300), source: .codexAppServer)
        let (store, _, directory) = makeHistoryStore(
            results: [.success(snap), .success(second)], history: history, scheduler: scheduler)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.start()
        await waitUntil("初回が記録されない") {
            history.points(for: self.historyKey(firstWindow)).count == 1
        }

        scheduler.now.addTimeInterval(300)
        store.refresh(provider: .codex, userInitiated: true)
        await waitUntil("2回目の取得が反映されない") {
            store.states[.codex]?.snapshot?.fetchedAt == second.fetchedAt
        }
        let points = history.points(for: historyKey(firstWindow))
        XCTAssertEqual(points.count, 2, "15分未満でも使用率の変化を記録する")
        XCTAssertEqual(points.last?.usedPercent, changedWindow.usedPercent)
        XCTAssertEqual(points.last?.at, scheduler.now, "記録時刻は scheduler.now を使う")
    }

    func testHistoryFailureDoesNotAffectUsage() async throws {
        let scheduler = FakeScheduler(now: now)
        let snap = thresholdSnapshot(provider: .codex)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedDirectory = directory.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blockedDirectory)
        let history = FileUsageHistoryStore(directory: blockedDirectory)
        let provider = FakeProvider(
            id: .codex, normalInterval: 300, results: [.success(snap)])
        let store = UsageStore(
            providers: [provider], cache: cache, scheduler: scheduler,
            notificationSettings: [.codex: NotificationSettings(enabled: true)],
            stateStore: NotificationStateStore(directory: directory),
            baselineStore: DailyBaselineStore(directory: directory),
            historyStore: history)

        store.start()
        await waitUntil("取得が反映されない") {
            store.states[.codex]?.snapshot?.fetchedAt == snap.fetchedAt
        }

        XCTAssertEqual(store.states[.codex]?.freshness, .fresh)
        XCTAssertEqual(store.states[.codex]?.snapshot, snap)
        XCTAssertNil(
            store.states[.codex]?.lastErrorDescription,
            "履歴保存失敗を使用量のエラー欄へ混ぜない")
        XCTAssertEqual(
            thresholdEventProviders(in: store.pendingNotifications), [.codex],
            "履歴保存失敗でも先に生成された通知イベントを失わない")
    }

    func testDefaultHistoryStoreIsInMemory() {
        let provider = FakeProvider(
            id: .codex, normalInterval: 300, results: [.success(snapshot())])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(providers: [provider], cache: cache, scheduler: scheduler)

        let historyStore = Mirror(reflecting: store).children.first {
            $0.label == "historyStore"
        }?.value
        XCTAssertNotNil(historyStore, "private historyStore の取得失敗は検査失敗として扱う")
        XCTAssertTrue(
            historyStore is InMemoryUsageHistoryStore,
            "UsageStore の既定値は実 Application Support に触れないメモリ実装にする")
    }

    func testDefaultHistoryStoreDoesNotWriteFiles() async throws {
        let provider = FakeProvider(
            id: .codex, normalInterval: 300, results: [.success(snapshot())])
        let scheduler = FakeScheduler(now: now)
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(providers: [provider], cache: cache, scheduler: scheduler)

        store.start()
        await waitUntil("取得が反映されない") {
            store.states[.codex]?.snapshot?.fetchedAt == self.now
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, ["codex.json"], "既定の履歴ストアはファイルを増やさない")
    }

    private func thresholdSnapshot(provider: ProviderID) -> UsageSnapshot {
        snapshot(provider: provider, windows: [RateLimitWindow(
            id: "weekly",
            label: "Weekly",
            scope: .weeklyAll,
            usedPercent: 85,
            resetsAt: nil,
            kind: .weekly)])
    }

    private func thresholdEventProviders(
        in events: [NotificationEvent]
    ) -> [ProviderID] {
        events.compactMap { event in
            guard case .thresholdExceeded(let provider, _, _, _, _, _) = event else {
                return nil
            }
            return provider
        }
    }
}
