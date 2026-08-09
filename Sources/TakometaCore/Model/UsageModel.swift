import Foundation

public enum ProviderID: String, Sendable, Codable, Hashable {
    case codex
    case claude
}

/// UI・読み上げ用のプロバイダ表示名。旧 CL / CX 略称の後継。
public func providerDisplayName(_ provider: ProviderID) -> String {
    switch provider {
    case .codex: return "Codex"
    case .claude: return "Claude"
    }
}

public enum UsageSource: String, Sendable, Codable {
    case codexAppServer
    case claudeOAuth
    case claudeStatusLine
}

public enum Freshness: String, Sendable, Codable {
    case fresh
    case stale
    case unavailable
    case authenticationRequired
}

public enum RateLimitScope: Sendable, Equatable, Codable {
    case session
    case weeklyAll
    case model(id: String?, displayName: String)
    case other(String)

    private enum CodingKeys: String, CodingKey {
        case discriminator = "case"
        case id
        case displayName
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .discriminator) {
        case "session": self = .session
        case "weeklyAll": self = .weeklyAll
        case "model":
            self = .model(
                id: try container.decodeIfPresent(String.self, forKey: .id),
                displayName: try container.decode(String.self, forKey: .displayName))
        case "other": self = .other(try container.decode(String.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .discriminator, in: container,
                debugDescription: "未知の RateLimitScope")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .session:
            try container.encode("session", forKey: .discriminator)
        case .weeklyAll:
            try container.encode("weeklyAll", forKey: .discriminator)
        case .model(let id, let displayName):
            try container.encode("model", forKey: .discriminator)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encode(displayName, forKey: .displayName)
        case .other(let value):
            try container.encode("other", forKey: .discriminator)
            try container.encode(value, forKey: .value)
        }
    }
}

/// 実測（設計書 §2.1）: primary が5時間枠とは限らないため、
/// ウィンドウ種別は位置でなく継続時間から導出する。
public enum WindowKind: Sendable, Equatable, Codable {
    case session
    case weekly
    case other(minutes: Int64)

    public init(durationMinutes: Int64) {
        switch durationMinutes {
        case 300: self = .session
        case 10080: self = .weekly
        default: self = .other(minutes: durationMinutes)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case discriminator = "case"
        case minutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .discriminator) {
        case "session": self = .session
        case "weekly": self = .weekly
        case "other": self = .other(minutes: try container.decode(Int64.self, forKey: .minutes))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .discriminator, in: container,
                debugDescription: "未知の WindowKind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .session:
            try container.encode("session", forKey: .discriminator)
        case .weekly:
            try container.encode("weekly", forKey: .discriminator)
        case .other(let minutes):
            try container.encode("other", forKey: .discriminator)
            try container.encode(minutes, forKey: .minutes)
        }
    }
}

public struct RateLimitWindow: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let label: String
    public let scope: RateLimitScope
    public let usedPercent: Double
    public let resetsAt: Date?
    public let severity: String?
    public let isActive: Bool?
    public let kind: WindowKind?

    public init(
        id: String, label: String, scope: RateLimitScope,
        usedPercent: Double, resetsAt: Date?,
        severity: String? = nil, isActive: Bool? = nil,
        kind: WindowKind? = nil
    ) {
        self.id = id
        self.label = label
        self.scope = scope
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.severity = severity
        self.isActive = isActive
        self.kind = kind
    }
}

public struct UsageSnapshot: Sendable, Codable, Equatable {
    public let provider: ProviderID
    public let windows: [RateLimitWindow]
    public let fetchedAt: Date
    public let source: UsageSource

    public init(
        provider: ProviderID, windows: [RateLimitWindow],
        fetchedAt: Date, source: UsageSource
    ) {
        self.provider = provider
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.source = source
    }
}

public enum TakometaCoreInfo {
    public static let name = "TakometaCore"
}
