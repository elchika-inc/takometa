import XCTest
@testable import TakometaCore

final class ClaudeCredentialsReaderTests: XCTestCase {
    func testReadsAccessTokenFromCredentialsJSON() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"dummy-for-test","scopes":["user:profile"]}}"#
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("credentials.json")
        try json.data(using: .utf8)!.write(to: file)

        let token = ClaudeCredentialsReader.accessToken(fromFileAt: file)
        XCTAssertEqual(token, "dummy-for-test")
    }

    func testMissingOAuthSectionReturnsNil() throws {
        let json = #"{"mcpOAuth":{}}"#
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("credentials.json")
        try json.data(using: .utf8)!.write(to: file)

        XCTAssertNil(ClaudeCredentialsReader.accessToken(fromFileAt: file))
    }

    func testReadsCredentialsWithEpochMillisecondsExpiration() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"dummy-for-test","expiresAt":1800000000000}}"#
        let credentials = ClaudeCredentialsReader.credentials(fromData: Data(json.utf8))

        XCTAssertEqual(credentials?.accessToken, "dummy-for-test")
        XCTAssertEqual(
            credentials?.expiresAt,
            Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testSuccessfulEmptyKeychainOutputIsMalformedNotReadFailure() {
        let result = ClaudeCredentialsReader.classifyKeychainOutput(
            terminationStatus: 0,
            terminationReason: .exit,
            output: Data())

        XCTAssertEqual(result, .success(Data()))
    }
}
