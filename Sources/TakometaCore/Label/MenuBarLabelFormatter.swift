import Foundation

public enum DisplayMode: String, Sendable, CaseIterable {
    case full                          // "full" ─ 意味不変
    // 以下2つは rawValue が case 名と異なる。旧版の同名の値と意味がずれたため、
    // 永続化層で新旧を区別できるようにする（設計書 §5.2）。
    case balanced = "onePerProvider"   // 旧 "balanced"（モデル枠1個）とは別物
    case compact = "icon"              // 旧 "compact"（最逼迫1枠）とは別物

    /// 永続化された文字列からモードを復元する。
    /// 旧版の値（"compact" = 最逼迫1枠 / "balanced" = モデル枠1個）は
    /// 新しい体系へ1段繰り上げて解釈する（設計書 §5.2 の表）。
    public static func fromPersistedValue(_ raw: String?) -> DisplayMode {
        switch raw {
        case DisplayMode.full.rawValue: return .full
        case DisplayMode.balanced.rawValue: return .balanced
        case DisplayMode.compact.rawValue: return .compact
        case "compact": return .balanced   // 旧版
        case "balanced": return .full      // 旧版（設計書 §5.4）
        default: return .full
        }
    }
}

public struct ProviderDisplayFilter: Sendable, Equatable {
    public var show: Bool
    public var showSession: Bool
    public var showWeekly: Bool
    public var showModel: Bool

    public init(
        show: Bool = true,
        showSession: Bool = true,
        showWeekly: Bool = true,
        showModel: Bool = true
    ) {
        self.show = show
        self.showSession = showSession
        self.showWeekly = showWeekly
        self.showModel = showModel
    }
}

public struct DisplayFilter: Sendable, Equatable {
    public var codex: ProviderDisplayFilter
    public var claude: ProviderDisplayFilter

    public init(
        codex: ProviderDisplayFilter = .init(),
        claude: ProviderDisplayFilter = .init()
    ) {
        self.codex = codex
        self.claude = claude
    }
}

public enum SegmentStyle: Sendable, Equatable {
    case normal
    case warning
    case critical
}

public struct LabelSegment: Sendable, Equatable {
    public let text: String
    public let style: SegmentStyle

    public init(text: String, style: SegmentStyle) {
        self.text = text
        self.style = style
    }
}

public struct MenuBarLabel: Sendable, Equatable {
    public let segments: [LabelSegment]

    public init(segments: [LabelSegment]) {
        self.segments = segments
    }

    public var text: String { segments.map(\.text).joined() }
}

public enum MenuBarLabelFormatter {
    private struct SelectedWindow {
        let window: RateLimitWindow
        let fixedPrefix: String?
        let abbreviationSource: String?
    }

    private struct ResolvedProvider {
        let provider: ProviderID
        let windows: [RateLimitWindow]
        let freshness: Freshness
        let label: String
        let kindOrder: [WindowKindCategory]
    }

    private static func category(of selected: SelectedWindow) -> WindowKindCategory {
        windowKindCategory(for: selected.window.scope)
    }

    /// 枠種別列が既定順並びと一致しない場合のみ、session に H・weekly に W を上書きする（裁定2）。
    private static func applyMarkers(
        to sorted: [SelectedWindow],
        defaultSorted: [SelectedWindow]
    ) -> [SelectedWindow] {
        guard sorted.map(category(of:)) != defaultSorted.map(category(of:)) else { return sorted }
        return sorted.map { selected in
            switch category(of: selected) {
            case .session:
                return SelectedWindow(
                    window: selected.window, fixedPrefix: "H",
                    abbreviationSource: selected.abbreviationSource)
            case .weekly:
                return SelectedWindow(
                    window: selected.window, fixedPrefix: "W",
                    abbreviationSource: selected.abbreviationSource)
            case .model:
                return selected
            }
        }
    }

