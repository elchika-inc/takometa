import Foundation
import OSLog

private final class ClaudeCredentialCache: @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: ClaudeCredentials?

    func valid(at now: Date) -> ClaudeCredentials? {
        lock.lock()
        defer { lock.unlock() }
        guard let credentials else { return nil }
        guard let expiresAt = credentials.expiresAt else { return credentials }
        return expiresAt > now ? credentials : nil
    }

    func store(_ credentials: ClaudeCredentials) {
        lock.lock()
        defer { lock.unlock() }
        self.credentials = credentials
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        credentials = nil
    }
}

final class CrossHostRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHost: String

    init(allowedHost: String) {
        self.allowedHost = allowedHost
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let url = request.url
        let isAllowed = url?.scheme == "https" && url?.host == allowedHost
        completionHandler(isAllowed ? request : nil)
    }
}

public final class ClaudeUsageProvider: UsageProvider, @unchecked Sendable {
    public let id: ProviderID = .claude
    public let normalInterval: TimeInterval = 60

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let credentialsProvider: any CredentialsProviding
    private let session: URLSession
    private let cache = ClaudeCredentialCache()
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "Takometa", category: "ClaudeUsageProvider")
    private let suspensionLock = NSLock()
    private var consecutiveKeychainFailures = 0
    private var keychainSuspended = false

    public convenience init(
        credentials: any CredentialsProviding,
        session: URLSession = .shared
    ) {
        self.init(credentials: credentials, session: session, now: Date.init)
    }

    init(
        credentials: any CredentialsProviding,
        session: URLSession,
        now: @Sendable @escaping () -> Date
    ) {
        self.credentialsProvider = credentials
        let configuration = session.configuration
        let delegate = CrossHostRedirectDelegate(allowedHost: Self.endpoint.host!)
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.now = now
    }

    public func fetch() async throws -> UsageSnapshot {
        let credential: ClaudeCredentials
        if let cached = cache.valid(at: now()) {
            credential = cached
        } else {
            credential = try readCredentials()
            cache.store(credential)
        }

        let firstResponse = try await request(using: credential)
        if firstResponse.statusCode == 401 {
            let refreshed = try readCredentials()
            cache.store(refreshed)
            let retryResponse = try await request(using: refreshed)
            guard retryResponse.statusCode != 401 else {
                throw UsageFetchError.authenticationRequired(reason: "Claude の認証が必要です")
            }
            return try snapshot(from: retryResponse)
        }
        return try snapshot(from: firstResponse)
    }

    public func updates() -> AsyncStream<UsageSnapshot> {
        AsyncStream { continuation in continuation.finish() }
    }

    public func resetKeychainSuspension() {
        suspensionLock.lock()
        consecutiveKeychainFailures = 0
        keychainSuspended = false
        suspensionLock.unlock()
        cache.clear()
    }

    private func readCredentials() throws -> ClaudeCredentials {
        var keychainError: CredentialsError?
        if !isKeychainSuspended {
            switch credentialsProvider.readKeychainCredentials() {
            case .success(let credentials):
                recordKeychainSuccess()
                return credentials
            case .failure(let error):
                keychainError = error
                recordKeychainFailure()
            }
        }

        switch credentialsProvider.readFileCredentials() {
        case .success(let credentials):
            return credentials
        case .failure(let fileError):
            if isKeychainSuspended {
                throw UsageFetchError.authenticationRequired(
                    reason: "Keychain アクセス不可（手動更新で再試行）")
            }
            if keychainError == .notFound, fileError == .notFound {
                throw UsageFetchError.authenticationRequired(reason: "Claude の資格情報がありません")
            }
            throw UsageFetchError.transient(reason: "Claude の資格情報を読み取れません")
        }
    }

    private var isKeychainSuspended: Bool {
        suspensionLock.lock()
        defer { suspensionLock.unlock() }
        return keychainSuspended
    }

    private func recordKeychainSuccess() {
        suspensionLock.lock()
        consecutiveKeychainFailures = 0
        keychainSuspended = false
        suspensionLock.unlock()
    }

    private func recordKeychainFailure() {
        suspensionLock.lock()
        consecutiveKeychainFailures += 1
        if consecutiveKeychainFailures >= 3 {
            keychainSuspended = true
        }
        suspensionLock.unlock()
    }

    private func request(using credentials: ClaudeCredentials) async throws -> HTTPResult {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw UsageFetchError.transient(reason: "Claude API の応答が不正です")
            }
            return HTTPResult(statusCode: response.statusCode, data: data)
        } catch let error as UsageFetchError {
            throw error
        } catch {
            throw UsageFetchError.transient(reason: "Claude API への接続に失敗しました")
        }
    }

    private func snapshot(from response: HTTPResult) throws -> UsageSnapshot {
        guard response.statusCode == 200 else {
            throw UsageFetchError.transient(reason: "Claude API が一時的なエラーを返しました")
        }
        do {
            let fetchedAt = now()
            let decoded = try ClaudeOAuthUsageDecoder.decode(response.data, now: fetchedAt)
            if !decoded.unknownKeys.isEmpty {
                logger.notice("Claude usage response に未知キー: \(decoded.unknownKeys, privacy: .public)")
            }
            return UsageSnapshot(
                provider: .claude,
                windows: decoded.windows,
                fetchedAt: fetchedAt,
                source: .claudeOAuth)
        } catch {
            throw UsageFetchError.transient(reason: "Claude API の応答を解釈できません")
        }
    }

    private struct HTTPResult {
        let statusCode: Int
        let data: Data
    }
}
