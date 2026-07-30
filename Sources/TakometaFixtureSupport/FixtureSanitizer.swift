import Foundation
import OSLog

/// fixture・表示用の秘密除去。手作業マスクは禁止で、必ずここを通す（設計書 §6）。
public enum FixtureSanitizer {
    private static let logger = Logger(subsystem: "Takometa", category: "FixtureSanitizer")

    private static let allowedKeys: Set<String> = [
        "amber_ladder", "amount_minor", "auto_reload", "availablecount", "balance",
        "can_purchase_credits", "can_toggle", "cap", "cinder_cove", "codex",
        "codex_bengalfox", "codex_empty", "credits", "currency", "daily",
        "decimal_places", "disabled_reason", "disclaimer", "display_name", "enabled",
        "exponent", "extra_usage", "five_hour", "future_flag", "group", "hascredits",
        "id", "iguana_necktie", "individuallimit", "is_active", "is_enabled", "kind",
        "limit", "limit_dollars", "limitid", "limitname", "limits",
        "member_dashboard_available", "model", "money", "monthly_limit", "nimbus_quill",
        "omelette_promotional", "percent", "plantype", "primary", "ratelimitreachedtype",
        "ratelimitresetcredits", "ratelimits", "ratelimitsbylimitid", "remaining_dollars",
        "resets_at", "resetsat", "scope", "secondary", "seven_day",
        "seven_day_cowork", "seven_day_oauth_apps", "seven_day_omelette",
        "seven_day_opus", "seven_day_sonnet", "severity", "spend", "surface", "tangelo",
        "unlimited", "used", "used_credits", "used_dollars", "usedpercent",
        "utilization", "weekly", "windowdurationmins",
    ]

    private static let allowedIdentityValues: Set<String> = [
        "codex", "codex_bengalfox", "codex_empty", "GPT-5.3-Codex-Spark", "Empty",
        "Fable", "SomeModel", "some-model",
    ]

    private static let fixedSchemaParents: Set<String> = [
        "auto_reload", "balance", "credits", "daily", "extra_usage", "five_hour",
        "individuallimit", "limits", "model", "money", "primary", "ratelimits",
        "scope", "secondary", "seven_day", "seven_day_cowork", "seven_day_oauth_apps",
        "seven_day_omelette", "seven_day_opus", "seven_day_sonnet", "spend", "weekly",
    ]

    public static func sanitize(
        jsonObject: Any,
        onLog: ((String) -> Void)? = nil
    ) -> Any {
        var collector = SensitiveStringCollector()
        collector.collectDynamicKeys(jsonObject, path: [])
        collector.collectIdentityValues(
            jsonObject,
            path: [],
            insideAnonymousScope: false)

        var anonymizedKeyCount = 0
        var messages: [String] = []
        let structurallySanitized = sanitizeStructure(
            jsonObject,
            path: [],
            insideAnonymousScope: false,
            replacements: collector.replacements,
            anonymizedKeyCount: &anonymizedKeyCount,
            messages: &messages)
        let output = replaceSensitiveStrings(
            structurallySanitized,
            replacements: collector.replacements)

        if anonymizedKeyCount > 0 {
            messages.append("動的キーを\(anonymizedKeyCount)件匿名化")
        }
        for message in messages {
            logger.warning("\(message, privacy: .public)")
            onLog?(message)
        }
        return output
    }

    public static func sanitizedData(from data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        let cleaned = sanitize(jsonObject: object)
        return try JSONSerialization.data(
            withJSONObject: cleaned,
            options: [.prettyPrinted, .sortedKeys])
    }

    private struct SensitiveStringCollector {
        var replacements: [String: String] = [:]
        private var nextKeyIndex = 1
        private var nextValueIndex = 1

        mutating func collectDynamicKeys(
            _ object: Any,
            path: [String]
        ) {
            switch object {
            case let dictionary as [String: Any]:
                for key in dictionary.keys.sorted() {
                    guard let value = dictionary[key] else { continue }
                    let lowered = key.lowercased()
                    let isAllowed = allowedKeys.contains(lowered)
                    let isFixed = isFixedSchemaPosition(path)
                    if !isAllowed, !isFixed {
                        addKeyReplacement(for: key)
                    }
                    if isAllowed || !isFixed {
                        collectDynamicKeys(value, path: path + [lowered])
                    }
                }
            case let array as [Any]:
                for value in array {
                    collectDynamicKeys(value, path: path)
                }
            default:
                break
            }
        }

