import XCTest
@testable import TakometaCore

final class ProviderSettingsTests: XCTestCase {
    func testDefaultsUseVisibleDisplayRowsAndNotificationSettingsDefaults() {
        let settings = ProviderSettings()
        let notificationDefaults = NotificationSettings()

        XCTAssertTrue(settings.show)
        XCTAssertTrue(settings.showSession)
        XCTAssertTrue(settings.showWeekly)
        XCTAssertTrue(settings.showModel)
        XCTAssertEqual(settings.notificationsEnabled, notificationDefaults.enabled)
        XCTAssertEqual(settings.usageThreshold, notificationDefaults.usageThreshold)
        XCTAssertEqual(settings.dailyEnabled, notificationDefaults.dailyEnabled)
        XCTAssertEqual(settings.dailyThreshold, notificationDefaults.dailyThreshold)
    }

    func testCodableRoundTripPreservesAllFields() throws {
        let original = ProviderSettings(
            show: false,
            showSession: false,
            showWeekly: true,
            showModel: false,
            notificationsEnabled: true,
            usageThreshold: 73,
            dailyEnabled: true,
            dailyThreshold: 17)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProviderSettings.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testDecodingIgnoresLegacyLabelKey() throws {
        let json = """
        {"show":true,"showSession":true,"showWeekly":true,"showModel":true,\
        "notificationsEnabled":false,"usageThreshold":80,"dailyEnabled":false,\
        "dailyThreshold":20,"label":"MyCX"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ProviderSettings.self, from: json)
        XCTAssertTrue(decoded.show)
    }

    func testWindowKindOrderDefaultsToDefaultOrder() {
        XCTAssertEqual(ProviderSettings().windowKindOrder, WindowKindCategory.defaultOrder)
    }

    func testWindowKindOrderEncodesAndDecodesRoundTrip() throws {
        let settings = ProviderSettings(windowKindOrder: [.model, .session, .weekly])
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ProviderSettings.self, from: data)
        XCTAssertEqual(decoded.windowKindOrder, [.model, .session, .weekly])
    }

    func testMissingWindowKindOrderKeyDecodesToDefaultOrder() throws {
        let json = """
        {"show":true,"showSession":true,"showWeekly":true,"showModel":true,\
        "notificationsEnabled":false,"usageThreshold":80,"dailyEnabled":false,\
        "dailyThreshold":20}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ProviderSettings.self, from: json)
        XCTAssertEqual(decoded.windowKindOrder, WindowKindCategory.defaultOrder)
    }

    func testUnknownWindowKindOrderValueIsRemovedWithoutThrowing() throws {
        let json = """
        {"show":true,"showSession":true,"showWeekly":true,"showModel":true,\
        "notificationsEnabled":false,"usageThreshold":80,"dailyEnabled":false,\
        "dailyThreshold":20,"windowKindOrder":["future","model"]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ProviderSettings.self, from: json)
        XCTAssertEqual(decoded.windowKindOrder, [.model, .session, .weekly])
    }
}
