import Foundation

public struct CodexUsageDecodeResult: Sendable {
    public let windows: [RateLimitWindow]
    public let unknownKeys: [String]
}

/// account/rateLimits/read の result デコーダー（設計書 §4）。
/// rateLimitsByLimitId を主体とし、無い場合は rateLimits 単体へフォールバックする。
public enum CodexRateLimitsDecoder {
    static let knownTopLevelKeys: Set<String> = [
        "rateLimits", "rateLimitsByLimitId", "rateLimitResetCredits",
    ]
    static let aggregateLimitId = "codex"

    public static func decode(_ data: Data) throws -> CodexUsageDecodeResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.notAnObject
        }
        let unknownKeys = root.keys.filter { !knownTopLevelKeys.contains($0) }.sorted()

        var windows: [RateLimitWindow] = []
        if let buckets = root["rateLimitsByLimitId"] as? [String: [String: Any]] {
            for limitId in buckets.keys.sorted() {
                windows.append(contentsOf: windowsFor(bucket: buckets[limitId]!, limitId: limitId))
            }
        } else if let single = root["rateLimits"] as? [String: Any] {
            let limitId = single["limitId"] as? String ?? aggregateLimitId
            windows.append(contentsOf: windowsFor(bucket: single, limitId: limitId))
        }
        return CodexUsageDecodeResult(windows: windows, unknownKeys: unknownKeys)
    }

    static func windowsFor(bucket: [String: Any], limitId: String) -> [RateLimitWindow] {
        let limitName = bucket["limitName"] as? String
        var out: [RateLimitWindow] = []
        for position in ["primary", "secondary"] {
            guard let window = bucket[position] as? [String: Any],
                  let usedPercent = window["usedPercent"] as? NSNumber else { continue }
            let durationMins = (window["windowDurationMins"] as? NSNumber)?.int64Value
            let kind = durationMins.map(WindowKind.init(durationMinutes:))
            let scope = scopeFor(limitId: limitId, limitName: limitName, kind: kind)
            let resetsAt = (window["resetsAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
            out.append(RateLimitWindow(
                id: "codex.\(limitId).\(position)",
                label: labelFor(scope: scope, kind: kind),
                scope: scope,
                usedPercent: usedPercent.doubleValue,
                resetsAt: resetsAt,
                kind: kind))
        }
        return out
    }

    static func scopeFor(limitId: String, limitName: String?, kind: WindowKind?) -> RateLimitScope {
        if limitId == aggregateLimitId {
            switch kind {
            case .session: return .session
            case .weekly: return .weeklyAll
            default: return .other(limitId)
            }
        }
        return .model(id: limitId, displayName: limitName ?? limitId)
    }

    static func labelFor(scope: RateLimitScope, kind: WindowKind?) -> String {
        switch scope {
        case .session: return "5 hours"
        case .weeklyAll: return "Weekly"
        case .model(_, let displayName):
            return kind == .session ? "\(displayName) 5 hours" : "\(displayName) weekly"
        case .other(let raw): return raw
        }
    }

    public enum DecodeError: Error {
        case notAnObject
    }
}