        mutating func collectIdentityValues(
            _ object: Any,
            path: [String],
            insideAnonymousScope: Bool
        ) {
            switch object {
            case let dictionary as [String: Any]:
                for key in dictionary.keys.sorted() {
                    guard let value = dictionary[key] else { continue }
                    let lowered = key.lowercased()
                    let isAllowed = allowedKeys.contains(lowered)
                    let isFixed = isFixedSchemaPosition(path)
                    var childIsAnonymous = insideAnonymousScope

                    if !isAllowed, !isFixed {
                        addKeyReplacement(for: key)
                        childIsAnonymous = true
                    }

                    if isIdentityField(key: lowered, path: path),
                       let string = value as? String,
                       (childIsAnonymous || !allowedIdentityValues.contains(string)) {
                        addValueReplacement(for: string)
                    }

                    if isAllowed || !isFixed {
                        collectIdentityValues(
                            value,
                            path: path + [lowered],
                            insideAnonymousScope: childIsAnonymous)
                    }
                }
            case let array as [Any]:
                for value in array {
                    collectIdentityValues(
                        value,
                        path: path,
                        insideAnonymousScope: insideAnonymousScope)
                }
            default:
                break
            }
        }

        private mutating func addKeyReplacement(for string: String) {
            guard replacements[string] == nil else { return }
            replacements[string] = "<redacted-key-\(nextKeyIndex)>"
            nextKeyIndex += 1
        }

        private mutating func addValueReplacement(for string: String) {
            guard replacements[string] == nil else { return }
            replacements[string] = "<redacted-value-\(nextValueIndex)>"
            nextValueIndex += 1
        }
    }

    private static func sanitizeStructure(
        _ object: Any,
        path: [String],
        insideAnonymousScope: Bool,
        replacements: [String: String],
        anonymizedKeyCount: inout Int,
        messages: inout [String]
    ) -> Any {
        switch object {
        case let dictionary as [String: Any]:
            var output: [String: Any] = [:]
            for key in dictionary.keys.sorted() {
                guard let value = dictionary[key] else { continue }
                let lowered = key.lowercased()
                if allowedKeys.contains(lowered) {
                    output[key] = sanitizeStructure(
                        value,
                        path: path + [lowered],
                        insideAnonymousScope: insideAnonymousScope,
                        replacements: replacements,
                        anonymizedKeyCount: &anonymizedKeyCount,
                        messages: &messages)
                } else if isFixedSchemaPosition(path) {
                    output[key] = "<redacted>"
                    messages.append("未知キーを秘匿: \(key)")
                } else {
                    let anonymousKey = replacements[key] ?? "<redacted-key>"
                    anonymizedKeyCount += 1
                    if value is [String: Any] || value is [Any] {
                        output[anonymousKey] = sanitizeStructure(
                            value,
                            path: path + [lowered],
                            insideAnonymousScope: true,
                            replacements: replacements,
                            anonymizedKeyCount: &anonymizedKeyCount,
                            messages: &messages)
                    } else {
                        output[anonymousKey] = "<redacted>"
                    }
                }
            }
            return output
        case let array as [Any]:
            return array.map {
                sanitizeStructure(
                    $0,
                    path: path,
                    insideAnonymousScope: insideAnonymousScope,
                    replacements: replacements,
                    anonymizedKeyCount: &anonymizedKeyCount,
                    messages: &messages)
            }
        default:
            return object
        }
    }

    private static func replaceSensitiveStrings(
        _ object: Any,
        replacements: [String: String]
    ) -> Any {
        switch object {
        case let dictionary as [String: Any]:
            return dictionary.mapValues {
                replaceSensitiveStrings($0, replacements: replacements)
            }
        case let array as [Any]:
            return array.map { replaceSensitiveStrings($0, replacements: replacements) }
        case let string as String:
            return replacements[string] ?? string
        default:
            return object
        }
    }

    private static func isIdentityField(key: String, path: [String]) -> Bool {
        if key == "limitid" || key == "limitname" { return true }
        guard key == "id" || key == "display_name" else { return false }
        return path.suffix(2).elementsEqual(["scope", "model"])
    }

    private static func isFixedSchemaPosition(_ path: [String]) -> Bool {
        guard !path.isEmpty else { return true }
        if path.last == "ratelimitsbylimitid" { return false }
        if path.count >= 2, path[path.count - 2] == "ratelimitsbylimitid" { return true }
        return path.last.map(fixedSchemaParents.contains) ?? false
    }
}
