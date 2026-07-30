import Foundation
import OSLog

/// Statuspage 形式のレスポンスから対象コンポーネントの状態を取り出す。
///
/// **`name` と `status` しかデコードしない**（N-11）。OpenAI（incident.io の互換実装）と
/// Anthropic（Atlassian Statuspage）はキー集合が異なり（7 vs 13）、`description` は
/// OpenAI 側に存在しない。他のフィールドを型に含めると OpenAI 側だけが必ず失敗する。
public enum ServiceStatusDecoder {
    private struct Payload: Decodable {
        struct Component: Decodable {
            let name: String
            let status: String
        }
        let components: [Component]
    }

    private static let logger = Logger(subsystem: "Takometa", category: "ServiceStatus")

    public static func decode(_ data: Data, componentName: String) -> ServiceStatus {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            logger.warning("障害情報のデコードに失敗しました")
            return .unknown
        }

        // 完全一致のみ。部分一致で拾うと別のコンポーネントを見てしまう
        let matches = payload.components.filter { $0.name == componentName }
        guard !matches.isEmpty else {
            // 最も静かに壊れる経路。名前が変わったらここに落ちる（N-3）
            logger.warning("障害情報に対象コンポーネントがありません")
            return .unknown
        }
        if matches.count > 1 {
            // OpenAI には同名が実在する（Login が2件）
            logger.warning("障害情報に同名のコンポーネントが複数あります")
        }

        // 最も悪いものを採る。first(where:) だと配列順に依存し障害を隠す（N-3）
        let worst = matches
            .map(\.status)
            .max { severity(of: $0) < severity(of: $1) }
        guard let worst else { return .unknown }

        if worst == "operational" { return .normal }
        if severity(of: worst) == unknownSeverity {
            // 未知の値を normal へ倒さない（N-4）
            logger.warning("障害情報に未知の status 値があります")
        }
        return .degraded(raw: worst)
    }

    /// 深刻度。大きいほど悪い。未知の値は operational より上・既知の異常より下に置く
    private static let unknownSeverity = 1

    private static func severity(of status: String) -> Int {
        switch status {
        case "major_outage": return 5
        case "partial_outage": return 4
        case "degraded_performance": return 3
        case "under_maintenance": return 2
        case "operational": return 0
        default: return unknownSeverity
        }
    }
}
