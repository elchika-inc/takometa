import Foundation

public enum UsageFetchError: Error, Sendable, Equatable {
    case authenticationRequired(reason: String)
    case unrecoverable(reason: String)
    case transient(reason: String)
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var normalInterval: TimeInterval { get }
    func fetch() async throws -> UsageSnapshot
    func updates() -> AsyncStream<UsageSnapshot>
    func resetKeychainSuspension()
}

public extension UsageProvider {
    func resetKeychainSuspension() {}
}

public protocol UsageScheduler: Sendable {
    var now: Date { get }
    func schedule(
        after interval: TimeInterval,
        action: @Sendable @escaping () -> Void
    ) -> any UsageCancellable
}

public protocol UsageCancellable: Sendable {
    func cancel()
}
