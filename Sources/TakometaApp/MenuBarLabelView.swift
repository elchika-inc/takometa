import AppKit
import SwiftUI
import TakometaCore

struct MenuBarLabelView: View {
    let store: UsageStore
    let settingsStore: SettingsStore
    var codexStateOverride: UsageStore.ProviderState?
    var claudeStateOverride: UsageStore.ProviderState?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    init(
        store: UsageStore,
        settingsStore: SettingsStore,
        codexStateOverride: UsageStore.ProviderState? = nil,
        claudeStateOverride: UsageStore.ProviderState? = nil
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.codexStateOverride = codexStateOverride
        self.claudeStateOverride = claudeStateOverride
    }

    @ViewBuilder
    var body: some View {
        if settingsStore.displayMode == .compact {
            let icons = formattedIcons
            if icons.icons.isEmpty {
                EmptyMenuBarLabelView()
            } else {
                Image(nsImage: renderedImage(for: MenuBarIconsView(icons: icons)))
                    .renderingMode(.original)
                    .accessibilityLabel(icons.accessibilityText)
            }
        } else if settingsStore.menuBarLineCount == .two {
            let columns = formattedColumns
            if columns.groups.isEmpty {
                EmptyMenuBarLabelView()
            } else {
                Image(nsImage: renderedImage(for: MenuBarColumnsView(columns: columns)))
                    .renderingMode(.original)
                    .accessibilityLabel(columns.accessibilityText)
            }
        } else {
            let label = formattedLabel
            if label.segments.isEmpty {
                EmptyMenuBarLabelView()
            } else {
                Image(nsImage: renderedImage(for: MenuBarSegmentView(label: label)))
                    .renderingMode(.original)
                    .accessibilityLabel(label.text)
            }
        }
    }

    private var formattedLabel: MenuBarLabel {
        _ = store.revision
        return MenuBarLabelFormatter.formatCombined(
            codex: input(for: .codex),
            claude: input(for: .claude),
            filter: SettingsSupply.displayFilter(from: settingsStore.providers),
            now: Date(),
            mode: settingsStore.displayMode,
            order: settingsStore.providerOrder.compactMap(ProviderID.init(rawValue:)),
            labels: SettingsSupply.providerLabels(from: settingsStore.providers),
            kindOrders: SettingsSupply.windowKindOrders(from: settingsStore.providers))
    }

    private var formattedIcons: MenuBarIcons {
        _ = store.revision
        return MenuBarLabelFormatter.formatCombinedIcons(
            codex: input(for: .codex),
            claude: input(for: .claude),
            filter: SettingsSupply.displayFilter(from: settingsStore.providers),
            now: Date(),
            order: settingsStore.providerOrder.compactMap(ProviderID.init(rawValue:)),
            labels: SettingsSupply.providerLabels(from: settingsStore.providers))
    }

    private var formattedColumns: MenuBarColumns {
        _ = store.revision
        return MenuBarLabelFormatter.formatCombinedColumns(
            codex: input(for: .codex),
            claude: input(for: .claude),
            filter: SettingsSupply.displayFilter(from: settingsStore.providers),
            now: Date(),
            mode: settingsStore.displayMode,
            order: settingsStore.providerOrder.compactMap(ProviderID.init(rawValue:)),
            labels: SettingsSupply.providerLabels(from: settingsStore.providers),
            kindOrders: SettingsSupply.windowKindOrders(from: settingsStore.providers))
    }

    private func input(
        for provider: ProviderID
    ) -> (windows: [RateLimitWindow], freshness: Freshness)? {
        let override = provider == .codex ? codexStateOverride : claudeStateOverride
        let state = override ?? store.states[provider] ?? UsageStore.ProviderState()
        return menuBarInput(from: state)
    }

    @MainActor
    private func renderedImage(for content: some View) -> NSImage {
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, colorScheme))
        renderer.scale = displayScale
        return renderer.nsImage ?? NSImage(size: NSSize(width: 1, height: 1))
    }
}

func menuBarInput(
    from state: UsageStore.ProviderState
) -> (windows: [RateLimitWindow], freshness: Freshness) {
    (state.snapshot?.windows ?? [], state.freshness)
}

private struct EmptyMenuBarLabelView: View {
    var body: some View {
        Image(systemName: "gauge.medium")
            .accessibilityLabel("Takometa（表示項目なし）")
    }
}

private struct MenuBarSegmentView: View {
    let label: MenuBarLabel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(label.segments.enumerated()), id: \.offset) { _, segment in
                Text(segment.text)
                    .foregroundStyle(color(for: segment.style))
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .fixedSize()
    }

    private func color(for style: SegmentStyle) -> Color {
        switch style {
        case .normal: return .primary
        case .warning: return Color(nsColor: .systemOrange)
        case .critical: return Color(nsColor: .systemRed)
        }
    }
}

