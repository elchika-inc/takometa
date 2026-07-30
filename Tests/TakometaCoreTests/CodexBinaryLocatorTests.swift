import XCTest
@testable import TakometaCore

final class CodexBinaryLocatorTests: XCTestCase {
    func testReturnsFirstExecutableCandidate() {
        let locator = CodexBinaryLocator(
            candidates: ["/first/codex", "/second/codex"],
            fileExists: { $0 == "/first/codex" || $0 == "/second/codex" })

        XCTAssertEqual(locator.locate(), "/first/codex")
    }

    func testReturnsSecondExecutableCandidate() {
        let locator = CodexBinaryLocator(
            candidates: ["/first/codex", "/second/codex"],
            fileExists: { $0 == "/second/codex" })

        XCTAssertEqual(locator.locate(), "/second/codex")
    }

    func testReturnsNilWhenNoCandidateIsExecutable() {
        let locator = CodexBinaryLocator(
            candidates: ["/first/codex", "/second/codex"],
            fileExists: { _ in false })

        XCTAssertNil(locator.locate())
    }
}
