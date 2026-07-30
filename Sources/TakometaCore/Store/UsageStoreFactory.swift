import Foundation

/// アプリ用の依存組み立て。
///
/// **アプリ側で直接 `UsageStore(...)` を組まない。** ファイル実装の注入を
/// 書き忘れても `swift build` / `swift test` は通り、UI でも
/// 「機能が死んだ状態」と「正常な起動直後」が視覚的に同一になるため、
/// 注入をここに集約してテストで検査する（N-15）。
@MainActor
public enum UsageStoreFactory {
    public static func production(
        providers: [any UsageProvider],
        cache: SnapshotCache,
        scheduler: any UsageScheduler,
        notificationSettings: [ProviderID: NotificationSettings] = [:],
        statusProvider: (any ServiceStatusProviding)? = nil,
        /// テストから一時ディレクトリを渡すための口。既定（nil）は実アプリの保存先
        historyDirectory: URL? = nil
    ) -> UsageStore {
        UsageStore(
            providers: providers,
            cache: cache,
            scheduler: scheduler,
            notificationSettings: notificationSettings,
            statusProvider: statusProvider,
            historyStore: FileUsageHistoryStore(directory: historyDirectory))
    }
}
