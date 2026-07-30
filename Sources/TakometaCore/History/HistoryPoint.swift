import CryptoKit
import Foundation

/// 使用量履歴の1点。**`windowKey` を持たない**——キーは辞書側に外出しする。
/// 点に持たせると 105 B/点になり、上限時にサイズ閾値を超える（実測）。
public struct HistoryPoint: Sendable, Equatable, Codable {
    public let at: Date
    public let resetsAt: Date?
    public let usedPercent: Double

    public init(at: Date, resetsAt: Date?, usedPercent: Double) {
        self.at = at
        self.resetsAt = resetsAt
        self.usedPercent = usedPercent
    }
}

/// 履歴の窓キー。
///
/// **既存の `NotificationWindowKey.stateKey` を流用しない**（N-1）。あちらは
/// `.model` を `id ?? displayName`、`.other` を `raw` でそのまま展開しており、
/// 生の非公開識別子を含む。
///
/// **序数（配列順）も使わない。** 窓が1つ増えると以降の序数が全てずれるため、
/// 48時間にわたる時系列の追跡キーにならない。ずれた系列が同じキーに混ざると、
/// `WindowIdentity.sameWindow` は 0.0004 秒差の週次窓を同一と判定して素通しし、
/// 異常な傾きが出る。
enum HistoryWindowKey {
    static func make(
        provider: ProviderID, scope: RateLimitScope, kind: WindowKind?
    ) -> String {
        let base = "\(provider.rawValue)|\(kindName(kind))|\(scopeName(scope))"
        guard let secret = associatedValue(scope) else { return base }
        return "\(base)|\(shortHash(secret))"
    }

    private static func kindName(_ kind: WindowKind?) -> String {
        switch kind {
        case nil: return "none"
        case .session: return "session"
        case .weekly: return "weekly"
        case .other(let minutes): return "other\(minutes)"
        }
    }

    private static func scopeName(_ scope: RateLimitScope) -> String {
        switch scope {
        case .session: return "session"
        case .weeklyAll: return "weeklyAll"
        case .model: return "model"
        case .other: return "other"
        }
    }

    /// ハッシュ化する連想値。`.session` / `.weeklyAll` は持たない
    private static func associatedValue(_ scope: RateLimitScope) -> String? {
        switch scope {
        case .session, .weeklyAll: return nil
        case .model(let id, let displayName): return id ?? displayName
        case .other(let raw): return raw
        }
    }

    /// **これは秘匿ではない。** 候補リストがあれば総当たりで逆引きできる。
    /// 目的は「検出語の grep 検査を通すこと」と「キーを安定させること」。
    private static func shortHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
            .prefix(8)
            .description
    }
}
