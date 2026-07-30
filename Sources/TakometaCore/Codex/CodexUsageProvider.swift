import Foundation
import OSLog

private actor CodexProviderController {
    typealias TransportFactory = @Sendable () -> any CodexAppServerTransport

    private let binaryPath: String
    private let scheduler: any UsageScheduler
    private let transportFactory: TransportFactory
    private let now: @Sendable () -> Date
    private let continuation: AsyncStream<UsageSnapshot>.Continuation
    private let logger = Logger(subsystem: "Takometa", category: "CodexUsageProvider")
    private var transport: (any CodexAppServerTransport)?
    private var connectionID: UUID?
    private var restartAttempt = 0
    private var restartScheduled = false
    private var restartCancellable: (any UsageCancellable)?

    init(
        binaryPath: String,
        scheduler: any UsageScheduler,
        transportFactory: @escaping TransportFactory,
        now: @Sendable @escaping () -> Date,
        continuation: AsyncStream<UsageSnapshot>.Continuation
    ) {
        self.binaryPath = binaryPath
        self.scheduler = scheduler
        self.transportFactory = transportFactory
        self.now = now
        self.continuation = continuation
    }

    func fetch() async throws -> UsageSnapshot {
        do {
            let transport = try await connectedTransport()
            guard try await transport.accountIsAuthenticated() else {
                throw UsageFetchError.authenticationRequired(reason: "Codex へのログインが必要です")
            }
            let decoded = try await transport.readRateLimits()
            return snapshot(from: decoded)
        } catch let error as UsageFetchError {
            throw error
        } catch {
            throw UsageFetchError.transient(reason: "Codex app-server との通信に失敗しました")
        }
    }

    private func connectedTransport() async throws -> any CodexAppServerTransport {
        if let transport { return transport }
        let newTransport = transportFactory()
        let id = UUID()
        transport = newTransport
        connectionID = id
        do {
            try await newTransport.connect(
                binaryPath: binaryPath,
                notificationHandler: { [weak self] method in
                    Task { await self?.receivedNotification(method, connectionID: id) }
                },
                disconnectionHandler: { [weak self] in
                    Task { await self?.disconnected(connectionID: id) }
                })
            guard connectionID == id, transport != nil else {
                throw CodexTransportError.disconnected
            }
            return newTransport
        } catch {
            if connectionID == id {
                transport = nil
                connectionID = nil
            }
            scheduleRestart()
            throw error
        }
    }

    private func receivedNotification(_ method: String, connectionID id: UUID) async {
        guard connectionID == id, method == "account/rateLimits/updated",
              let transport else { return }
        do {
            let decoded = try await transport.readRateLimits()
            continuation.yield(snapshot(from: decoded))
        } catch {
            // プロセス切断時は disconnectionHandler が再起動を担当する。
        }
    }

    private func disconnected(connectionID id: UUID) {
        guard connectionID == id else { return }
        transport = nil
        connectionID = nil
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !restartScheduled else { return }
        restartAttempt += 1
        restartScheduled = true
        let delay = RestartBackoff.delay(attempt: restartAttempt)
        restartCancellable = scheduler.schedule(after: delay) { [weak self] in
            Task { await self?.restart() }
        }
    }

    private func restart() async {
        restartScheduled = false
        restartCancellable = nil
        do {
            let transport = try await connectedTransport()
            let authenticated = try await transport.accountIsAuthenticated()
            guard authenticated else {
                restartAttempt = 0
                return
            }
            let decoded = try await transport.readRateLimits()
            restartAttempt = 0
            continuation.yield(snapshot(from: decoded))
        } catch {
            transport = nil
            connectionID = nil
            scheduleRestart()
        }
    }

    private func snapshot(from decoded: CodexUsageDecodeResult) -> UsageSnapshot {
        if !decoded.unknownKeys.isEmpty {
            logger.notice("Codex rate limits に未知キー: \(decoded.unknownKeys, privacy: .public)")
        }
        return UsageSnapshot(
            provider: .codex,
            windows: decoded.windows,
            fetchedAt: now(),
            source: .codexAppServer)
    }
}

public final class CodexUsageProvider: UsageProvider, @unchecked Sendable {
    public let id: ProviderID = .codex
    public let normalInterval: TimeInterval = 300

    private let binaryPath: String?
    private let controller: CodexProviderController?
    private let updateStream: AsyncStream<UsageSnapshot>

    public convenience init(
        locator: CodexBinaryLocator = .init(),
        scheduler: any UsageScheduler
    ) {
        self.init(
            locator: locator,
            scheduler: scheduler,
            transportFactory: { CodexProcessTransport() },
            now: { scheduler.now })
    }

    init(
        locator: CodexBinaryLocator,
        scheduler: any UsageScheduler,
        transportFactory: @Sendable @escaping () -> any CodexAppServerTransport,
        now: @Sendable @escaping () -> Date
    ) {
        let pair = AsyncStream<UsageSnapshot>.makeStream()
        let binaryPath = locator.locate()
        self.binaryPath = binaryPath
        self.updateStream = pair.stream
        if let binaryPath {
            self.controller = CodexProviderController(
                binaryPath: binaryPath,
                scheduler: scheduler,
                transportFactory: transportFactory,
                now: now,
                continuation: pair.continuation)
        } else {
            pair.continuation.finish()
            self.controller = nil
        }
    }

    public func fetch() async throws -> UsageSnapshot {
        guard binaryPath != nil, let controller else {
            throw UsageFetchError.unrecoverable(reason: "Codex 未導入")
        }
        return try await controller.fetch()
    }

    public func updates() -> AsyncStream<UsageSnapshot> {
        updateStream
    }
}
