import XCTest
@testable import TakometaCore

private actor FakeCodexTransport: CodexAppServerTransport {
    enum Operation: Equatable { case connect(String), accountRead, rateLimitsRead }

    private let authenticated: Bool
    private var rateLimitResults: [Result<CodexUsageDecodeResult, CodexTransportError>]
    private let connectError: CodexTransportError?
    private var notificationHandler: (@Sendable (String) -> Void)?
    private var disconnectionHandler: (@Sendable () -> Void)?
    private(set) var operations: [Operation] = []

    init(
        authenticated: Bool = true,
        rateLimitResults: [Result<CodexUsageDecodeResult, CodexTransportError>] = [],
        connectError: CodexTransportError? = nil
    ) {
        self.authenticated = authenticated
        self.rateLimitResults = rateLimitResults
        self.connectError = connectError
    }

    func connect(
        binaryPath: String,
        notificationHandler: @Sendable @escaping (String) -> Void,
        disconnectionHandler: @Sendable @escaping () -> Void
    ) async throws {
        operations.append(.connect(binaryPath))
        if let connectError { throw connectError }
        self.notificationHandler = notificationHandler
        self.disconnectionHandler = disconnectionHandler
    }

    func accountIsAuthenticated() async throws -> Bool {
        operations.append(.accountRead)
        return authenticated
    }

    func readRateLimits() async throws -> CodexUsageDecodeResult {
        operations.append(.rateLimitsRead)
        guard !rateLimitResults.isEmpty else { throw CodexTransportError.protocolError }
        return try rateLimitResults.removeFirst().get()
    }

    func disconnect() async {}

    func sendNotification(_ method: String) {
        notificationHandler?(method)
    }

    func terminate() {
        disconnectionHandler?()
    }
}

private final class FakeCodexTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [FakeCodexTransport]

    init(_ transports: [FakeCodexTransport]) {
        self.transports = transports
    }

    func make() -> any CodexAppServerTransport {
        lock.lock()
        defer { lock.unlock() }
        return transports.removeFirst()
    }
}

private final class CodexTestCancellable: UsageCancellable, @unchecked Sendable {
    func cancel() {}
}

private final class CodexTestScheduler: UsageScheduler, @unchecked Sendable {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let lock = NSLock()
    private var entries: [(TimeInterval, @Sendable () -> Void)] = []

    var intervals: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.0)
    }

    func schedule(
        after interval: TimeInterval,
        action: @Sendable @escaping () -> Void
    ) -> any UsageCancellable {
        lock.lock()
        entries.append((interval, action))
        lock.unlock()
        return CodexTestCancellable()
    }

    func runNext() {
        lock.lock()
        let action = entries.removeFirst().1
        lock.unlock()
        action()
    }
}

final class CodexUsageProviderTests: XCTestCase {
    private let binaryPath = "/test/bin/codex"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func decoded(percent: Double = 42) throws -> CodexUsageDecodeResult {
        let data = Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":\#(percent),"windowDurationMins":300,"resetsAt":1800003600}}}"#.utf8)
        return try CodexRateLimitsDecoder.decode(data)
    }

    private func locator(found: Bool = true) -> CodexBinaryLocator {
        CodexBinaryLocator(candidates: [binaryPath], fileExists: { _ in found })
    }

    private func provider(
        scheduler: CodexTestScheduler,
        factory: FakeCodexTransportFactory,
        found: Bool = true
    ) -> CodexUsageProvider {
        let fixedNow = now
        return CodexUsageProvider(
            locator: locator(found: found),
            scheduler: scheduler,
            transportFactory: { factory.make() },
            now: { fixedNow })
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("条件が成立しなかった")
    }

    func testMissingBinaryIsUnrecoverable() async {
        let scheduler = CodexTestScheduler()
        let factory = FakeCodexTransportFactory([])
        let provider = provider(scheduler: scheduler, factory: factory, found: false)

        do {
            _ = try await provider.fetch()
            XCTFail("unrecoverable が必要")
        } catch let error as UsageFetchError {
            XCTAssertEqual(error, .unrecoverable(reason: "Codex 未導入"))
        } catch {
            XCTFail("異なるエラー型")
        }
    }

