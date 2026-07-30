import Foundation

/// CLI が出力する使用量レポート。
///
/// **`UsageSnapshot` を丸ごとエンコードしない**（N-2 / N-2b）。出力するフィールドを
/// ここで明示的に列挙し、非公開識別子（`RateLimitWindow.id` / `label` /
/// `.model(displayName:)` / `.other(raw)`）が構造的に出られないようにする。
public struct UsageReport: Sendable, Equatable, Encodable {
    /// フィールドの削除・意味変更で上げる。追加では上げない
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let providers: [ProviderReport]

    public init(schemaVersion: Int, generatedAt: Date, providers: [ProviderReport]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.providers = providers
    }

    /// 使用量の窓を1件でも出力できたか。CLI の終了コード判定に使う（N-6）。
    ///
    /// **キャッシュを読めただけでは true にしない。** 妥当な窓が1件も無い出力を
    /// exit 0 で返すと、呼び出し側（エージェント）が「残量を読めた」と誤認する。
    public var hasUsableWindow: Bool {
        providers.contains { $0.windows?.isEmpty == false }
    }
}

/// プロバイダー1件分。未取得でも配列から落とさない（N-3b）
public struct ProviderReport: Sendable, Equatable, Encodable {
    public let id: ProviderID
    public let available: Bool
    public let fetchedAt: Date?
    public let ageSeconds: Int?
    public let source: UsageSource?
    public let reason: UnavailableReason?
    public let windows: [WindowReport]?

    public init(
        id: ProviderID, available: Bool,
        fetchedAt: Date? = nil, ageSeconds: Int? = nil, source: UsageSource? = nil,
        reason: UnavailableReason? = nil, windows: [WindowReport]? = nil
    ) {
        self.id = id
        self.available = available
        self.fetchedAt = fetchedAt
        self.ageSeconds = ageSeconds
        self.source = source
        self.reason = reason
        self.windows = windows
    }
}

/// 取得できなかった理由。**固定文字列に限る**——例外メッセージやパスを載せない（N-2）
public enum UnavailableReason: String, Sendable, Equatable, Encodable {
    case absent
    case unreadable
}

/// キャッシュからレポートを組み立てる。
///
/// `now` を引数で受け取り、テストで時刻を固定できるようにする。
public enum UsageReportBuilder {
    /// 出力対象のプロバイダー。**ここに列挙したものは必ず出力に現れる**（N-3b）
    static let knownProviders: [ProviderID] = [.codex, .claude]

    /// - Returns: レポートと、標準エラーへ出す警告（読み取り失敗または空の使用量）
    public static func build(
        cache: SnapshotCache, now: Date
    ) -> (report: UsageReport, warnings: [String]) {
        var providers: [ProviderReport] = []
        var warnings: [String] = []

        for id in knownProviders {
            switch cache.read(provider: id) {
            case .loaded(let snapshot):
                if snapshot.windows.isEmpty {
                    warnings.append("警告: \(id.rawValue) のキャッシュに使用量の枠がありません")
                }
                providers.append(ProviderReport(
                    id: id,
                    available: true,
                    fetchedAt: snapshot.fetchedAt,
                    ageSeconds: elapsedSeconds(from: snapshot.fetchedAt, to: now),
                    source: snapshot.source,
                    windows: WindowReport.list(from: snapshot.windows, now: now)))
            case .absent:
                // 不在は異常ではない（まだ取得していないだけ）ので警告しない
                providers.append(ProviderReport(id: id, available: false, reason: .absent))
            case .unreadable:
                // 握りつぶして0件化しない。ただし警告にパス・例外を載せない（N-2 / N-10）
                warnings.append("警告: \(id.rawValue) のキャッシュを読めませんでした（unreadable）")
                providers.append(ProviderReport(id: id, available: false, reason: .unreadable))
            }
        }

        return (
            UsageReport(
                schemaVersion: UsageReport.currentSchemaVersion,
                generatedAt: now,
                providers: providers),
            warnings)
    }

