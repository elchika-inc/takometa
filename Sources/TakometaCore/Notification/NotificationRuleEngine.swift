import Foundation

public struct DailyBaseline: Sendable, Codable, Equatable {
    public let day: String
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(day: String, usedPercent: Double, resetsAt: Date?) {
        self.day = day
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public enum NotificationRuleEngine {
    public struct Evaluation: Sendable, Equatable {
        public let events: [NotificationEvent]
        public let newState: NotificationState
        public let newBaselines: [String: DailyBaseline]

        public init(
            events: [NotificationEvent],
            newState: NotificationState,
            newBaselines: [String: DailyBaseline]
        ) {
            self.events = events
            self.newState = newState
            self.newBaselines = newBaselines
        }
    }

    public static func evaluate(
        snapshot: UsageSnapshot,
        freshness: Freshness,
        state: NotificationState,
        baselines: [String: DailyBaseline],
        settings: NotificationSettings,
        now: Date,
        calendar: Calendar
    ) -> Evaluation {
        guard settings.enabled, freshness == .fresh else {
            return Evaluation(events: [], newState: state, newBaselines: baselines)
        }

        let selected = selectedWindows(from: snapshot)
        let currentKeys = Set(selected.map(\.key))
        let providerPrefix = "\(snapshot.provider.rawValue)|"
        var newState = state
        newState.windows = newState.windows.filter { key, _ in
            !key.hasPrefix(providerPrefix) || currentKeys.contains(key)
        }
        var newBaselines = baselines
        if settings.dailyEnabled {
            newBaselines = newBaselines.filter { key, _ in
                !key.hasPrefix(providerPrefix) || currentKeys.contains(key)
            }
        } else {
            newBaselines = newBaselines.filter { key, _ in
                !key.hasPrefix(providerPrefix)
            }
        }

        let today = dayString(now, calendar: calendar)
        var events: [NotificationEvent] = []

        for item in selected {
            let key = item.key
            let window = item.window
            var flags = newState.windows[key] ?? NotificationState.WindowFlags()

            if let reachedMark = flags.limitReached, window.usedPercent < 100 {
                events.append(.recovered(
                    provider: snapshot.provider,
                    windowID: key,
                    windowLabel: window.label,
                    basisResetsAt: reachedMark.basisResetsAt))
                flags.limitReached = nil
            }

            if window.usedPercent >= 100 {
                if shouldFire(mark: flags.limitReached, currentResetsAt: window.resetsAt) {
                    events.append(.limitReached(
                        provider: snapshot.provider,
                        windowID: key,
                        windowLabel: window.label,
                        resetsAt: window.resetsAt))
                    flags.limitReached = NotificationState.FiredMark(
                        firedAt: now,
                        basisResetsAt: window.resetsAt)
                    flags.threshold = NotificationState.FiredMark(
                        firedAt: now,
                        basisResetsAt: window.resetsAt,
                        basisThreshold: settings.usageThreshold)
                }
            } else {
                if window.usedPercent >= settings.usageThreshold,
                   shouldFire(
                       mark: flags.threshold,
                       currentResetsAt: window.resetsAt,
                       currentThreshold: settings.usageThreshold) {
                    events.append(.thresholdExceeded(
                        provider: snapshot.provider,
                        windowID: key,
                        windowLabel: window.label,
                        usedPercent: window.usedPercent,
                        threshold: settings.usageThreshold,
                        resetsAt: window.resetsAt))
                    flags.threshold = NotificationState.FiredMark(
                        firedAt: now,
                        basisResetsAt: window.resetsAt,
                        basisThreshold: settings.usageThreshold)
                }

                if let pace = UsagePace.calculate(
                    window: window,
                    freshness: freshness,
                    now: now),
                   !pace.willLastToReset,
                   let projectedLimitAt = pace.projectedLimitAt,
                   shouldFire(mark: flags.paceDanger, currentResetsAt: window.resetsAt) {
                    events.append(.paceDanger(
                        provider: snapshot.provider,
                        windowID: key,
                        windowLabel: window.label,
                        projectedLimitAt: projectedLimitAt,
                        resetsAt: window.resetsAt))
                    flags.paceDanger = NotificationState.FiredMark(
                        firedAt: now,
                        basisResetsAt: window.resetsAt)
                }
            }

            if settings.dailyEnabled, window.kind == .weekly {
                let result = evaluateDaily(
                    provider: snapshot.provider,
                    key: key,
                    window: window,
                    flags: flags,
                    baseline: newBaselines[key],
                    threshold: settings.dailyThreshold,
                    today: today,
                    now: now)
                flags = result.flags
                newBaselines[key] = result.baseline
                events.append(contentsOf: result.events)
            }

            if flags.isEmpty {
                newState.windows.removeValue(forKey: key)
            } else {
                newState.windows[key] = flags
            }
        }

        return Evaluation(
            events: events,
            newState: newState,
            newBaselines: newBaselines)
    }

    private struct SelectedWindow {
        let key: String
        let window: RateLimitWindow
    }

    private static func selectedWindows(from snapshot: UsageSnapshot) -> [SelectedWindow] {
        var order: [String] = []
        var selected: [String: RateLimitWindow] = [:]
        for window in snapshot.windows {
            let key = NotificationWindowKey.stateKey(
                provider: snapshot.provider,
                window: window)
            if selected[key] == nil {
                order.append(key)
                selected[key] = window
            } else if window.usedPercent > selected[key]!.usedPercent {
                selected[key] = window
            }
        }
        return order.compactMap { key in
            selected[key].map { SelectedWindow(key: key, window: $0) }
        }
    }

    private static func shouldFire(
        mark: NotificationState.FiredMark?,
        currentResetsAt: Date?,
        currentThreshold: Double? = nil
    ) -> Bool {
        guard let mark else { return true }
        guard let currentResetsAt else { return false }
        guard let basisResetsAt = mark.basisResetsAt else { return true }
        if !WindowIdentity.sameWindow(basisResetsAt, currentResetsAt) { return true }
        guard let currentThreshold, let basisThreshold = mark.basisThreshold else { return false }
        return basisThreshold != currentThreshold
    }

    private struct DailyEvaluation {
        let events: [NotificationEvent]
        let flags: NotificationState.WindowFlags
        let baseline: DailyBaseline
    }

    private static func evaluateDaily(
        provider: ProviderID,
        key: String,
        window: RateLimitWindow,
        flags: NotificationState.WindowFlags,
        baseline: DailyBaseline?,
        threshold: Double,
        today: String,
        now: Date
    ) -> DailyEvaluation {
        var newFlags = flags
        let activeBaseline: DailyBaseline
        if let baseline,
           baseline.day == today,
           window.usedPercent >= baseline.usedPercent,
           WindowIdentity.sameWindow(baseline.resetsAt, window.resetsAt) {
            activeBaseline = baseline
        } else {
            activeBaseline = DailyBaseline(
                day: today,
                usedPercent: window.usedPercent,
                resetsAt: window.resetsAt)
        }

        let consumed = window.usedPercent - activeBaseline.usedPercent
        var events: [NotificationEvent] = []
        let thresholdChanged = newFlags.dailyBasisThreshold.map { $0 != threshold } ?? false
        if consumed >= threshold && (newFlags.dailyFiredOn != today || thresholdChanged) {
            events.append(.dailyExceeded(
                provider: provider,
                windowID: key,
                windowLabel: window.label,
                consumedPercent: consumed,
                threshold: threshold,
                day: today))
            newFlags.dailyFiredOn = today
            newFlags.dailyBasisThreshold = threshold
        }
        return DailyEvaluation(
            events: events,
            flags: newFlags,
            baseline: activeBaseline)
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0)
    }
}

private extension NotificationState.WindowFlags {
    var isEmpty: Bool {
        threshold == nil
            && paceDanger == nil
            && limitReached == nil
            && dailyFiredOn == nil
            && dailyBasisThreshold == nil
    }
}
