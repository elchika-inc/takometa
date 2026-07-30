import XCTest
@testable import TakometaCore

final class WindowKindOrderingTests: XCTestCase {
    func testDefaultOrderCoversAllCases() {
        XCTAssertEqual(WindowKindCategory.defaultOrder.count, WindowKindCategory.allCases.count)
        XCTAssertEqual(Set(WindowKindCategory.defaultOrder), Set(WindowKindCategory.allCases))
    }

    func testNormalizedOrderRemovesUnknownAndFillsMissing() {
        XCTAssertEqual(
            WindowKindCategory.normalizedOrder(["future", "weekly"]),
            [.weekly, .session, .model])
    }

    func testNormalizedOrderRemovesDuplicatesKeepingFirst() {
        XCTAssertEqual(
            WindowKindCategory.normalizedOrder(["model", "model", "session"]),
            [.model, .session, .weekly])
    }

    func testNormalizedOrderOfEmptyIsDefaultOrder() {
        XCTAssertEqual(WindowKindCategory.normalizedOrder([]), WindowKindCategory.defaultOrder)
    }

    func testSortedPlacesItemsInGivenOrder() {
        let items: [(String, WindowKindCategory)] = [
            ("a", .session), ("b", .weekly), ("c", .model),
        ]
        let sorted = WindowKindOrdering.sorted(items, order: [.model, .weekly, .session]) { $0.1 }
        XCTAssertEqual(sorted.map(\.0), ["c", "b", "a"])
    }

    func testSortedKeepsInputOrderWithinSameCategory() {
        let items: [(String, WindowKindCategory)] = [
            ("m1", .model), ("m2", .model), ("s", .session),
            ("m3", .model), ("m4", .model),
        ]
        let sorted = WindowKindOrdering.sorted(items, order: [.model, .session, .weekly]) { $0.1 }
        XCTAssertEqual(sorted.map(\.0), ["m1", "m2", "m3", "m4", "s"])
    }

    func testSortedPlacesCategoriesMissingFromOrderAtEndKeepingInputOrder() {
        let items: [(String, WindowKindCategory)] = [
            ("m", .model), ("s", .session), ("w", .weekly),
        ]
        let sorted = WindowKindOrdering.sorted(items, order: [.weekly]) { $0.1 }
        XCTAssertEqual(sorted.map(\.0), ["w", "m", "s"])
    }

    func testSortedWithEmptyOrderReturnsInputOrder() {
        let items: [(String, WindowKindCategory)] = [("m", .model), ("s", .session)]
        let sorted = WindowKindOrdering.sorted(items, order: []) { $0.1 }
        XCTAssertEqual(sorted.map(\.0), ["m", "s"])
    }

    func testSortedWithEmptyItemsReturnsEmpty() {
        let items: [(String, WindowKindCategory)] = []
        let sorted = WindowKindOrdering.sorted(items, order: WindowKindCategory.defaultOrder) { $0.1 }
        XCTAssertTrue(sorted.isEmpty)
    }

    func testApplyingVisibleReorderFillsOccupiedIndices() {
        // session は非表示。weekly と model が添字 1, 2 を占める
        let result = WindowKindOrdering.applyingVisibleReorder(
            full: [.session, .weekly, .model],
            visibleReordered: [.model, .weekly])
        XCTAssertEqual(result, [.session, .model, .weekly])
    }

    func testApplyingVisibleReorderKeepsHiddenCategoryFromFallingToEnd() {
        // session は非表示で添字 1 にある。末尾へ落ちないこと
        let result = WindowKindOrdering.applyingVisibleReorder(
            full: [.model, .session, .weekly],
            visibleReordered: [.weekly, .model])
        XCTAssertEqual(result, [.weekly, .session, .model])
    }

    func testApplyingVisibleReorderWithAllVisibleUsesReorderedDirectly() {
        let result = WindowKindOrdering.applyingVisibleReorder(
            full: [.session, .weekly, .model],
            visibleReordered: [.model, .session, .weekly])
        XCTAssertEqual(result, [.model, .session, .weekly])
    }

    func testApplyingVisibleReorderWithSingleVisibleIsIdentity() {
        let result = WindowKindOrdering.applyingVisibleReorder(
            full: [.session, .weekly, .model],
            visibleReordered: [.weekly])
        XCTAssertEqual(result, [.session, .weekly, .model])
    }

    func testApplyingVisibleReorderWithEmptyVisibleReturnsFull() {
        let result = WindowKindOrdering.applyingVisibleReorder(
            full: [.session, .weekly, .model],
            visibleReordered: [])
        XCTAssertEqual(result, [.session, .weekly, .model])
    }

    func testApplyingVisibleReorderIgnoresValuesOutsideFullAndDuplicates() {
        let result = WindowKindOrdering.applyingVisibleReorder(
            full: [.session, .weekly],
            visibleReordered: [.model, .weekly, .weekly, .session])
        XCTAssertEqual(result, [.weekly, .session])
    }
}