    /// 経過秒数。負にしない（N-7・システム時刻の巻き戻り）。
    /// 壊れたキャッシュの極端な `fetchedAt` で `Int(_:)` がクラッシュしないよう上限も抑える。
    static func elapsedSeconds(from fetchedAt: Date, to now: Date) -> Int {
        let elapsed = now.timeIntervalSince(fetchedAt)
        guard elapsed > 0 else { return 0 }
        guard elapsed < Double(Int.max) else { return Int.max }
        return Int(elapsed)
    }
}

/// JSON へのエンコード。
public enum UsageReportJSON {
    public static func encode(_ report: UsageReport) throws -> Data {
        let encoder = JSONEncoder()
        // sortedKeys でキー順を決定的にし、prettyPrinted で人もエージェントも読める形にする
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }
}

/// 出力用の scope 名。`RateLimitScope` と 1:1 だが**連想値を持たない**（N-2b）
public enum ScopeName: String, Sendable, Equatable, Encodable {
    case session
    case weeklyAll
    case model
    case other

    init(_ scope: RateLimitScope) {
        switch scope {
        case .session: self = .session
        case .weeklyAll: self = .weeklyAll
        case .model: self = .model
        case .other: self = .other
        }
    }

    /// 連番を振る対象か。同一 scope 内で独立に数える
    var isIndexed: Bool {
        self == .model || self == .other
    }
}

/// 出力用の継続時間種別。`WindowKind` と 1:1（分数は windowMinutes へ分離）
public enum WindowName: String, Sendable, Equatable, Encodable {
    case session
    case weekly
    case other
}

/// 窓1件分。**生の識別子を持たない**（N-2b）——`scope` と `index` で表す。
///
/// `scope`（誰の枠か）と `window`（どれだけの期間か）は別物。
/// 「週次のモデル固有枠」は `scope: .model` かつ `window: .weekly` になる。
public struct WindowReport: Sendable, Equatable, Encodable {
    public let scope: ScopeName
    /// `scope` が `model` / `other` のときのみ。同一 provider・同一 scope 内の 1 始まり連番
    public let index: Int?
    /// `kind` が nil のときは nil（キーごと省略される）。`.other` へ潰さない
    public let window: WindowName?
    public let windowMinutes: Int64?
    /// 丸めない。99.6 を 100 へ丸めると偽情報になる
    public let usedPercent: Double
    public let resetsAt: Date?
    /// `resetsAt` があれば常に出す（false を省略しない）
    public let expired: Bool?
    public let isActive: Bool?

    public init(
        scope: ScopeName, index: Int?, window: WindowName?, windowMinutes: Int64?,
        usedPercent: Double, resetsAt: Date?, expired: Bool?, isActive: Bool?
    ) {
        self.scope = scope
        self.index = index
        self.window = window
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.expired = expired
        self.isActive = isActive
    }

    /// `UsageSnapshot.windows` の配列順をそのまま保つ。
    /// index は入力配列順で採番する仕様のため、並べ替えない。
    static func list(from windows: [RateLimitWindow], now: Date) -> [WindowReport] {
        var counters: [ScopeName: Int] = [:]
        return windows.map { window in
            let scope = ScopeName(window.scope)
            var index: Int?
            if scope.isIndexed {
                let next = (counters[scope] ?? 0) + 1
                counters[scope] = next
                index = next
            }
            let (name, minutes) = windowName(from: window.kind)
            return WindowReport(
                scope: scope,
                index: index,
                window: name,
                windowMinutes: minutes,
                usedPercent: window.usedPercent,
                resetsAt: window.resetsAt,
                expired: window.resetsAt.map { $0 < now },
                isActive: window.isActive)
        }
    }

    private static func windowName(from kind: WindowKind?) -> (WindowName?, Int64?) {
        switch kind {
        case nil: return (nil, nil)
        case .session: return (.session, nil)
        case .weekly: return (.weekly, nil)
        case .other(let minutes): return (.other, minutes)
        }
    }
}
