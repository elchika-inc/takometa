import Foundation

public struct NotificationSettings: Sendable, Equatable {
    public var enabled: Bool
    public var usageThreshold: Double
    public var dailyEnabled: Bool
    public var dailyThreshold: Double

    public init(
        enabled: Bool = false,
        usageThreshold: Double = 80,
        dailyEnabled: Bool = false,
        dailyThreshold: Double = 20
    ) {
        self.enabled = enabled
        self.usageThreshold = usageThreshold
        self.dailyEnabled = dailyEnabled
        self.dailyThreshold = dailyThreshold
    }
}

public enum NotificationEvent: Sendable, Equatable {
    case thresholdExceeded(
        provider: ProviderID,
        windowID: String,
        windowLabel: String,
        usedPercent: Double,
        threshold: Double,
        resetsAt: Date?)
    case paceDanger(
        provider: ProviderID,
        windowID: String,
        windowLabel: String,
        projectedLimitAt: Date,
        resetsAt: Date?)
    case limitReached(
        provider: ProviderID,
        windowID: String,
        windowLabel: String,
        resetsAt: Date?)
    case recovered(
        provider: ProviderID,
        windowID: String,
        windowLabel: String,
        basisResetsAt: Date?)
    case dailyExceeded(
        provider: ProviderID,
        windowID: String,
        windowLabel: String,
        consumedPercent: Double,
        threshold: Double,
        day: String)
}

public struct NotificationState: Sendable, Codable, Equatable {
    public struct FiredMark: Sendable, Codable, Equatable {
        public var firedAt: Date
        public var basisResetsAt: Date?
        public var basisThreshold: Double?

        public init(firedAt: Date, basisResetsAt: Date?, basisThreshold: Double? = nil) {
            self.firedAt = firedAt
            self.basisResetsAt = basisResetsAt
            self.basisThreshold = basisThreshold
        }
    }

    public struct WindowFlags: Sendable, Codable, Equatable {
        public var threshold: FiredMark?
        public var paceDanger: FiredMark?
        public var limitReached: FiredMark?
        public var dailyFiredOn: String?
        public var dailyBasisThreshold: Double?

        public init(
            threshold: FiredMark? = nil,
            paceDanger: FiredMark? = nil,
            limitReached: FiredMark? = nil,
            dailyFiredOn: String? = nil,
            dailyBasisThreshold: Double? = nil
        ) {
            self.threshold = threshold
            self.paceDanger = paceDanger
            self.limitReached = limitReached
            self.dailyFiredOn = dailyFiredOn
            self.dailyBasisThreshold = dailyBasisThreshold
        }
    }

    public var windows: [String: WindowFlags]

    public init(windows: [String: WindowFlags] = [:]) {
        self.windows = windows
    }
}

public enum NotificationWindowKey {
    public static func stateKey(provider: ProviderID, window: RateLimitWindow) -> String {
        let kind: String
        switch window.kind {
        case .session:
            kind = "session"
        case .weekly:
            kind = "weekly"
        case .other:
            kind = "other"
        case nil:
            kind = "unknown"
        }

        let scope: String
        switch window.scope {
        case .session:
            scope = "session"
        case .weeklyAll:
            scope = "weeklyAll"
        case .model(let id, let displayName):
            scope = id ?? displayName
        case .other(let raw):
            scope = raw
        }

        return "\(provider.rawValue)|\(kind)|\(scope)"
    }
}

public enum WindowIdentity {
    public static func sameWindow(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            true
        case let (a?, b?):
            abs(a.timeIntervalSince(b)) < 300
        default:
            false
        }
    }
}
