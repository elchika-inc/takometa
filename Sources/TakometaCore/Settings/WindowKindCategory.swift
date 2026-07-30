public enum WindowKindCategory: String, Codable, Sendable, Hashable, CaseIterable {
    case session
    case weekly
    case model

    /// 既定順の正本（N-4）。allCases を順序の意味で使わない。
    public static let defaultOrder: [WindowKindCategory] = [.session, .weekly, .model]

    /// 未知値の除去・重複除去・欠落分の既定順補完（N-5）。
    public static func normalizedOrder(_ raw: [String]) -> [WindowKindCategory] {
        var seen = Set<WindowKindCategory>()
        var result: [WindowKindCategory] = []
        for value in raw {
            guard let category = WindowKindCategory(rawValue: value),
                  seen.insert(category).inserted
            else { continue }
            result.append(category)
        }
        for category in defaultOrder where seen.insert(category).inserted {
            result.append(category)
        }
        return result
    }
}

public func windowKindCategory(for scope: RateLimitScope) -> WindowKindCategory {
    switch scope {
    case .session: .session
    case .weeklyAll: .weekly
    case .model, .other: .model
    }
}

public enum ObservedWindowKinds {
    public static func observed(in windows: [RateLimitWindow]) -> Set<WindowKindCategory> {
        Set(windows.map { windowKindCategory(for: $0.scope) })
    }
}

public enum WindowKindRowRules {
    public static func visibleKinds(
        observed: Set<WindowKindCategory>
    ) -> Set<WindowKindCategory> {
        observed.isEmpty ? Set(WindowKindCategory.allCases) : observed
    }

    public static func isToggleDisabled(
        for kind: WindowKindCategory,
        visibleKinds: Set<WindowKindCategory>,
        settings: ProviderSettings
    ) -> Bool {
        guard visibleKinds.contains(kind), settings.isShown(kind) else { return false }
        return visibleKinds.filter(settings.isShown).count == 1
    }
}

public enum WindowKindOrdering {
    /// 枠種別順で安定ソートする（N-8）。order に無い枠種別は入力順を保って末尾へ回す。
    public static func sorted<T>(
        _ items: [T],
        order: [WindowKindCategory],
        category: (T) -> WindowKindCategory
    ) -> [T] {
        var rank: [WindowKindCategory: Int] = [:]
        for (index, kind) in order.enumerated() where rank[kind] == nil {
            rank[kind] = index
        }
        let fallback = order.count
        return items.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = rank[category(lhs.element)] ?? fallback
                let rhsRank = rank[category(rhs.element)] ?? fallback
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// 表示中配列の並べ替えを完全順序へ反映する（N-13）。
    /// full 内で表示中の枠種別が占める添字位置へ、並べ替え後の順を先頭から埋め戻す。
    public static func applyingVisibleReorder(
        full: [WindowKindCategory],
        visibleReordered: [WindowKindCategory]
    ) -> [WindowKindCategory] {
        var seen = Set<WindowKindCategory>()
        let sanitized = visibleReordered.filter {
            full.contains($0) && seen.insert($0).inserted
        }
        let visibleSet = Set(sanitized)
        var replacements = sanitized.makeIterator()
        return full.map { category in
            guard visibleSet.contains(category) else { return category }
            return replacements.next() ?? category
        }
    }
}