private struct MenuBarIconsView: View {
    let icons: MenuBarIcons

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(icons.icons.enumerated()), id: \.offset) { _, icon in
                Image(systemName: symbolName(for: icon.glyph))
                    .foregroundStyle(color(for: icon))
                    // stale はマークを足さず不透明度で示す。Compact の存在理由が
                    // 幅なので、ここで幅を増やすと目的と矛盾する
                    .opacity(icon.isStale ? 0.45 : 1)
            }
        }
        .font(.system(size: 13))
        .fixedSize()
    }

    private func symbolName(for glyph: MenuBarIconGlyph) -> String {
        switch glyph {
        case .gauge(let level):
            switch level {
            case .zero: return "gauge.with.dots.needle.0percent"
            case .low: return "gauge.with.dots.needle.33percent"
            case .mid: return "gauge.with.dots.needle.50percent"
            case .high: return "gauge.with.dots.needle.67percent"
            case .max: return "gauge.with.dots.needle.100percent"
            }
        case .unavailable: return "questionmark.circle"
        case .authenticationRequired: return "lock.circle"
        }
    }

    private func color(for icon: MenuBarIcon) -> Color {
        switch icon.glyph {
        case .unavailable, .authenticationRequired:
            return .secondary
        case .gauge:
            switch icon.style {
            case .normal: return .primary
            case .warning: return Color(nsColor: .systemOrange)
            case .critical: return Color(nsColor: .systemRed)
            }
        }
    }
}

private struct MenuBarColumnsView: View {
    let columns: MenuBarColumns

    var body: some View {
        HStack(spacing: MenuBarColumnsMetrics.groupSpacing) {
            ForEach(Array(columns.groups.enumerated()), id: \.offset) { groupIndex, group in
                if groupIndex > 0 {
                    Rectangle()
                        .frame(
                            width: MenuBarColumnsMetrics.dividerWidth,
                            height: MenuBarColumnsMetrics.dividerHeight)
                        .opacity(0.25)
                }
                HStack(spacing: MenuBarColumnsMetrics.columnSpacing) {
                    ForEach(Array(group.enumerated()), id: \.offset) { _, column in
                        // 各行の高さをフォントサイズちょうどへ詰める。SwiftUI の Text は
                        // フォントサイズに対して余分な行高を持つため、詰めないと文字を
                        // 大きくできない（MenuBarColumnsMetrics のコメント参照）
                        VStack(spacing: 0) {
                            Text(column.title)
                                .font(.system(size: MenuBarColumnsMetrics.titleFontSize))
                                .foregroundStyle(.secondary)
                                .frame(height: MenuBarColumnsMetrics.titleFontSize)
                            Text(column.value)
                                .font(.system(
                                    size: MenuBarColumnsMetrics.valueFontSize,
                                    weight: .semibold).monospacedDigit())
                                .foregroundStyle(color(for: column.style))
                                .frame(height: MenuBarColumnsMetrics.valueFontSize)
                        }
                    }
                }
            }
        }
        .fixedSize()
    }

    private func color(for style: SegmentStyle) -> Color {
        switch style {
        case .normal: return .primary
        case .warning: return Color(nsColor: .systemOrange)
        case .critical: return Color(nsColor: .systemRed)
        }
    }
}

#Preview("表示項目なし - Light") {
    EmptyMenuBarLabelView()
        .padding(8)
        .background(.bar)
        .preferredColorScheme(.light)
}

#Preview("表示項目なし - Dark") {
    EmptyMenuBarLabelView()
        .padding(8)
        .background(.bar)
        .preferredColorScheme(.dark)
}

#Preview("アイコン表示 - 5段階") {
    MenuBarIconsView(icons: MenuBarIcons(icons: [
        MenuBarIcon(glyph: .gauge(.zero), style: .normal, isStale: false,
                    accessibilityText: "CX 週間枠 10%"),
        MenuBarIcon(glyph: .gauge(.low), style: .normal, isStale: false,
                    accessibilityText: "CX 週間枠 30%"),
        MenuBarIcon(glyph: .gauge(.mid), style: .normal, isStale: false,
                    accessibilityText: "CX 週間枠 50%"),
        MenuBarIcon(glyph: .gauge(.high), style: .warning, isStale: false,
                    accessibilityText: "CX 週間枠 70%"),
        MenuBarIcon(glyph: .gauge(.max), style: .critical, isStale: false,
                    accessibilityText: "CX 週間枠 95%"),
    ]))
    .padding(8)
    .background(.bar)
}

#Preview("アイコン表示 - 退化ケース") {
    MenuBarIconsView(icons: MenuBarIcons(icons: [
        MenuBarIcon(glyph: .gauge(.mid), style: .normal, isStale: true,
                    accessibilityText: "CX 週間枠 50%（更新が古い）"),
        MenuBarIcon(glyph: .unavailable, style: .normal, isStale: false,
                    accessibilityText: "CX 取得できません"),
        MenuBarIcon(glyph: .authenticationRequired, style: .normal, isStale: false,
                    accessibilityText: "CL 要認証"),
    ]))
    .padding(8)
    .background(.bar)
}
