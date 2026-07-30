import XCTest
@testable import TakometaCore

final class SettingsSupplyTests: XCTestCase {
    func testNotificationSettingsIgnoresUnknownProviderIDs() {
        let providers = [
            "codex": ProviderSettings(
                notificationsEnabled: true,
                usageThreshold: 75,
                dailyEnabled: true,
                dailyThreshold: 15),
            "future": ProviderSettings(
                notificationsEnabled: true,
                usageThreshold: 95,
                dailyEnabled: true,
                dailyThreshold: 50),
        ]

        let settings = SettingsSupply.notificationSettings(from: providers)

        XCTAssertEqual(settings, [
            .codex: NotificationSettings(
                enabled: true,
                usageThreshold: 75,
                dailyEnabled: true,
                dailyThreshold: 15),
        ])
    }

    func testDisplayFilterUsesKnownProvidersAndIgnoresUnknownProviderIDs() {
        let providers = [
            "codex": ProviderSettings(
                show: false,
                showSession: false,
                showWeekly: true,
                showModel: false),
            "claude": ProviderSettings(
                show: true,
                showSession: true,
                showWeekly: false,
                showModel: true),
            "future": ProviderSettings(
                show: false,
                showSession: false,
                showWeekly: false,
                showModel: false),
        ]

        let filter = SettingsSupply.displayFilter(from: providers)

        XCTAssertEqual(filter, DisplayFilter(
            codex: ProviderDisplayFilter(
                show: false,
                showSession: false,
                showWeekly: true,
                showModel: false),
            claude: ProviderDisplayFilter(
                show: true,
                showSession: true,
                showWeekly: false,
                showModel: true)))
    }

    func testDisplayFilterUsesProviderDefaultsForMissingKnownProvider() {
        let filter = SettingsSupply.displayFilter(from: [:])

        XCTAssertEqual(filter, DisplayFilter())
    }

    func testProviderLabelsMapsKnownProvidersAndIgnoresUnknownProviderIDs() {
        let providers = [
            "codex": ProviderSettings(label: "GPT"),
            "claude": ProviderSettings(label: "🐙"),
            "future": ProviderSettings(label: "X"),
        ]

        let labels = SettingsSupply.providerLabels(from: providers)

        XCTAssertEqual(labels, [.codex: "GPT", .claude: "🐙"])
    }

    func testWindowKindOrdersMapsKnownProvidersAndIgnoresUnknownProviderIDs() {
        let providers = [
            "codex": ProviderSettings(windowKindOrder: [.model, .weekly, .session]),
            "claude": ProviderSettings(windowKindOrder: [.weekly, .session, .model]),
            "future": ProviderSettings(windowKindOrder: [.session, .weekly, .model]),
        ]

        let orders = SettingsSupply.windowKindOrders(from: providers)

        XCTAssertEqual(orders, [
            .codex: [.model, .weekly, .session],
            .claude: [.weekly, .session, .model],
        ])
    }
}
