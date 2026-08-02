import Foundation

public enum NotificationSettingsLoader {
    public static let displayModeKey = "displayMode"
    public static let showCodexKey = "showCodex"
    public static let showClaudeKey = "showClaude"
    public static let codexShowSessionKey = "codexShowSession"
    public static let codexShowWeeklyKey = "codexShowWeekly"
    public static let codexShowModelKey = "codexShowModel"
    public static let claudeShowSessionKey = "claudeShowSession"
    public static let claudeShowWeeklyKey = "claudeShowWeekly"
    public static let claudeShowModelKey = "claudeShowModel"
    public static let codexNotificationsEnabledKey = "codexNotificationsEnabled"
    public static let codexUsageThresholdKey = "codexUsageThreshold"
    public static let codexDailyEnabledKey = "codexDailyEnabled"
    public static let codexDailyThresholdKey = "codexDailyThreshold"
    public static let claudeNotificationsEnabledKey = "claudeNotificationsEnabled"
    public static let claudeUsageThresholdKey = "claudeUsageThreshold"
    public static let claudeDailyEnabledKey = "claudeDailyEnabled"
    public static let claudeDailyThresholdKey = "claudeDailyThreshold"

    public static func migrate(from defaults: UserDefaults) -> SettingsDocument {
        SettingsDocument(
            displayMode: DisplayMode.fromPersistedValue(defaults.string(forKey: displayModeKey)),
            providers: [
                ProviderID.codex.rawValue: providerSettings(
                    from: defaults,
                    showKey: showCodexKey,
                    showSessionKey: codexShowSessionKey,
                    showWeeklyKey: codexShowWeeklyKey,
                    showModelKey: codexShowModelKey,
                    enabledKey: codexNotificationsEnabledKey,
                    usageThresholdKey: codexUsageThresholdKey,
                    dailyEnabledKey: codexDailyEnabledKey,
                    dailyThresholdKey: codexDailyThresholdKey),
                ProviderID.claude.rawValue: providerSettings(
                    from: defaults,
                    showKey: showClaudeKey,
                    showSessionKey: claudeShowSessionKey,
                    showWeeklyKey: claudeShowWeeklyKey,
                    showModelKey: claudeShowModelKey,
                    enabledKey: claudeNotificationsEnabledKey,
                    usageThresholdKey: claudeUsageThresholdKey,
                    dailyEnabledKey: claudeDailyEnabledKey,
                    dailyThresholdKey: claudeDailyThresholdKey),
            ])
    }

    private static func providerSettings(
        from defaults: UserDefaults,
        showKey: String,
        showSessionKey: String,
        showWeeklyKey: String,
        showModelKey: String,
        enabledKey: String,
        usageThresholdKey: String,
        dailyEnabledKey: String,
        dailyThresholdKey: String
    ) -> ProviderSettings {
        let fallback = ProviderSettings()
        return ProviderSettings(
            show: bool(from: defaults, key: showKey, fallback: fallback.show),
            showSession: bool(
                from: defaults, key: showSessionKey, fallback: fallback.showSession),
            showWeekly: bool(
                from: defaults, key: showWeeklyKey, fallback: fallback.showWeekly),
            showModel: bool(from: defaults, key: showModelKey, fallback: fallback.showModel),
            notificationsEnabled: bool(
                from: defaults, key: enabledKey, fallback: fallback.notificationsEnabled),
            usageThreshold: double(
                from: defaults,
                key: usageThresholdKey,
                fallback: fallback.usageThreshold),
            dailyEnabled: bool(
                from: defaults,
                key: dailyEnabledKey,
                fallback: fallback.dailyEnabled),
            dailyThreshold: double(
                from: defaults,
                key: dailyThresholdKey,
                fallback: fallback.dailyThreshold))
    }

    private static func bool(
        from defaults: UserDefaults,
        key: String,
        fallback: Bool
    ) -> Bool {
        guard let value = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return fallback }
        return value.boolValue
    }

    private static func double(
        from defaults: UserDefaults,
        key: String,
        fallback: Double
    ) -> Double {
        guard let value = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite
        else { return fallback }
        return value.doubleValue
    }
}
