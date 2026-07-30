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
        if settingsStore.menuBarLineCount == .two {
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
        guard let snapshot = state.snapshot else { return nil }
        return (snapshot.windows, state.freshness)
    }

    @MainActor
    private func renderedImage(for content: some View) -> NSImage {
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, colorScheme))
        renderer.scale = displayScale
        return renderer.nsImage ?? NSImage(size: NSSize(width: 1, height: 1))
    }
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
