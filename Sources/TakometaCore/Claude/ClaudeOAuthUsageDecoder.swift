import Foundation

public struct ClaudeUsageDecodeResult: Sendable {
    public let windows: [RateLimitWindow]
    public let crosscheck: [String: Double]
    public let unknownKeys: [String]
}

/// /api/oauth/usage のデコーダー（設計書 §5）。limits[] を正とし、
/// 従来形 seven_day_opus / seven_day_sonnet は limits が無い場合のみ取り込む。
/// 未知フィールドはキー名のみ記録する（値は見ない・出さない）。
public enum ClaudeOAuthUsageDecoder {
    static let knownTopLevelKeys: Set<String> = [
        "five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet",
        "limits", "extra_usage", "spend", "member_dashboard_available",
        "seven_day_oauth_apps", "seven_day_cowork",
    ]

    static func parseDate(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        let fallback = ISO8601DateFormatter()
        return fallback.date(from: s)
    }

    public static func decode(_ data: Data, now: Date) throws -> ClaudeUsageDecodeResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.notAnObject
        }
        let unknownKeys = root.keys.filter { !knownTopLevelKeys.contains($0) }.sorted()

        var windows: [RateLimitWindow] = []
        var crosscheck: [String: Double] = [:]

        for key in ["five_hour", "seven_day"] {
            if let dict = root[key] as? [String: Any],
               let utilization = dict["utilization"] as? Double {
                crosscheck[key] = utilization
            }
        }

        if let limits = root["limits"] as? [[String: Any]] {
            for (index, entry) in limits.enumerated() {
                guard let kind = entry["kind"] as? String,
                      let percent = entry["percent"] as? NSNumber else { continue }
                let scope = scopeFor(kind: kind, entry: entry)
                let label = labelFor(scope: scope, kind: kind)
                let windowKind = windowKindFor(kind: kind)
                windows.append(RateLimitWindow(
                    id: "claude.\(kind).\(index)",
                    label: label,
                    scope: scope,
                    usedPercent: percent.doubleValue,
                    resetsAt: parseDate(entry["resets_at"]),
                    severity: entry["severity"] as? String,
                    isActive: entry["is_active"] as? Bool,
                    kind: windowKind))
            }
        } else {
            // 従来形フォールバック
            let legacy: [(String, RateLimitScope, WindowKind)] = [
                ("five_hour", .session, .session),
                ("seven_day", .weeklyAll, .weekly),
                ("seven_day_opus", .model(id: nil, displayName: "Opus"), .weekly),
                ("seven_day_sonnet", .model(id: nil, displayName: "Sonnet"), .weekly),
            ]
            for (key, scope, kind) in legacy {
                guard let dict = root[key] as? [String: Any],
                      let utilization = dict["utilization"] as? Double else { continue }
                windows.append(RateLimitWindow(
                    id: "claude.legacy.\(key)",
                    label: labelFor(scope: scope, kind: key),
                    scope: scope,
                    usedPercent: utilization,
                    resetsAt: parseDate(dict["resets_at"]),
                    kind: kind))
            }
        }

        return ClaudeUsageDecodeResult(
            windows: windows, crosscheck: crosscheck, unknownKeys: unknownKeys)
    }

    static func scopeFor(kind: String, entry: [String: Any]) -> RateLimitScope {
        switch kind {
        case "session": return .session
        case "weekly_all": return .weeklyAll
        case "weekly_scoped":
            let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
            let displayName = model?["display_name"] as? String ?? "Unknown model"
            return .model(id: model?["id"] as? String, displayName: displayName)
        default:
            return .other(kind)
        }
    }

    static func windowKindFor(kind: String) -> WindowKind? {
        switch kind {
        case "session": return .session
        case "weekly_all", "weekly_scoped": return .weekly
        default: return nil
        }
    }

    static func labelFor(scope: RateLimitScope, kind: String) -> String {
        switch scope {
        case .session: return "5 hours"
        case .weeklyAll: return "Weekly (all models)"
        case .model(_, let displayName): return "\(displayName) weekly"
        case .other(let raw): return raw
        }
    }

    public enum DecodeError: Error {
        case notAnObject
    }
}