    func testInitializeAccountReadAndRateLimitsRead() async throws {
        let transport = FakeCodexTransport(rateLimitResults: [.success(try decoded())])
        let scheduler = CodexTestScheduler()
        let provider = provider(
            scheduler: scheduler,
            factory: FakeCodexTransportFactory([transport]))

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.source, .codexAppServer)
        XCTAssertEqual(snapshot.windows.count, 1)
        let operations = await transport.operations
        XCTAssertEqual(
            operations,
            [.connect(binaryPath), .accountRead, .rateLimitsRead])
    }

    func testUnauthenticatedAccountIsAuthenticationRequired() async {
        let transport = FakeCodexTransport(authenticated: false)
        let provider = provider(
            scheduler: CodexTestScheduler(),
            factory: FakeCodexTransportFactory([transport]))

        do {
            _ = try await provider.fetch()
            XCTFail("authenticationRequired が必要")
        } catch let error as UsageFetchError {
            guard case .authenticationRequired = error else {
                return XCTFail("異なる分類")
            }
        } catch {
            XCTFail("異なるエラー型")
        }
    }

    func testDisconnectedReadIsTransient() async throws {
        let transport = FakeCodexTransport(
            rateLimitResults: [.failure(.disconnected)])
        let provider = provider(
            scheduler: CodexTestScheduler(),
            factory: FakeCodexTransportFactory([transport]))

        do {
            _ = try await provider.fetch()
            XCTFail("transient が必要")
        } catch let error as UsageFetchError {
            guard case .transient = error else { return XCTFail("異なる分類") }
        } catch {
            XCTFail("異なるエラー型")
        }
    }

    func testRestartUsesExponentialBackoff() async throws {
        let first = FakeCodexTransport(rateLimitResults: [.success(try decoded())])
        let second = FakeCodexTransport(connectError: .disconnected)
        let third = FakeCodexTransport(connectError: .disconnected)
        let scheduler = CodexTestScheduler()
        let provider = provider(
            scheduler: scheduler,
            factory: FakeCodexTransportFactory([first, second, third]))
        _ = try await provider.fetch()

        await first.terminate()
        await waitUntil { scheduler.intervals == [1] }
        scheduler.runNext()
        await waitUntil { scheduler.intervals == [2] }
        scheduler.runNext()
        await waitUntil { scheduler.intervals == [4] }
    }

    func testInitialConnectionFailureSchedulesRestart() async {
        let failed = FakeCodexTransport(connectError: .disconnected)
        let scheduler = CodexTestScheduler()
        let provider = provider(
            scheduler: scheduler,
            factory: FakeCodexTransportFactory([failed]))

        do {
            _ = try await provider.fetch()
            XCTFail("transient が必要")
        } catch let error as UsageFetchError {
            guard case .transient = error else { return XCTFail("異なる分類") }
        } catch {
            XCTFail("異なるエラー型")
        }

        await waitUntil { scheduler.intervals == [1] }
    }

    func testReconnectSuccessEmitsSnapshot() async throws {
        let first = FakeCodexTransport(rateLimitResults: [.success(try decoded())])
        let second = FakeCodexTransport(rateLimitResults: [.success(try decoded(percent: 63))])
        let scheduler = CodexTestScheduler()
        let provider = provider(
            scheduler: scheduler,
            factory: FakeCodexTransportFactory([first, second]))
        _ = try await provider.fetch()
        var iterator = provider.updates().makeAsyncIterator()

        await first.terminate()
        await waitUntil { scheduler.intervals == [1] }
        scheduler.runNext()

        let update = await iterator.next()
        XCTAssertEqual(update?.windows.first?.usedPercent, 63)
    }

    func testRateLimitsNotificationEmitsSnapshot() async throws {
        let transport = FakeCodexTransport(rateLimitResults: [
            .success(try decoded()),
            .success(try decoded(percent: 77)),
        ])
        let scheduler = CodexTestScheduler()
        let provider = provider(
            scheduler: scheduler,
            factory: FakeCodexTransportFactory([transport]))
        _ = try await provider.fetch()
        var iterator = provider.updates().makeAsyncIterator()

        await transport.sendNotification("account/rateLimits/updated")

        let update = await iterator.next()
        XCTAssertEqual(update?.windows.first?.usedPercent, 77)
    }
}
