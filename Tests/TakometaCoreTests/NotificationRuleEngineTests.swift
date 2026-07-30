import XCTest
@testable import TakometaCore

final class NotificationRuleEngineTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func window(
        id: String = "w",
        scope: RateLimitScope = .weeklyAll,
        used: Double = 50,
        kind: WindowKind? = .weekly,
        resetsAt: Date? = nil,
        label: String = "Weekly"
    ) -> RateLimitWindow {
        RateLimitWindow(
            id: id,
            label: label,
            scope: scope,
            usedPercent: used,
            resetsAt: resetsAt,
            kind: kind)
    }

    func testStateKeyDerivation() {
        XCTAssertEqual(
            NotificationWindowKey.stateKey(
                provider: .claude,
                window: window(scope: .session, kind: .session)),
            "claude|session|session")
        XCTAssertEqual(
            NotificationWindowKey.stateKey(
                provider: .claude,
                window: window(scope: .model(id: "fable", displayName: "Fable"))),
            "claude|weekly|fable")
        XCTAssertEqual(
            NotificationWindowKey.stateKey(
                provider: .codex,
                window: window(scope: .model(id: nil, displayName: "Spark"))),
            "codex|weekly|Spark")
        XCTAssertEqual(
            NotificationWindowKey.stateKey(
                provider: .codex,
                window: window(scope: .other("raw_x"), kind: .other(minutes: 90))),
            "codex|other|raw_x")
        XCTAssertEqual(
            NotificationWindowKey.stateKey(provider: .codex, window: window(kind: nil)),
            "codex|unknown|weeklyAll")
    }

    func testSameWindow() {
        XCTAssertTrue(WindowIdentity.sameWindow(nil, nil))
        XCTAssertFalse(WindowIdentity.sameWindow(nil, now))
        XCTAssertTrue(WindowIdentity.sameWindow(now, now.addingTimeInterval(0.005)))
        XCTAssertTrue(WindowIdentity.sameWindow(now, now.addingTimeInterval(299)))
        XCTAssertFalse(WindowIdentity.sameWindow(now, now.addingTimeInterval(301)))
        XCTAssertFalse(WindowIdentity.sameWindow(now, now.addingTimeInterval(5 * 3600)))
    }

    func testThresholdEdgeFiresOnlyOnce() {
        let snapshot = usageSnapshot(windows: [window(used: 80)])
        let first = evaluate(snapshot: snapshot)

        XCTAssertEqual(first.events, [
            .thresholdExceeded(
                provider: .codex,
                windowID: "codex|weekly|weeklyAll",
                windowLabel: "Weekly",
                usedPercent: 80,
                threshold: 80,
                resetsAt: nil),
        ])
        XCTAssertTrue(evaluate(snapshot: snapshot, state: first.newState).events.isEmpty)
    }

    func testPaceDangerEdgeFiresOnlyOnce() {
        let snapshot = usageSnapshot(windows: [window(
            scope: .session,
            used: 90,
            kind: .session,
            resetsAt: now.addingTimeInterval(3600),
            label: "Session")])
        let settings = NotificationSettings(enabled: true, usageThreshold: 95)
        let first = evaluate(snapshot: snapshot, settings: settings)

        XCTAssertEqual(first.events.count, 1)
        guard case .paceDanger(
            provider: .codex,
            windowID: "codex|session|session",
            windowLabel: "Session",
            projectedLimitAt: _,
            resetsAt: now.addingTimeInterval(3600)) = first.events[0]
        else { return XCTFail("paceDanger が必要") }
        XCTAssertTrue(evaluate(
            snapshot: snapshot,
            state: first.newState,
            settings: settings).events.isEmpty)
    }

    func testLimitReachedEdgeFiresOnlyOnce() {
        let snapshot = usageSnapshot(windows: [window(used: 100)])
        let first = evaluate(snapshot: snapshot)

        XCTAssertEqual(first.events, [
            .limitReached(
                provider: .codex,
                windowID: "codex|weekly|weeklyAll",
                windowLabel: "Weekly",
                resetsAt: nil),
        ])
        XCTAssertTrue(evaluate(snapshot: snapshot, state: first.newState).events.isEmpty)
    }

    func testRecoveredEdgeFiresOnlyOnce() {
        let key = "codex|weekly|weeklyAll"
        let basis = now.addingTimeInterval(3600)
        let state = NotificationState(windows: [
            key: .init(limitReached: .init(firedAt: now, basisResetsAt: basis)),
        ])
        let snapshot = usageSnapshot(windows: [window(used: 20, resetsAt: basis)])
        let first = evaluate(snapshot: snapshot, state: state)

        XCTAssertEqual(first.events, [
            .recovered(
                provider: .codex,
                windowID: key,
                windowLabel: "Weekly",
                basisResetsAt: basis),
        ])
        XCTAssertTrue(evaluate(snapshot: snapshot, state: first.newState).events.isEmpty)
    }

    func testDailyExceededEdgeFiresOnlyOnce() {
        let key = "codex|weekly|weeklyAll"
        let reset = now.addingTimeInterval(4 * 86400)
        let day = dayString(now)
        let snapshot = usageSnapshot(windows: [window(used: 30, resetsAt: reset)])
        let settings = NotificationSettings(
            enabled: true,
            usageThreshold: 95,
            dailyEnabled: true,
            dailyThreshold: 20)
        let baselines = [key: DailyBaseline(day: day, usedPercent: 10, resetsAt: reset)]
        let first = evaluate(snapshot: snapshot, baselines: baselines, settings: settings)

        XCTAssertEqual(first.events, [
            .dailyExceeded(
                provider: .codex,
                windowID: key,
                windowLabel: "Weekly",
                consumedPercent: 20,
                threshold: 20,
                day: day),
        ])
        XCTAssertTrue(evaluate(
            snapshot: snapshot,
            state: first.newState,
            baselines: first.newBaselines,
            settings: settings).events.isEmpty)
    }

    func testThresholdIncludesEquality() {
        let result = evaluate(snapshot: usageSnapshot(windows: [window(used: 80)]))

        XCTAssertTrue(result.events.contains {
            if case .thresholdExceeded(_, _, _, 80, 80, _) = $0 { return true }
            return false
        })
    }

    func testWindowRearmingUsesSameWindowTolerance() {
        let reset = now.addingTimeInterval(3600)
        let snapshot = usageSnapshot(windows: [window(used: 85, resetsAt: reset)])
        let first = evaluate(snapshot: snapshot)
        let jittered = usageSnapshot(windows: [window(
            used: 85,
            resetsAt: reset.addingTimeInterval(0.005))])
        let renewed = usageSnapshot(windows: [window(
            used: 85,
            resetsAt: reset.addingTimeInterval(5 * 3600))])

        XCTAssertTrue(evaluate(snapshot: jittered, state: first.newState).events.isEmpty)
        XCTAssertEqual(
            evaluate(snapshot: renewed, state: first.newState).events.filter(isThreshold).count,
            1)
    }

    func testNilResetDoesNotRearmUntilResetBecomesKnown() {
        let firstSnapshot = usageSnapshot(windows: [window(used: 85)])
        let first = evaluate(snapshot: firstSnapshot)

        XCTAssertTrue(evaluate(snapshot: firstSnapshot, state: first.newState).events.isEmpty)
        let knownReset = usageSnapshot(windows: [window(
            used: 85,
            resetsAt: now.addingTimeInterval(3600))])
        XCTAssertEqual(
            evaluate(snapshot: knownReset, state: first.newState).events.filter(isThreshold).count,
            1)
    }

    func testRecoveredInheritsBasisAndImmediateHundredAfterRenewalDoesNotRecover() {
        let firstKey = "codex|weekly|weeklyAll"
        let secondKey = "codex|weekly|model"
        let firstBasis = now.addingTimeInterval(3600)
        let secondBasis = now.addingTimeInterval(7200)
        let state = NotificationState(windows: [
            firstKey: .init(limitReached: .init(firedAt: now, basisResetsAt: firstBasis)),
            secondKey: .init(limitReached: .init(firedAt: now, basisResetsAt: secondBasis)),
        ])
        let recovered = evaluate(
            snapshot: usageSnapshot(windows: [
                window(used: 10, resetsAt: firstBasis),
                window(
                    id: "model",
                    scope: .model(id: "model", displayName: "Model"),
                    used: 20,
                    resetsAt: secondBasis,
                    label: "Model"),
            ]),
            state: state)

        let bases = recovered.events.compactMap { event -> Date? in
            guard case .recovered(_, _, _, let basis) = event else { return nil }
            return basis
        }
        XCTAssertEqual(Set(bases), Set([firstBasis, secondBasis]))
        XCTAssertTrue(recovered.newState.windows.values.allSatisfy { $0.limitReached == nil })

        let renewedReset = firstBasis.addingTimeInterval(5 * 3600)
        let stillReached = evaluate(
            snapshot: usageSnapshot(windows: [window(used: 100, resetsAt: renewedReset)]),
            state: NotificationState(windows: [
                firstKey: .init(limitReached: .init(firedAt: now, basisResetsAt: firstBasis)),
            ]))
        XCTAssertFalse(stillReached.events.contains(where: isRecovered))
        XCTAssertEqual(stillReached.events.filter(isLimitReached).count, 1)
        XCTAssertEqual(
            stillReached.newState.windows[firstKey]?.limitReached?.basisResetsAt,
            renewedReset)
    }

    func testHundredSuppressesThresholdAndRecordsThresholdMark() {
        let key = "codex|weekly|weeklyAll"
        let reset = now.addingTimeInterval(3600)
        let reached = evaluate(snapshot: usageSnapshot(windows: [window(
            used: 100,
            resetsAt: reset)]))

        XCTAssertEqual(reached.events.filter(isLimitReached).count, 1)
        XCTAssertFalse(reached.events.contains(where: isThreshold))
        XCTAssertEqual(reached.newState.windows[key]?.threshold?.basisResetsAt, reset)

        let lowered = evaluate(
            snapshot: usageSnapshot(windows: [window(used: 90, resetsAt: reset)]),
            state: reached.newState)
        XCTAssertEqual(lowered.events.filter(isRecovered).count, 1)
        XCTAssertFalse(lowered.events.contains(where: isThreshold))
    }

    func testThresholdAndDailyCanFireTogether() {
        let key = "codex|weekly|weeklyAll"
        let day = dayString(now)
        let snapshot = usageSnapshot(windows: [window(used: 80)])
        let settings = NotificationSettings(
            enabled: true,
            dailyEnabled: true,
            dailyThreshold: 20)
        let result = evaluate(
            snapshot: snapshot,
            baselines: [key: DailyBaseline(day: day, usedPercent: 60, resetsAt: nil)],
            settings: settings)

        XCTAssertEqual(result.events.filter(isThreshold).count, 1)
        XCTAssertEqual(result.events.filter(isDaily).count, 1)
    }

    func testDisabledAndNonFreshAreNoOps() {
        let key = "codex|weekly|weeklyAll"
        let state = NotificationState(windows: [
            key: .init(threshold: .init(firedAt: now, basisResetsAt: nil)),
        ])
        let baselines = [key: DailyBaseline(
            day: dayString(now), usedPercent: 10, resetsAt: nil)]
        let snapshot = usageSnapshot(windows: [window(used: 100)])

        let disabled = evaluate(
            snapshot: snapshot,
            state: state,
            baselines: baselines,
            settings: NotificationSettings(enabled: false))
        XCTAssertTrue(disabled.events.isEmpty)
        XCTAssertEqual(disabled.newState, state)
        XCTAssertEqual(disabled.newBaselines, baselines)

        for freshness in [Freshness.stale, .unavailable, .authenticationRequired] {
            let result = evaluate(
                snapshot: snapshot,
                freshness: freshness,
                state: state,
                baselines: baselines)
            XCTAssertTrue(result.events.isEmpty)
            XCTAssertEqual(result.newState, state)
            XCTAssertEqual(result.newBaselines, baselines)
        }
    }

    func testMasterOffOnPreservesExistingMarksAndObservesNewEdges() {
        let existingKey = "codex|weekly|weeklyAll"
        let newKey = "codex|weekly|model"
        let state = NotificationState(windows: [
            existingKey: .init(threshold: .init(firedAt: now, basisResetsAt: nil)),
        ])
        let snapshot = usageSnapshot(windows: [
            window(used: 90),
            window(
                id: "model",
                scope: .model(id: "model", displayName: "Model"),
                used: 90,
                label: "Model"),
        ])
        let off = evaluate(
            snapshot: snapshot,
            state: state,
            settings: NotificationSettings(enabled: false))
        let on = evaluate(snapshot: snapshot, state: off.newState)

        XCTAssertEqual(off.newState, state)
        XCTAssertEqual(on.events.filter(isThreshold).count, 1)
        XCTAssertEqual(on.newState.windows[existingKey]?.threshold, state.windows[existingKey]?.threshold)
        XCTAssertNotNil(on.newState.windows[newKey]?.threshold)
        XCTAssertTrue(evaluate(snapshot: snapshot, state: on.newState).events.isEmpty)
    }

    func testDailyBaselineThreeRules() {
        let key = "codex|weekly|weeklyAll"
        let today = dayString(now)
        let yesterday = dayString(now.addingTimeInterval(-86400))
        let reset = now.addingTimeInterval(6 * 86400)
        let settings = NotificationSettings(
            enabled: true,
            usageThreshold: 95,
            dailyEnabled: true,
            dailyThreshold: 50)
        let snapshot = usageSnapshot(windows: [window(used: 40, resetsAt: reset)])

        XCTAssertEqual(
            evaluate(snapshot: snapshot, settings: settings).newBaselines[key],
            DailyBaseline(day: today, usedPercent: 40, resetsAt: reset))
        XCTAssertEqual(
            evaluate(
                snapshot: snapshot,
                baselines: [key: DailyBaseline(
                    day: yesterday, usedPercent: 10, resetsAt: reset)],
                settings: settings).newBaselines[key]?.usedPercent,
            40)
        XCTAssertEqual(
            evaluate(
                snapshot: snapshot,
                baselines: [key: DailyBaseline(
                    day: today, usedPercent: 50, resetsAt: reset)],
                settings: settings).newBaselines[key]?.usedPercent,
            40)
        XCTAssertEqual(
            evaluate(
                snapshot: snapshot,
                baselines: [key: DailyBaseline(
                    day: today,
                    usedPercent: 10,
                    resetsAt: reset.addingTimeInterval(-5 * 3600))],
                settings: settings).newBaselines[key]?.usedPercent,
            40)
    }

    func testDailyBaselineSameWindowToleranceAccumulatesButRenewalRebases() {
        let key = "codex|weekly|weeklyAll"
        let today = dayString(now)
        let reset = now.addingTimeInterval(6 * 86400)
        let settings = NotificationSettings(
            enabled: true,
            usageThreshold: 95,
            dailyEnabled: true,
            dailyThreshold: 20)
        let baseline = DailyBaseline(day: today, usedPercent: 10, resetsAt: reset)
        let jittered = evaluate(
            snapshot: usageSnapshot(windows: [window(
                used: 35,
                resetsAt: reset.addingTimeInterval(0.005))]),
            baselines: [key: baseline],
            settings: settings)

        XCTAssertEqual(jittered.newBaselines[key], baseline)
        XCTAssertEqual(jittered.events.filter(isDaily).count, 1)

        let renewedReset = reset.addingTimeInterval(7 * 86400)
        let renewed = evaluate(
            snapshot: usageSnapshot(windows: [window(used: 35, resetsAt: renewedReset)]),
            baselines: [key: baseline],
            settings: settings)
        XCTAssertFalse(renewed.events.contains(where: isDaily))
        XCTAssertEqual(
            renewed.newBaselines[key],
            DailyBaseline(day: today, usedPercent: 35, resetsAt: renewedReset))
    }

    func testDailyDisabledClearsBaselinesAndSameDayReenableStartsAtCurrentValue() {
        let key = "codex|weekly|weeklyAll"
        let today = dayString(now)
        let snapshot = usageSnapshot(windows: [window(used: 50)])
        let oldBaseline = DailyBaseline(day: today, usedPercent: 10, resetsAt: nil)
        let off = evaluate(
            snapshot: snapshot,
            baselines: [key: oldBaseline],
            settings: NotificationSettings(enabled: true, dailyEnabled: false))

        XCTAssertTrue(off.events.isEmpty)
        XCTAssertTrue(off.newBaselines.isEmpty)

        let onSettings = NotificationSettings(
            enabled: true,
            usageThreshold: 95,
            dailyEnabled: true,
            dailyThreshold: 20)
        let on = evaluate(
            snapshot: snapshot,
            state: off.newState,
            baselines: off.newBaselines,
            settings: onSettings)
        XCTAssertFalse(on.events.contains(where: isDaily))
        XCTAssertEqual(on.newBaselines[key]?.usedPercent, 50)
    }

    func testDailyDisabledClearsOnlyCurrentProviderBaselines() {
        let codexKey = "codex|weekly|weeklyAll"
        let claudeKey = "claude|weekly|weeklyAll"
        let baseline = DailyBaseline(
            day: dayString(now),
            usedPercent: 10,
            resetsAt: nil)

        let result = evaluate(
            snapshot: usageSnapshot(windows: [window(used: 50)]),
            baselines: [codexKey: baseline, claudeKey: baseline],
            settings: NotificationSettings(enabled: true, dailyEnabled: false))

        XCTAssertNil(result.newBaselines[codexKey])
        XCTAssertEqual(result.newBaselines[claudeKey], baseline)
    }

    func testDailyOnlyEvaluatesWeeklyWindows() {
        let settings = NotificationSettings(
            enabled: true,
            usageThreshold: 95,
            dailyEnabled: true,
            dailyThreshold: 5)
        let result = evaluate(
            snapshot: usageSnapshot(windows: [
                window(scope: .session, used: 50, kind: .session),
                window(
                    id: "other",
                    scope: .other("other"),
                    used: 50,
                    kind: .other(minutes: 90)),
                window(id: "unknown", used: 50, kind: nil),
            ]),
            settings: settings)

        XCTAssertTrue(result.newBaselines.isEmpty)
        XCTAssertFalse(result.events.contains(where: isDaily))
    }

    func testStateKeyCollisionUsesHighestUsedPercentOnly() {
        let result = evaluate(snapshot: usageSnapshot(windows: [
            window(id: "low", used: 70, label: "Low"),
            window(id: "high", used: 90, label: "High"),
        ]))

        let thresholdEvents = result.events.filter(isThreshold)
        XCTAssertEqual(thresholdEvents.count, 1)
        guard case .thresholdExceeded(_, _, let label, let used, _, _) = thresholdEvents[0]
        else { return XCTFail("thresholdExceeded が必要") }
        XCTAssertEqual(label, "High")
        XCTAssertEqual(used, 90)
    }

    func testLogicalStateKeySurvivesWindowIDAndOrderChanges() {
        let first = evaluate(snapshot: usageSnapshot(windows: [
            window(id: "old-position", used: 85),
            window(
                id: "model-old",
                scope: .model(id: "model", displayName: "Model"),
                used: 20,
                label: "Model"),
        ]))
        let reordered = usageSnapshot(windows: [
            window(
                id: "model-new",
                scope: .model(id: "model", displayName: "Model"),
                used: 20,
                label: "Model"),
            window(id: "new-position", used: 90),
        ])

        XCTAssertTrue(evaluate(snapshot: reordered, state: first.newState).events.isEmpty)
    }

    func testCleanupRemovesMissingCurrentProviderKeysAndPreservesOtherProvider() {
        let kept = "codex|weekly|weeklyAll"
        let removed = "codex|weekly|gone"
        let otherProvider = "claude|weekly|weeklyAll"
        let mark = NotificationState.FiredMark(firedAt: now, basisResetsAt: nil)
        let state = NotificationState(windows: [
            kept: .init(threshold: mark),
            removed: .init(threshold: mark),
            otherProvider: .init(threshold: mark),
        ])
        let baseline = DailyBaseline(day: dayString(now), usedPercent: 10, resetsAt: nil)
        let result = evaluate(
            snapshot: usageSnapshot(windows: [window(used: 20)]),
            state: state,
            baselines: [kept: baseline, removed: baseline, otherProvider: baseline],
            settings: NotificationSettings(
                enabled: true,
                usageThreshold: 95,
                dailyEnabled: true,
                dailyThreshold: 50))

        XCTAssertNotNil(result.newState.windows[kept])
        XCTAssertNil(result.newState.windows[removed])
        XCTAssertNotNil(result.newState.windows[otherProvider])
        XCTAssertNotNil(result.newBaselines[kept])
        XCTAssertNil(result.newBaselines[removed])
        XCTAssertNotNil(result.newBaselines[otherProvider])
    }

    func testRaisedThresholdRefiresWithinSameWindow() {
        let basis = now.addingTimeInterval(3600)
        let key = "codex|weekly|weeklyAll"
        let state = NotificationState(windows: [
            key: .init(threshold: .init(firedAt: now, basisResetsAt: basis, basisThreshold: 80)),
        ])
        let snapshot = usageSnapshot(windows: [window(used: 92, resetsAt: basis)])

        let result = evaluate(
            snapshot: snapshot,
            state: state,
            settings: NotificationSettings(enabled: true, usageThreshold: 90))

        XCTAssertTrue(result.events.contains { if case .thresholdExceeded = $0 { true } else { false } })
        XCTAssertEqual(result.newState.windows[key]?.threshold?.basisThreshold, 90)
    }

    func testLoweredThresholdRefiresWithinSameWindow() {
        let basis = now.addingTimeInterval(3600)
        let key = "codex|weekly|weeklyAll"
        let state = NotificationState(windows: [
            key: .init(threshold: .init(firedAt: now, basisResetsAt: basis, basisThreshold: 90)),
        ])
        let snapshot = usageSnapshot(windows: [window(used: 85, resetsAt: basis)])

        let result = evaluate(
            snapshot: snapshot,
            state: state,
            settings: NotificationSettings(enabled: true, usageThreshold: 80))

        XCTAssertTrue(result.events.contains { if case .thresholdExceeded = $0 { true } else { false } })
        XCTAssertEqual(result.newState.windows[key]?.threshold?.basisThreshold, 80)
    }

    func testUnchangedThresholdDoesNotRefireWithinSameWindow() {
        let basis = now.addingTimeInterval(3600)
        let key = "codex|weekly|weeklyAll"
        let state = NotificationState(windows: [
            key: .init(threshold: .init(firedAt: now, basisResetsAt: basis, basisThreshold: 80)),
        ])
        let snapshot = usageSnapshot(windows: [window(used: 92, resetsAt: basis)])

        let result = evaluate(
            snapshot: snapshot,
            state: state,
            settings: NotificationSettings(enabled: true, usageThreshold: 80))

        XCTAssertFalse(result.events.contains { if case .thresholdExceeded = $0 { true } else { false } })
    }

    func testRefireHappensOnlyOncePerThresholdChange() {
        let basis = now.addingTimeInterval(3600)
        let state = NotificationState(windows: [
            "codex|weekly|weeklyAll": .init(
                threshold: .init(firedAt: now, basisResetsAt: basis, basisThreshold: 80)),
        ])
        let snapshot = usageSnapshot(windows: [window(used: 92, resetsAt: basis)])
        let settings = NotificationSettings(enabled: true, usageThreshold: 90)

        let first = evaluate(snapshot: snapshot, state: state, settings: settings)
        let second = evaluate(snapshot: snapshot, state: first.newState, settings: settings)

        XCTAssertTrue(first.events.contains { if case .thresholdExceeded = $0 { true } else { false } })
        XCTAssertFalse(second.events.contains { if case .thresholdExceeded = $0 { true } else { false } })
    }

    func testLegacyMarkWithoutThresholdDoesNotRefire() {
        let basis = now.addingTimeInterval(3600)
        let state = NotificationState(windows: [
            "codex|weekly|weeklyAll": .init(threshold: .init(firedAt: now, basisResetsAt: basis)),
        ])
        let snapshot = usageSnapshot(windows: [window(used: 92, resetsAt: basis)])

        let result = evaluate(
            snapshot: snapshot,
            state: state,
            settings: NotificationSettings(enabled: true, usageThreshold: 90))

        XCTAssertFalse(result.events.contains { if case .thresholdExceeded = $0 { true } else { false } })
    }

    func testDifferentWindowFiresRegardlessOfThreshold() {
        let oldBasis = now.addingTimeInterval(3600)
        let newBasis = now.addingTimeInterval(100_000)
        let state = NotificationState(windows: [
            "codex|weekly|weeklyAll": .init(
                threshold: .init(firedAt: now, basisResetsAt: oldBasis, basisThreshold: 80)),
        ])
        let snapshot = usageSnapshot(windows: [window(used: 92, resetsAt: newBasis)])

        let result = evaluate(
            snapshot: snapshot,
            state: state,
            settings: NotificationSettings(enabled: true, usageThreshold: 80))

        XCTAssertTrue(result.events.contains { if case .thresholdExceeded = $0 { true } else { false } })
    }

    func testThresholdRoundTripFiresOncePerChange() {
        let basis = now.addingTimeInterval(3600)
        let snapshot = usageSnapshot(windows: [window(used: 92, resetsAt: basis)])
        let isThreshold: (NotificationEvent) -> Bool = {
            if case .thresholdExceeded = $0 { true } else { false }
        }

        let first = evaluate(
            snapshot: snapshot,
            settings: NotificationSettings(enabled: true, usageThreshold: 80))
        let raised = evaluate(
            snapshot: snapshot, state: first.newState,
            settings: NotificationSettings(enabled: true, usageThreshold: 90))
        let lowered = evaluate(
            snapshot: snapshot, state: raised.newState,
            settings: NotificationSettings(enabled: true, usageThreshold: 80))

        XCTAssertTrue(first.events.contains(where: isThreshold))
        XCTAssertTrue(raised.events.contains(where: isThreshold))
        XCTAssertTrue(lowered.events.contains(where: isThreshold))
        XCTAssertEqual(raised.events.filter(isThreshold).count, 1)
        XCTAssertEqual(lowered.events.filter(isThreshold).count, 1)
        XCTAssertEqual(
            raised.events.filter(isThreshold).count
                + lowered.events.filter(isThreshold).count,
            2)
    }

    func testThresholdRoundTripDoesNotFireWhenUsageStaysBelowRaisedThreshold() {
        let basis = now.addingTimeInterval(3600)
        let snapshot = usageSnapshot(windows: [window(used: 85, resetsAt: basis)])
        let isThreshold: (NotificationEvent) -> Bool = {
            if case .thresholdExceeded = $0 { true } else { false }
        }

        let first = evaluate(
            snapshot: snapshot,
            settings: NotificationSettings(enabled: true, usageThreshold: 80))
        let raised = evaluate(
            snapshot: snapshot, state: first.newState,
            settings: NotificationSettings(enabled: true, usageThreshold: 90))
        let lowered = evaluate(
            snapshot: snapshot, state: raised.newState,
            settings: NotificationSettings(enabled: true, usageThreshold: 80))

        XCTAssertTrue(first.events.contains(where: isThreshold))
        XCTAssertFalse(raised.events.contains(where: isThreshold))
        XCTAssertFalse(lowered.events.contains(where: isThreshold))
    }

    func testNilResetsAtDoesNotRefireOnThresholdChange() {
        let state = NotificationState(windows: [
            "codex|weekly|weeklyAll": .init(
                threshold: .init(firedAt: now, basisResetsAt: nil, basisThreshold: 80)),
        ])
        let snapshot = usageSnapshot(windows: [window(used: 92, resetsAt: nil)])

        let result = evaluate(
            snapshot: snapshot,
            state: state,
            settings: NotificationSettings(enabled: true, usageThreshold: 90))

        XCTAssertFalse(result.events.contains { if case .thresholdExceeded = $0 { true } else { false } })
    }

    func testLimitReachedRecordsThresholdOnThresholdMark() {
        let basis = now.addingTimeInterval(3600)
        let key = "codex|weekly|weeklyAll"
        let snapshot = usageSnapshot(windows: [window(used: 100, resetsAt: basis)])

        let result = evaluate(
            snapshot: snapshot,
            settings: NotificationSettings(enabled: true, usageThreshold: 80))

        XCTAssertEqual(result.newState.windows[key]?.threshold?.basisThreshold, 80)
        XCTAssertNil(result.newState.windows[key]?.limitReached?.basisThreshold)
    }

    func testRefiresAfterRecoveryWhenThresholdLowered() {
        let basis = now.addingTimeInterval(3600)
        let key = "codex|weekly|weeklyAll"
        let isThreshold: (NotificationEvent) -> Bool = {
            if case .thresholdExceeded = $0 { true } else { false }
        }

        let reached = evaluate(
            snapshot: usageSnapshot(windows: [window(used: 100, resetsAt: basis)]),
            settings: NotificationSettings(enabled: true, usageThreshold: 90))
        let recovered = evaluate(
            snapshot: usageSnapshot(windows: [window(used: 85, resetsAt: basis)]),
            state: reached.newState,
            settings: NotificationSettings(enabled: true, usageThreshold: 90))
        let lowered = evaluate(
            snapshot: usageSnapshot(windows: [window(used: 85, resetsAt: basis)]),
            state: recovered.newState,
            settings: NotificationSettings(enabled: true, usageThreshold: 80))

        XCTAssertEqual(recovered.events.filter(isRecovered).count, 1)
        XCTAssertNil(recovered.newState.windows[key]?.limitReached)
        XCTAssertTrue(lowered.events.contains(where: isThreshold))
        XCTAssertEqual(lowered.newState.windows[key]?.threshold?.basisThreshold, 80)
    }

    func testPaceDangerUnaffectedByLegacyMarkWithNilBasisResetsAt() {
        let state = NotificationState(windows: [
            "codex|session|session": .init(paceDanger: .init(firedAt: now, basisResetsAt: nil)),
        ])
        let snapshot = usageSnapshot(windows: [
            window(scope: .session, used: 90, kind: .session,
                   resetsAt: now.addingTimeInterval(3600), label: "Session"),
        ])

        let result = evaluate(
            snapshot: snapshot, state: state,
            settings: NotificationSettings(enabled: true, usageThreshold: 95))

        XCTAssertTrue(result.events.contains { if case .paceDanger = $0 { true } else { false } })
    }

    func testPaceDangerDoesNotRefireOnThresholdChange() {
        let basis = now.addingTimeInterval(3600)
        let snapshot = usageSnapshot(windows: [
            window(scope: .session, used: 90, kind: .session, resetsAt: basis, label: "Session"),
        ])
        let isPace: (NotificationEvent) -> Bool = {
            if case .paceDanger = $0 { true } else { false }
        }

        let first = evaluate(
            snapshot: snapshot,
            settings: NotificationSettings(enabled: true, usageThreshold: 95))
        let changed = evaluate(
            snapshot: snapshot, state: first.newState,
            settings: NotificationSettings(enabled: true, usageThreshold: 99))

        XCTAssertTrue(first.events.contains(where: isPace))
        XCTAssertFalse(changed.events.contains(where: isPace))
        XCTAssertNil(changed.newState.windows["codex|session|session"]?.paceDanger?.basisThreshold)
    }

    func testDailyThresholdChangeRefiresWithinSameDay() {
        let basis = now.addingTimeInterval(3600)
        let key = "codex|weekly|weeklyAll"
        let today = "2027-01-15"
        let dailyNow = dateFor(day: today)
        let state = NotificationState(windows: [
            key: .init(dailyFiredOn: today, dailyBasisThreshold: 20),
        ])
        let baselines = [key: DailyBaseline(day: today, usedPercent: 10, resetsAt: basis)]
        let snapshot = UsageSnapshot(
            provider: .codex,
            windows: [window(used: 45, resetsAt: basis)],
            fetchedAt: dailyNow,
            source: .codexAppServer)

        let result = NotificationRuleEngine.evaluate(
            snapshot: snapshot,
            freshness: .fresh,
            state: state,
            baselines: baselines,
            settings: NotificationSettings(enabled: true, dailyEnabled: true, dailyThreshold: 30),
            now: dailyNow,
            calendar: calendar)

        XCTAssertTrue(result.events.contains { if case .dailyExceeded = $0 { true } else { false } })
        XCTAssertEqual(result.newState.windows[key]?.dailyBasisThreshold, 30)
    }

    func testDailyUnchangedThresholdDoesNotRefireWithinSameDay() {
        let basis = now.addingTimeInterval(3600)
        let key = "codex|weekly|weeklyAll"
        let today = "2027-01-15"
        let dailyNow = dateFor(day: today)
        let state = NotificationState(windows: [
            key: .init(dailyFiredOn: today, dailyBasisThreshold: 20),
        ])
        let baselines = [key: DailyBaseline(day: today, usedPercent: 10, resetsAt: basis)]
        let snapshot = UsageSnapshot(
            provider: .codex,
            windows: [window(used: 45, resetsAt: basis)],
            fetchedAt: dailyNow,
            source: .codexAppServer)

        let result = NotificationRuleEngine.evaluate(
            snapshot: snapshot,
            freshness: .fresh,
            state: state,
            baselines: baselines,
            settings: NotificationSettings(enabled: true, dailyEnabled: true, dailyThreshold: 20),
            now: dailyNow,
            calendar: calendar)

        XCTAssertFalse(result.events.contains { if case .dailyExceeded = $0 { true } else { false } })
    }

    func testLegacyDailyStateWithoutThresholdDoesNotRefire() {
        let basis = now.addingTimeInterval(3600)
        let key = "codex|weekly|weeklyAll"
        let today = "2027-01-15"
        let dailyNow = dateFor(day: today)
        // 旧形式: dailyBasisThreshold なし
        let state = NotificationState(windows: [key: .init(dailyFiredOn: today)])
        let baselines = [key: DailyBaseline(day: today, usedPercent: 10, resetsAt: basis)]
        let snapshot = UsageSnapshot(
            provider: .codex,
            windows: [window(used: 45, resetsAt: basis)],
            fetchedAt: dailyNow,
            source: .codexAppServer)

        let result = NotificationRuleEngine.evaluate(
            snapshot: snapshot,
            freshness: .fresh,
            state: state,
            baselines: baselines,
            settings: NotificationSettings(enabled: true, dailyEnabled: true, dailyThreshold: 30),
            now: dailyNow,
            calendar: calendar)

        XCTAssertFalse(result.events.contains { if case .dailyExceeded = $0 { true } else { false } })
    }

    func testDailyFirstFireRecordsThreshold() {
        let basis = now.addingTimeInterval(3600)
        let key = "codex|weekly|weeklyAll"
        let today = "2027-01-15"
        let dailyNow = dateFor(day: today)
        let baselines = [key: DailyBaseline(day: today, usedPercent: 10, resetsAt: basis)]
        let snapshot = UsageSnapshot(
            provider: .codex,
            windows: [window(used: 45, resetsAt: basis)],
            fetchedAt: dailyNow,
            source: .codexAppServer)

        let result = NotificationRuleEngine.evaluate(
            snapshot: snapshot,
            freshness: .fresh,
            state: NotificationState(),
            baselines: baselines,
            settings: NotificationSettings(enabled: true, dailyEnabled: true, dailyThreshold: 20),
            now: dailyNow,
            calendar: calendar)

        XCTAssertTrue(result.events.contains { if case .dailyExceeded = $0 { true } else { false } })
        XCTAssertEqual(result.newState.windows[key]?.dailyBasisThreshold, 20)
    }

    func testDailyFiresOnNewDayAndUpdatesThreshold() {
        // 日付ロールオーバー経路（dailyFiredOn == 前日・閾値は変更なし）。
        // 発火条件を「thresholdChanged || dailyFiredOn == nil」と書く誤実装だと
        // 初回発火テストは通るが翌日以降の日次通知が永久に出なくなる。
        let key = "codex|weekly|weeklyAll"
        let yesterday = "2027-01-14"
        let today = "2027-01-15"
        let dailyNow = dateFor(day: today)
        let basis = dailyNow.addingTimeInterval(6 * 86400)
        let state = NotificationState(windows: [
            key: .init(dailyFiredOn: yesterday, dailyBasisThreshold: 20),
        ])
        let baselines = [key: DailyBaseline(day: today, usedPercent: 10, resetsAt: basis)]
        let snapshot = UsageSnapshot(
            provider: .codex,
            windows: [window(used: 45, resetsAt: basis)],
            fetchedAt: dailyNow,
            source: .codexAppServer)

        let result = NotificationRuleEngine.evaluate(
            snapshot: snapshot,
            freshness: .fresh,
            state: state,
            baselines: baselines,
            settings: NotificationSettings(enabled: true, dailyEnabled: true, dailyThreshold: 20),
            now: dailyNow,
            calendar: calendar)

        XCTAssertTrue(result.events.contains { if case .dailyExceeded = $0 { true } else { false } })
        XCTAssertEqual(result.newState.windows[key]?.dailyFiredOn, today)
        XCTAssertEqual(result.newState.windows[key]?.dailyBasisThreshold, 20)
    }

    func testDailyBasisThresholdSurvivesFlagCleanup() {
        // isEmpty へ dailyBasisThreshold を含めないと、掃除で状態が黙って消える
        let key = "codex|weekly|weeklyAll"
        let state = NotificationState(windows: [key: .init(dailyBasisThreshold: 20)])
        // 何も発火しない条件（used 20 < 既定閾値 80・dailyEnabled は既定 false）
        let snapshot = usageSnapshot(windows: [window(used: 20, resetsAt: nil)])

        let result = evaluate(snapshot: snapshot, state: state)

        XCTAssertEqual(result.newState.windows[key]?.dailyBasisThreshold, 20)
    }

    private func usageSnapshot(
        provider: ProviderID = .codex,
        windows: [RateLimitWindow]
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            windows: windows,
            fetchedAt: now,
            source: provider == .codex ? .codexAppServer : .claudeOAuth)
    }

    private func evaluate(
        snapshot: UsageSnapshot,
        freshness: Freshness = .fresh,
        state: NotificationState = NotificationState(),
        baselines: [String: DailyBaseline] = [:],
        settings: NotificationSettings = NotificationSettings(enabled: true)
    ) -> NotificationRuleEngine.Evaluation {
        NotificationRuleEngine.evaluate(
            snapshot: snapshot,
            freshness: freshness,
            state: state,
            baselines: baselines,
            settings: settings,
            now: now,
            calendar: calendar)
    }

    private func dayString(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    private func dateFor(day: String) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        return calendar.date(from: components)!
    }

    private func isThreshold(_ event: NotificationEvent) -> Bool {
        if case .thresholdExceeded = event { return true }
        return false
    }

    private func isLimitReached(_ event: NotificationEvent) -> Bool {
        if case .limitReached = event { return true }
        return false
    }

    private func isRecovered(_ event: NotificationEvent) -> Bool {
        if case .recovered = event { return true }
        return false
    }

    private func isDaily(_ event: NotificationEvent) -> Bool {
        if case .dailyExceeded = event { return true }
        return false
    }
}
