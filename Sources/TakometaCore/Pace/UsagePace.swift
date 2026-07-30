import Foundation

public struct UsagePace: Sendable, Equatable {
    public let averagePercentPerHour: Double
    public let projectedLimitAt: Date?
    public let willLastToReset: Bool

    public init(
        averagePercentPerHour: Double,
        projectedLimitAt: Date?,
        willLastToReset: Bool
    ) {
        self.averagePercentPerHour = averagePercentPerHour
        self.projectedLimitAt = projectedLimitAt
        self.willLastToReset = willLastToReset
    }

    /// 算出不能なら nil。時刻は呼び出し元から注入する。
    public static func calculate(
        window: RateLimitWindow,
        freshness: Freshness,
        now: Date
    ) -> UsagePace? {
        guard freshness == .fresh,
              let kind = window.kind,
              let resetsAt = window.resetsAt,
              resetsAt > now,
              window.usedPercent > 0,
              window.usedPercent < 100 else { return nil }

        let duration: TimeInterval
        switch kind {
        case .session:
            duration = 5 * 3600
        case .weekly:
            duration = 7 * 86400
        case .other(let minutes):
            duration = TimeInterval(minutes) * 60
        }

        let elapsed = duration - resetsAt.timeIntervalSince(now)
        guard elapsed > 0 else { return nil }

        let percentPerSecond = window.usedPercent / elapsed
        let secondsToLimit = (100 - window.usedPercent) / percentPerSecond
        let projectedLimitAt = now.addingTimeInterval(secondsToLimit)
        return UsagePace(
            averagePercentPerHour: percentPerSecond * 3600,
            projectedLimitAt: projectedLimitAt,
            willLastToReset: projectedLimitAt >= resetsAt)
    }
}
