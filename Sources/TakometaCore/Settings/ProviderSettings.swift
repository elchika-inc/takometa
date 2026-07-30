public struct ProviderSettings: Sendable, Equatable, Codable {
    public var show: Bool
    public var showSession: Bool
    public var showWeekly: Bool
    public var showModel: Bool
    public var notificationsEnabled: Bool
    public var usageThreshold: Double
    public var dailyEnabled: Bool
    public var dailyThreshold: Double
    public var label: String
    public var windowKindOrder: [WindowKindCategory]

    private enum CodingKeys: String, CodingKey {
        case show
        case showSession
        case showWeekly
        case showModel
        case notificationsEnabled
        case usageThreshold
        case dailyEnabled
        case dailyThreshold
        case label
        case windowKindOrder
    }

    public init(
        show: Bool = true,
        showSession: Bool = true,
        showWeekly: Bool = true,
        showModel: Bool = true,
        notificationsEnabled: Bool = NotificationSettings().enabled,
        usageThreshold: Double = NotificationSettings().usageThreshold,
        dailyEnabled: Bool = NotificationSettings().dailyEnabled,
        dailyThreshold: Double = NotificationSettings().dailyThreshold,
        label: String = "",
        windowKindOrder: [WindowKindCategory] = WindowKindCategory.defaultOrder
    ) {
        self.show = show
        self.showSession = showSession
        self.showWeekly = showWeekly
        self.showModel = showModel
        self.notificationsEnabled = notificationsEnabled
        self.usageThreshold = usageThreshold
        self.dailyEnabled = dailyEnabled
        self.dailyThreshold = dailyThreshold
        self.label = label
        self.windowKindOrder = windowKindOrder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        show = try container.decode(Bool.self, forKey: .show)
        showSession = try container.decode(Bool.self, forKey: .showSession)
        showWeekly = try container.decode(Bool.self, forKey: .showWeekly)
        showModel = try container.decode(Bool.self, forKey: .showModel)
        notificationsEnabled = try container.decode(Bool.self, forKey: .notificationsEnabled)
        usageThreshold = try container.decode(Double.self, forKey: .usageThreshold)
        dailyEnabled = try container.decode(Bool.self, forKey: .dailyEnabled)
        dailyThreshold = try container.decode(Double.self, forKey: .dailyThreshold)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        windowKindOrder = WindowKindCategory.normalizedOrder(
            try container.decodeIfPresent([String].self, forKey: .windowKindOrder) ?? [])
    }

    public func isShown(_ kind: WindowKindCategory) -> Bool {
        switch kind {
        case .session: showSession
        case .weekly: showWeekly
        case .model: showModel
        }
    }
}
