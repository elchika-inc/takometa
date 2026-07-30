import XCTest
@testable import TakometaCore

final class ObservedWindowKindsTests: XCTestCase {
    func testScopeCategoryClassifiesSessionWeeklyModelAndOther() {
        XCTAssertEqual(windowKindCategory(for: .session), .session)
        XCTAssertEqual(windowKindCategory(for: .weeklyAll), .weekly)
        XCTAssertEqual(
            windowKindCategory(for: .model(id: "opus", displayName: "Opus")),
            .model)
        XCTAssertEqual(windowKindCategory(for: .other("extra")), .model)
    }

    func testObservedReturnsAllCategoriesPresentInWindows() {
        let windows = [
            makeWindow(id: "session", scope: .session),
            makeWindow(id: "weekly", scope: .weeklyAll),
            makeWindow(id: "model", scope: .model(id: "opus", displayName: "Opus")),
            makeWindow(id: "other", scope: .other("extra")),
        ]

        XCTAssertEqual(ObservedWindowKinds.observed(in: windows), [.session, .weekly, .model])
    }

    func testObservedReturnsEmptySetForNoWindows() {
        XCTAssertEqual(ObservedWindowKinds.observed(in: []), [])
    }

    func testVisibleKindsUsesOnlyObservedKindsWhenAnyAreObserved() {
        XCTAssertEqual(
            WindowKindRowRules.visibleKinds(observed: [.session, .model]),
            [.session, .model])
    }

    func testVisibleKindsShowsAllKindsWhenNothingIsObserved() {
        XCTAssertEqual(
            WindowKindRowRules.visibleKinds(observed: []),
            Set(WindowKindCategory.allCases))
    }

    func testOnlyVisibleEnabledKindIsDisabledAndVisibleOffKindsRemainEnabled() {
        let settings = ProviderSettings(
            showSession: true,
            showWeekly: false,
            showModel: false)
        let visibleKinds: Set<WindowKindCategory> = [.session, .weekly]

        XCTAssertTrue(WindowKindRowRules.isToggleDisabled(
            for: .session,
            visibleKinds: visibleKinds,
            settings: settings))
        XCTAssertFalse(WindowKindRowRules.isToggleDisabled(
            for: .weekly,
            visibleKinds: visibleKinds,
            settings: settings))
    }

    func testHiddenEnabledKindDoesNotCountTowardVisibleMinimum() {
        let settings = ProviderSettings(
            showSession: true,
            showWeekly: false,
            showModel: true)
        let visibleKinds: Set<WindowKindCategory> = [.session, .weekly]

        XCTAssertTrue(WindowKindRowRules.isToggleDisabled(
            for: .session,
            visibleKinds: visibleKinds,
            settings: settings))
    }

    func testNoKindIsDisabledWhenTwoVisibleKindsAreEnabled() {
        let settings = ProviderSettings(
            showSession: true,
            showWeekly: true,
            showModel: false)
        let visibleKinds: Set<WindowKindCategory> = [.session, .weekly]

        for kind in visibleKinds {
            XCTAssertFalse(WindowKindRowRules.isToggleDisabled(
                for: kind,
                visibleKinds: visibleKinds,
                settings: settings))
        }
    }

    func testSingleVisibleKindRemainsEnabledWhenItIsOff() {
        let settings = ProviderSettings(
            showSession: false,
            showWeekly: true,
            showModel: true)

        XCTAssertFalse(WindowKindRowRules.isToggleDisabled(
            for: .session,
            visibleKinds: [.session],
            settings: settings))
    }

    private func makeWindow(id: String, scope: RateLimitScope) -> RateLimitWindow {
        RateLimitWindow(
            id: id,
            label: id,
            scope: scope,
            usedPercent: 1,
            resetsAt: nil)
    }
}