    private static func resolvedPrefix(provider: ProviderID, custom: String) -> String {
        let stripped = String(custom.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        })
        let trimmed = stripped.trimmingCharacters(in: .whitespaces)
        let clamped = String(trimmed.prefix(6))
        let base = clamped.isEmpty ? (provider == .codex ? "CX" : "CL") : clamped
        return base + " "
    }

    private static func resolveProviders(
        codex: (windows: [RateLimitWindow], freshness: Freshness)?,
        claude: (windows: [RateLimitWindow], freshness: Freshness)?,
        filter: DisplayFilter,
        order: [ProviderID],
        labels: [ProviderID: String],
        kindOrders: [ProviderID: [WindowKindCategory]]
    ) -> [ResolvedProvider] {
        var result: [ResolvedProvider] = []
        var seen = Set<ProviderID>()
        for provider in order where seen.insert(provider).inserted {
            let input: (windows: [RateLimitWindow], freshness: Freshness)
            let providerFilter: ProviderDisplayFilter
            switch provider {
            case .codex:
                input = codex ?? (windows: [], freshness: .unavailable)
                providerFilter = filter.codex
            case .claude:
                input = claude ?? (windows: [], freshness: .unavailable)
                providerFilter = filter.claude
            }
            guard providerFilter.show else { continue }
            result.append(ResolvedProvider(
                provider: provider,
                windows: filtered(input.windows, by: providerFilter),
                freshness: input.freshness,
                label: labels[provider] ?? "",
                kindOrder: kindOrders[provider] ?? WindowKindCategory.defaultOrder))
        }
        return result
    }

    public static func format(
        provider: ProviderID,
        windows: [RateLimitWindow],
        freshness: Freshness,
        now: Date,
        mode: DisplayMode,
        customPrefix: String = "",
        kindOrder: [WindowKindCategory] = WindowKindCategory.defaultOrder
    ) -> MenuBarLabel {
        let providerPrefix = resolvedPrefix(provider: provider, custom: customPrefix)
        if freshness == .unavailable {
            return MenuBarLabel(segments: [normal(providerPrefix + "--")])
        }

        let result = select(windows: windows, mode: mode)
        guard !result.windows.isEmpty else {
            var segments = [normal(providerPrefix + "--")]
            appendFreshnessMark(freshness, to: &segments)
            return MenuBarLabel(segments: segments)
        }

        let sortedWindows = WindowKindOrdering.sorted(
            result.windows, order: kindOrder, category: category(of:))
        let defaultSorted = WindowKindOrdering.sorted(
            result.windows, order: WindowKindCategory.defaultOrder, category: category(of:))
        let orderedWindows = applyMarkers(to: sortedWindows, defaultSorted: defaultSorted)

        let abbreviations = resolveAbbreviations(for: orderedWindows)
        var segments = [normal(providerPrefix)]
        for (index, selected) in orderedWindows.enumerated() {
            if index > 0 { segments.append(normal("|")) }
            let marker = selected.fixedPrefix ?? abbreviations[index] ?? ""
            if !marker.isEmpty { segments.append(normal(marker)) }
            segments.append(LabelSegment(
                text: String(Int(selected.window.usedPercent.rounded(.down))),
                style: style(for: selected.window, freshness: freshness, now: now)))
        }
        if result.overflow > 0 {
            segments.append(normal(" +\(result.overflow)"))
        }
        appendFreshnessMark(freshness, to: &segments)
        return MenuBarLabel(segments: segments)
    }

    public static func formatCombined(
        codex: (windows: [RateLimitWindow], freshness: Freshness)?,
        claude: (windows: [RateLimitWindow], freshness: Freshness)?,
        filter: DisplayFilter,
        now: Date,
        mode: DisplayMode,
        order: [ProviderID] = [.codex, .claude],
        labels: [ProviderID: String] = [:],
        kindOrders: [ProviderID: [WindowKindCategory]] = [:]
    ) -> MenuBarLabel {
        let resolved = resolveProviders(
            codex: codex, claude: claude, filter: filter,
            order: order, labels: labels, kindOrders: kindOrders)

        var segments: [LabelSegment] = []
        for item in resolved {
            if !segments.isEmpty { segments.append(normal("  ")) }
            segments.append(contentsOf: format(
                provider: item.provider,
                windows: item.windows,
                freshness: item.freshness,
                now: now,
                mode: mode,
                customPrefix: item.label,
                kindOrder: item.kindOrder).segments)
        }
        return MenuBarLabel(segments: segments)
    }

    public static func formatCombinedColumns(
        codex: (windows: [RateLimitWindow], freshness: Freshness)?,
        claude: (windows: [RateLimitWindow], freshness: Freshness)?,
        filter: DisplayFilter,
        now: Date,
        mode: DisplayMode,
        order: [ProviderID] = [.codex, .claude],
        labels: [ProviderID: String] = [:],
        kindOrders: [ProviderID: [WindowKindCategory]] = [:]
    ) -> MenuBarColumns {
        let resolved = resolveProviders(
            codex: codex, claude: claude, filter: filter,
            order: order, labels: labels, kindOrders: kindOrders)

        let groups = resolved.map { item in
            columnGroup(
                provider: item.provider,
                windows: item.windows,
                freshness: item.freshness,
                now: now,
                mode: mode,
                customPrefix: item.label,
                kindOrder: item.kindOrder)
        }
        return MenuBarColumns(groups: groups)
    }

    private static func columnGroup(
        provider: ProviderID,
        windows: [RateLimitWindow],
        freshness: Freshness,
        now: Date,
        mode: DisplayMode,
        customPrefix: String,
        kindOrder: [WindowKindCategory]
    ) -> [MenuBarColumn] {
        let labelColumn = MenuBarColumn(
            title: resolvedPrefixTitle(provider: provider, custom: customPrefix),
            value: " ",
            style: .normal)
        let dashColumn = MenuBarColumn(title: "--", value: " ", style: .normal)

        if freshness == .unavailable {
            return [labelColumn, dashColumn]
        }

        let result = select(windows: windows, mode: mode)
        guard !result.windows.isEmpty else {
            var group = [labelColumn, dashColumn]
            appendFreshnessColumn(freshness, to: &group)
            return group
        }

        // N-3: applyMarkers / resolveAbbreviations / fixedPrefix は使わない
        let sorted = WindowKindOrdering.sorted(
            result.windows, order: kindOrder, category: category(of:))
        let titles = columnTitles(for: sorted.map(\.window.scope))

        var group = [labelColumn]
        for (index, selected) in sorted.enumerated() {
            group.append(MenuBarColumn(
                title: titles[index],
                value: String(Int(selected.window.usedPercent.rounded(.down))),
                style: style(for: selected.window, freshness: freshness, now: now)))
        }
        if result.overflow > 0 {
            group.append(MenuBarColumn(title: "他", value: "+\(result.overflow)", style: .normal))
        }
        appendFreshnessColumn(freshness, to: &group)
        return group
    }

    /// 鮮度マーク列を末尾へ足す（overflow 列より後）。
    private static func appendFreshnessColumn(
        _ freshness: Freshness,
        to group: inout [MenuBarColumn]
    ) {
        switch freshness {
        case .stale:
            group.append(MenuBarColumn(title: " ", value: "⏱", style: .normal))
        case .authenticationRequired:
            group.append(MenuBarColumn(title: " ", value: "🔒", style: .normal))
        case .fresh, .unavailable:
            break
        }
    }

    /// 2行のラベル列用。既存 `resolvedPrefix` は末尾に空白を付けるため、それを除いた形で解決する。
    private static func resolvedPrefixTitle(provider: ProviderID, custom: String) -> String {
        let prefix = resolvedPrefix(provider: provider, custom: custom)
        return String(prefix.dropLast())   // resolvedPrefix は末尾に " " を付けて返す
    }

    /// 2行表示の上段（枠名）を解決する。衝突回避のため配列で受けて配列で返す。
    static func columnTitles(for scopes: [RateLimitScope]) -> [String] {
        let base = scopes.map { prefixTruncated(baseName(for: $0)) }

        // 同一の枠名が複数ある場合、9文字以上のために切り詰めた名前だけを中央省略へ切り替える（N-5）
        var counts: [String: Int] = [:]
        for title in base { counts[title, default: 0] += 1 }

        var result = base
        for (index, scope) in scopes.enumerated() {
            guard counts[base[index], default: 0] > 1 else { continue }
            let name = baseName(for: scope)
            guard name.count > 8 else { continue }   // 切り詰めが発生していない名前は据え置く
            result[index] = middleTruncated(name)
        }

        // 中央省略でも衝突するなら先頭切り詰めへ戻す
        var afterCounts: [String: Int] = [:]
        for title in result { afterCounts[title, default: 0] += 1 }
        for index in result.indices where afterCounts[result[index], default: 0] > 1 {
            result[index] = base[index]
        }
        return result
    }

    private static func baseName(for scope: RateLimitScope) -> String {
        switch scope {
        case .session: return "5h"
        case .weeklyAll: return "1w"
        case .model(_, let displayName): return displayName
        case .other(let raw): return raw
        }
    }

    /// 8文字を超える場合は先頭7文字 + … で全体8文字にする。空なら "?"。
    private static func prefixTruncated(_ name: String) -> String {
        guard !name.isEmpty else { return "?" }
        guard name.count > 8 else { return name }
        return String(name.prefix(7)) + "…"
    }

    /// 先頭3文字 + … + 末尾4文字で全体8文字にする。
    private static func middleTruncated(_ name: String) -> String {
        String(name.prefix(3)) + "…" + String(name.suffix(4))
    }

    private static func filtered(
        _ windows: [RateLimitWindow],
        by filter: ProviderDisplayFilter
    ) -> [RateLimitWindow] {
        windows.filter { window in
            switch windowKindCategory(for: window.scope) {
            case .session: return filter.showSession
            case .weekly: return filter.showWeekly
            case .model: return filter.showModel
            }
        }
    }

    private static func select(
        windows: [RateLimitWindow],
        mode: DisplayMode
    ) -> (windows: [SelectedWindow], overflow: Int) {
        let session = windows.filter { if case .session = $0.scope { true } else { false } }
            .sorted(by: rankedBefore).first
        let weekly = windows.filter { if case .weeklyAll = $0.scope { true } else { false } }
            .sorted(by: rankedBefore).first
        let nonBasic = windows.filter {
            switch $0.scope {
            case .model, .other: return true
            case .session, .weeklyAll: return false
            }
        }.sorted(by: rankedBefore)

        switch mode {
        case .full:
            let bothBasics = session != nil && weekly != nil
            var selected: [SelectedWindow] = []
            if let session {
                selected.append(SelectedWindow(
                    window: session, fixedPrefix: bothBasics ? "" : "H",
                    abbreviationSource: nil))
            }
            if let weekly {
                selected.append(SelectedWindow(
                    window: weekly, fixedPrefix: bothBasics ? "" : "W",
                    abbreviationSource: nil))
            }
            let limit = 2
            selected.append(contentsOf: nonBasic.prefix(limit).map {
                SelectedWindow(
                    window: $0, fixedPrefix: nil,
                    abbreviationSource: abbreviationSource(for: $0.scope))
            })
            return (selected, max(0, nonBasic.count - limit))

        case .balanced:
            guard let window = windows.sorted(by: rankedBefore).first else { return ([], 0) }
            switch window.scope {
            case .session:
                return ([SelectedWindow(
                    window: window, fixedPrefix: "H", abbreviationSource: nil)], 0)
            case .weeklyAll:
                return ([SelectedWindow(
                    window: window, fixedPrefix: "W", abbreviationSource: nil)], 0)
            case .model, .other:
                return ([SelectedWindow(
                    window: window, fixedPrefix: nil,
                    abbreviationSource: abbreviationSource(for: window.scope))], 0)
            }

        case .compact:
            // アイコン表示は select を通らない（formatCombinedIcons が直接ウィンドウを選ぶ）。
            // テキスト経路が .compact で呼ばれた場合は最も近い balanced として描画し、
            // 表示が空になるのを避ける。
            return select(windows: windows, mode: .balanced)
        }
    }

    private static func rankedBefore(_ lhs: RateLimitWindow, _ rhs: RateLimitWindow) -> Bool {
        if lhs.usedPercent != rhs.usedPercent { return lhs.usedPercent > rhs.usedPercent }
        switch (lhs.resetsAt, rhs.resetsAt) {
        case let (left?, right?) where left != right: return left < right
        case (nil, _?): return false
        case (_?, nil): return true
        default: return lhs.id < rhs.id
        }
    }

    private static func abbreviationSource(for scope: RateLimitScope) -> String {
        switch scope {
        case .model(_, let displayName): return displayName
        case .other(let raw): return raw
        case .session, .weeklyAll: return ""
        }
    }

    private static func resolveAbbreviations(for windows: [SelectedWindow]) -> [Int: String] {
        let sources = windows.map(\.abbreviationSource)
        var resolved: [Int: String] = [:]
        for (index, source) in sources.enumerated() {
            guard let source, !source.isEmpty else { continue }
            let sourceCharacters = Array(source)
            var length = 1
            for other in sources.compactMap({ $0 }) where
                !other.isEmpty && other.lowercased() != source.lowercased()
            {
                let common = zip(source.lowercased(), other.lowercased())
                    .prefix { $0 == $1 }.count
                length = max(length, min(sourceCharacters.count, common + 1))
            }
            let rawPrefix = String(sourceCharacters.prefix(length))
            resolved[index] = rawPrefix.prefix(1).uppercased() + rawPrefix.dropFirst()
        }
        return resolved
    }

    private static func style(
        for window: RateLimitWindow,
        freshness: Freshness,
        now: Date
    ) -> SegmentStyle {
        if window.usedPercent >= 100 {
            let valueIsExpired = (freshness == .stale || freshness == .authenticationRequired)
                && window.resetsAt.map { $0 <= now } == true
            return valueIsExpired ? .normal : .critical
        }
        if UsagePace.calculate(window: window, freshness: freshness, now: now)?.willLastToReset == false {
            return .warning
        }
        return .normal
    }

    private static func appendFreshnessMark(
        _ freshness: Freshness,
        to segments: inout [LabelSegment]
    ) {
        switch freshness {
        case .stale: segments.append(normal(" ⏱"))
        case .authenticationRequired: segments.append(normal(" 🔒"))
        case .fresh, .unavailable: break
        }
    }

    private static func normal(_ text: String) -> LabelSegment {
        LabelSegment(text: text, style: .normal)
    }
}
