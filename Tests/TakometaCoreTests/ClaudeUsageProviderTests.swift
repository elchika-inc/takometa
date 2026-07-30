import XCTest
@testable import TakometaCore

private final class FakeCredentialsProvider: CredentialsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var keychainResults: [Result<ClaudeCredentials, CredentialsError>]
    private var fileResults: [Result<ClaudeCredentials, CredentialsError>]
    private var keychainCount = 0
    private var fileCount = 0

    init(
        _ keychainResults: [Result<ClaudeCredentials, CredentialsError>],
        fileResults: [Result<ClaudeCredentials, CredentialsError>] = []
    ) {
        self.keychainResults = keychainResults
        self.fileResults = fileResults
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return keychainCount
    }

    var fileReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return fileCount
    }

    func readKeychainCredentials() -> Result<ClaudeCredentials, CredentialsError> {
        lock.lock()
        defer { lock.unlock() }
        keychainCount += 1
        return keychainResults.isEmpty ? .failure(.notFound) : keychainResults.removeFirst()
    }

    func readFileCredentials() -> Result<ClaudeCredentials, CredentialsError> {
        lock.lock()
        defer { lock.unlock() }
        fileCount += 1
        return fileResults.isEmpty ? .failure(.notFound) : fileResults.removeFirst()
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Event {
        case response(status: Int, data: Data)
        case failure(Error)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var events: [Event] = []
    nonisolated(unsafe) private static var count = 0

    static func reset(events: [Event]) {
        lock.lock()
        self.events = events
        count = 0
        lock.unlock()
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    private static func nextEvent() -> Event {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return events.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.nextEvent() {
        case .response(let status, let data):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class ClaudeUsageProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var successBody: Data {
        Data(#"{"limits":[{"kind":"session","percent":20,"resets_at":"2027-01-15T09:00:00Z"},{"kind":"weekly_scoped","percent":21,"resets_at":"2027-01-20T09:00:00Z","scope":{"model":{"id":null,"display_name":"Fable"}}}]}"#.utf8)
    }

    private func credentials(
        _ token: String,
        expiresAt: Date? = Date(timeIntervalSince1970: 1_900_000_000)
    ) -> ClaudeCredentials {
        ClaudeCredentials(accessToken: token, expiresAt: expiresAt)
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func provider(_ credentials: FakeCredentialsProvider) -> ClaudeUsageProvider {
        let fixedNow = now
        return ClaudeUsageProvider(credentials: credentials, session: session(), now: { fixedNow })
    }

    private func assertAuthenticationRequired(
        _ operation: () async throws -> UsageSnapshot
    ) async {
        do {
            _ = try await operation()
            XCTFail("authenticationRequired が必要")
        } catch let error as UsageFetchError {
            guard case .authenticationRequired = error else {
                return XCTFail("異なるエラー: \(String(describing: type(of: error)))")
            }
        } catch {
            XCTFail("異なるエラー型")
        }
    }

    private func assertTransient(
        _ operation: () async throws -> UsageSnapshot
    ) async {
        do {
            _ = try await operation()
            XCTFail("transient が必要")
        } catch let error as UsageFetchError {
            guard case .transient = error else {
                return XCTFail("異なるエラー: \(String(describing: type(of: error)))")
            }
        } catch {
            XCTFail("異なるエラー型")
        }
    }

    func testSuccessReturnsSnapshotAndKindMapping() async throws {
        StubURLProtocol.reset(events: [.response(status: 200, data: successBody)])
        let fake = FakeCredentialsProvider([.success(credentials("token-a"))])

        let snapshot = try await provider(fake).fetch()

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.source, .claudeOAuth)
        XCTAssertEqual(snapshot.windows.map(\.kind), [.session, .weekly])
    }

    func test401RereadsOnceThenSucceeds() async throws {
        StubURLProtocol.reset(events: [
            .response(status: 401, data: Data()),
            .response(status: 200, data: successBody),
        ])
        let fake = FakeCredentialsProvider([
            .success(credentials("token-a")),
            .success(credentials("token-b")),
        ])

        _ = try await provider(fake).fetch()

        XCTAssertEqual(fake.readCount, 2)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testSecond401BecomesAuthenticationRequired() async {
        StubURLProtocol.reset(events: [
            .response(status: 401, data: Data()),
            .response(status: 401, data: Data()),
        ])
        let fake = FakeCredentialsProvider([
            .success(credentials("token-a")),
            .success(credentials("token-b")),
        ])
        let provider = provider(fake)

        await assertAuthenticationRequired { try await provider.fetch() }
        XCTAssertEqual(fake.readCount, 2)
    }

    func testNotFoundDoesNotSendHTTPRequest() async {
        StubURLProtocol.reset(events: [])
        let fake = FakeCredentialsProvider([.failure(.notFound)])
        let provider = provider(fake)

        await assertAuthenticationRequired { try await provider.fetch() }
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testReadFailureBecomesTransient() async {
        StubURLProtocol.reset(events: [])
        let fake = FakeCredentialsProvider([.failure(.readFailure)])
        let provider = provider(fake)

        await assertTransient { try await provider.fetch() }
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testHTTPAndDecodeFailuresBecomeTransient() async {
        for event in [
            StubURLProtocol.Event.response(status: 429, data: Data()),
            .response(status: 500, data: Data()),
            .response(status: 200, data: Data("not-json".utf8)),
            .failure(URLError(.timedOut)),
        ] {
            StubURLProtocol.reset(events: [event])
            let fake = FakeCredentialsProvider([.success(credentials("token-a"))])
            let provider = provider(fake)
            await assertTransient { try await provider.fetch() }
        }
    }

    func testUnexpiredCredentialsAreReused() async throws {
        StubURLProtocol.reset(events: [
            .response(status: 200, data: successBody),
            .response(status: 200, data: successBody),
        ])
        let fake = FakeCredentialsProvider([.success(credentials("token-a"))])
        let provider = provider(fake)

        _ = try await provider.fetch()
        _ = try await provider.fetch()

        XCTAssertEqual(fake.readCount, 1)
    }

    func testCredentialsWithoutExpirationAreReusedUntil401() async throws {
        StubURLProtocol.reset(events: [
            .response(status: 200, data: successBody),
            .response(status: 200, data: successBody),
        ])
        let fake = FakeCredentialsProvider([
            .success(credentials("token-a", expiresAt: nil)),
        ])
        let provider = provider(fake)

        _ = try await provider.fetch()
        _ = try await provider.fetch()

        XCTAssertEqual(fake.readCount, 1)
    }

    func testThreeKeychainFailuresSuspendLaterKeychainReads() async throws {
        StubURLProtocol.reset(events: Array(repeating: .response(
            status: 200,
            data: successBody), count: 4))
        let expired = credentials("file-token", expiresAt: now.addingTimeInterval(-1))
        let fake = FakeCredentialsProvider(
            Array(repeating: .failure(.readFailure), count: 3),
            fileResults: Array(repeating: .success(expired), count: 4))
        let provider = provider(fake)

        for _ in 0..<4 {
            _ = try await provider.fetch()
        }

        XCTAssertEqual(fake.readCount, 3)
        XCTAssertEqual(fake.fileReadCount, 4)
    }

    func testFileSuccessDoesNotResetKeychainFailureCounter() async throws {
        StubURLProtocol.reset(events: Array(repeating: .response(
            status: 200,
            data: successBody), count: 4))
        let expired = credentials("file-token", expiresAt: now.addingTimeInterval(-1))
        let fake = FakeCredentialsProvider(
            [
                .failure(.readFailure),
                .failure(.readFailure),
                .failure(.readFailure),
                .success(credentials("unexpected-keychain-token")),
            ],
            fileResults: Array(repeating: .success(expired), count: 4))
        let provider = provider(fake)

        for _ in 0..<4 {
            _ = try await provider.fetch()
        }

        XCTAssertEqual(fake.readCount, 3)
        XCTAssertEqual(fake.fileReadCount, 4)
    }

    func testSuspensionStillTriesFileAndBothUnavailableRequireAuthentication() async throws {
        StubURLProtocol.reset(events: Array(repeating: .response(
            status: 200,
            data: successBody), count: 3))
        let expired = credentials("file-token", expiresAt: now.addingTimeInterval(-1))
        let fake = FakeCredentialsProvider(
            Array(repeating: .failure(.readFailure), count: 3),
            fileResults: [
                .success(expired),
                .success(expired),
                .success(expired),
                .failure(.readFailure),
            ])
        let provider = provider(fake)

        for _ in 0..<3 {
            _ = try await provider.fetch()
        }
        do {
            _ = try await provider.fetch()
            XCTFail("authenticationRequired が必要")
        } catch let error as UsageFetchError {
            XCTAssertEqual(
                error,
                .authenticationRequired(reason: "Keychain アクセス不可（手動更新で再試行）"))
        }
        XCTAssertEqual(fake.readCount, 3)
        XCTAssertEqual(fake.fileReadCount, 4)
    }

    func testKeychainSuccessResetsConsecutiveFailureCounter() async throws {
        StubURLProtocol.reset(events: Array(repeating: .response(
            status: 200,
            data: successBody), count: 6))
        let expiredFile = credentials("file-token", expiresAt: now.addingTimeInterval(-1))
        let expiredKeychain = credentials("keychain-token", expiresAt: now.addingTimeInterval(-1))
        let fake = FakeCredentialsProvider(
            [
                .failure(.readFailure),
                .failure(.readFailure),
                .success(expiredKeychain),
                .failure(.readFailure),
                .failure(.readFailure),
                .success(expiredKeychain),
            ],
            fileResults: Array(repeating: .success(expiredFile), count: 4))
        let provider = provider(fake)

        for _ in 0..<6 {
            _ = try await provider.fetch()
        }

        XCTAssertEqual(fake.readCount, 6)
        XCTAssertEqual(fake.fileReadCount, 4)
    }

    func testResetKeychainSuspensionRetriesFromZero() async throws {
        StubURLProtocol.reset(events: Array(repeating: .response(
            status: 200,
            data: successBody), count: 5))
        let expiredFile = credentials("file-token", expiresAt: now.addingTimeInterval(-1))
        let expiredKeychain = credentials("keychain-token", expiresAt: now.addingTimeInterval(-1))
        let fake = FakeCredentialsProvider(
            [
                .failure(.readFailure),
                .failure(.readFailure),
                .failure(.readFailure),
                .success(expiredKeychain),
            ],
            fileResults: Array(repeating: .success(expiredFile), count: 4))
        let provider = provider(fake)

        for _ in 0..<4 {
            _ = try await provider.fetch()
        }
        XCTAssertEqual(fake.readCount, 3)

        provider.resetKeychainSuspension()
        _ = try await provider.fetch()

        XCTAssertEqual(fake.readCount, 4)
    }

    func testCrossHostRedirectIsRejected() async {
        let delegate = CrossHostRedirectDelegate(allowedHost: "api.anthropic.com")
        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            statusCode: 302, httpVersion: nil,
            headerFields: ["Location": "https://example.com/elsewhere"])!
        let request = URLRequest(url: URL(string: "https://example.com/elsewhere")!)
        let expectation = expectation(description: "redirect")

        delegate.urlSession(
            session(), task: URLSession.shared.dataTask(with: response.url!),
            willPerformHTTPRedirection: response, newRequest: request
        ) { redirected in
            XCTAssertNil(redirected)
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 1)
    }

    func testHTTPDowngradeRedirectIsRejected() async {
        let delegate = CrossHostRedirectDelegate(allowedHost: "api.anthropic.com")
        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            statusCode: 302, httpVersion: nil,
            headerFields: ["Location": "http://api.anthropic.com/elsewhere"])!
        let request = URLRequest(url: URL(string: "http://api.anthropic.com/elsewhere")!)
        let expectation = expectation(description: "redirect")

        delegate.urlSession(
            session(), task: URLSession.shared.dataTask(with: response.url!),
            willPerformHTTPRedirection: response, newRequest: request
        ) { redirected in
            XCTAssertNil(redirected)
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 1)
    }

    func testPhase0FetcherAlsoUsesRedirectRejectingSession() {
        XCTAssertTrue(ClaudeOAuthUsageFetcher.session.delegate is CrossHostRedirectDelegate)
    }
}
