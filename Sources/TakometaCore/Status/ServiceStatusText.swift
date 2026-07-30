import Foundation

/// 障害状況の表示文言。
///
/// **テンプレート合成をしない。** 「〈主語〉で障害が発生しています（〈表記〉）」の形にすると
/// under_maintenance で「障害が発生しています（メンテナンス中）」という矛盾した文になる。
/// status ごとに完成した文を持つ。
public enum ServiceStatusText {
    /// 表示する文言。`nil` なら何も表示しない（正常・未取得）
    public static func message(for status: ServiceStatus, provider: ProviderID) -> String? {
        switch status {
        case .normal:
            return nil
        case .unknown:
            // 切り分けができないことを伝えるだけなのでプロバイダーによらず同じ
            return "障害情報を取得できません"
        case .degraded(let raw):
            return degradedMessage(raw: raw, subject: subject(for: provider))
        }
    }

    /// 主語は運営元の名前。ポップオーバーの見出しと同じくハードコードする
    /// （Phase 2-G のカスタム表示ラベルはメニューバー専用で見出しには適用されていない）
    private static func subject(for provider: ProviderID) -> String {
        switch provider {
        case .codex: return "OpenAI"
        case .claude: return "Anthropic"
        }
    }

    private static func degradedMessage(raw: String, subject: String) -> String {
        switch raw {
        case "degraded_performance": return "\(subject) で機能低下が発生しています"
        case "partial_outage": return "\(subject) で一部の障害が発生しています"
        case "major_outage": return "\(subject) で障害が発生しています"
        case "under_maintenance": return "\(subject) はメンテナンス中です"
        default:
            // 未知の値。生の文字列は UI へ出さない（N-10）
            return "\(subject) で異常が報告されています"
        }
    }
}
