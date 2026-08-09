public enum SettingsSupply {
    public static func notificationSettings(
        from providers: [String: ProviderSettings]
    ) -> [ProviderID: NotificationSettings] {
        providers.reduce(into: [:]) { result, entry in
            guard let provider = ProviderID(rawValue: entry.key) else { return }
            let settings = entry.value
            result[provider] = NotificationSettings(
                enabled: settings.notificationsEnabled,
                usageThreshold: settings.usageThreshold,
                dailyEnabled: settings.dailyEnabled,
                dailyThreshold: settings.dailyThreshold)
        }
    }

    public static func displayFilter(
        from providers: [String: ProviderSettings]
    ) -> DisplayFilter {
        DisplayFilter(
            codex: displayFilter(
                from: providers[ProviderID.codex.rawValue] ?? ProviderSettings()),
            claude: displayFilter(
                from: providers[ProviderID.claude.rawValue] ?? ProviderSettings()))
    }

    public static func windowKindOrders(
        from providers: [String: ProviderSettings]
    ) -> [ProviderID: [WindowKindCategory]] {
        providers.reduce(into: [:]) { result, entry in
            guard let provider = ProviderID(rawValue: entry.key) else { return }
            result[provider] = entry.value.windowKindOrder
        }
    }

    private static func displayFilter(
        from settings: ProviderSettings
    ) -> ProviderDisplayFilter {
        ProviderDisplayFilter(
            show: settings.show,
            showSession: settings.showSession,
            showWeekly: settings.showWeekly,
            showModel: settings.showModel)
    }
}
