import SwiftUI
import TakometaCore

/// パネル用のカード表示（設計書 §2）。「眺める用」なのでリセット時刻・ペース・
/// 操作ボタンは載せない。詳細はポップオーバー（ProviderPopoverView）が担当する。
struct ProviderCardsView: View {
    let store: UsageStore
    let settingsStore: SettingsStore

    var body: some View {
        let _ = store.revision
        HStack(alignment: .top, spacing: 12) {
            ForEach(cards, id: \.name) { card in
                ProviderCardView(card: card)
            }
        }
        .padding(16)
    }

    private var cards: [ProviderCard] {
        MenuBarLabelFormatter.formatProviderCards(
            codex: input(for: .codex),
            claude: input(for: .claude),
            filter: SettingsSupply.displayFilter(from: settingsStore.providers),
            now: Date(),
            order: settingsStore.providerOrder.compactMap(ProviderID.init(rawValue:)),
            kindOrders: SettingsSupply.windowKindOrders(from: settingsStore.providers))
    }

    private func input(
        for provider: ProviderID
    ) -> (windows: [RateLimitWindow], freshness: Freshness) {
        menuBarInput(from: store.states[provider] ?? UsageStore.ProviderState())
    }
}

/// カード1枚。ProviderCard だけを入力に取り、UsageStore を知らない
/// （将来 WidgetKit の timeline provider からも使うため。設計書 §4）
struct ProviderCardView: View {
    let card: ProviderCard

    var body: some View {
        VStack(spacing: 8) {
            ring
                .frame(width: 72, height: 72)
            HStack(spacing: 4) {
                Text(card.name)
                    .font(.headline)
                if card.isStale {
                    Text("⏱")
                        .font(.caption)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(card.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color(for: row.style))
                            .frame(width: 6, height: 6)
                        Text(row.label)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text("\(row.percent)%")
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
        .padding(14)
        .frame(width: 150)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor)))
        // stale は減光で示す。メニューバーアイコンの 0.45 より弱いのは、
        // カードは面積が大きく 0.45 では内訳が読めなくなるため（設計書 §3）
        .opacity(card.isStale ? 0.6 : 1)
    }

    @ViewBuilder
    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 6)
            switch card.ring {
            case .gauge(let percent, let style):
                Circle()
                    .trim(from: 0, to: min(Double(percent), 100) / 100)
                    .stroke(
                        color(for: style),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(percent)%")
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
            case .unavailable:
                Text("--")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            case .authenticationRequired:
                Image(systemName: "lock")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func color(for style: SegmentStyle) -> Color {
        switch style {
        case .normal: return .primary
        case .warning: return Color(nsColor: .systemOrange)
        case .critical: return Color(nsColor: .systemRed)
        }
    }
}

#Preview("カード各状態") {
    HStack(alignment: .top, spacing: 12) {
        ProviderCardView(card: ProviderCard(
            name: "Claude",
            ring: .gauge(percent: 32, style: .normal),
            rows: [
                ProviderCard.Row(label: "5h", percent: 32, style: .normal),
                ProviderCard.Row(label: "1w", percent: 17, style: .normal),
                ProviderCard.Row(label: "Fable", percent: 10, style: .normal),
            ],
            isStale: false))
        ProviderCardView(card: ProviderCard(
            name: "Codex",
            ring: .gauge(percent: 53, style: .warning),
            rows: [ProviderCard.Row(label: "1w", percent: 53, style: .warning)],
            isStale: true))
        ProviderCardView(card: ProviderCard(
            name: "Claude", ring: .authenticationRequired, rows: [], isStale: false))
        ProviderCardView(card: ProviderCard(
            name: "Codex", ring: .unavailable, rows: [], isStale: false))
    }
    .padding()
}
