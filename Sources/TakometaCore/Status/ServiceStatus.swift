import Foundation

/// プロバイダーのサービス状態。
///
/// **「判定できない」を `.normal` へ倒さない**（N-3）。この機能の目的は
/// 「上限に達したのか障害なのか」の切り分けであり、誤った安心を与えると目的に反する。
public enum ServiceStatus: Sendable, Equatable {
    /// 対象コンポーネントが operational
    case normal
    /// 対象コンポーネントに問題がある。raw は元の status 文字列
    case degraded(raw: String)
    /// 判定できない（通信失敗・デコード失敗・対象不在・空配列）
    case unknown
}

/// 障害状況の取得器。
///
/// `throws` にしない——失敗は `.unknown` を返すことで表現し、
/// 例外を使用量取得の経路へ伝播させない（N-6）。
public protocol ServiceStatusProviding: Sendable {
    func fetch(for provider: ProviderID) async -> ServiceStatus
}
