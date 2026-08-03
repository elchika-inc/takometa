# Stats 風リングゲージカード 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** フローティングパネルを Stats 風のリングゲージカード表示にする。

**Architecture:** `TakometaCore` に `ProviderCard`（値型）と `formatProviderCards`（既存の選択・色ロジックを再利用する純粋関数）を置く。`TakometaApp` の `ProviderCardsView` は store / settings から `ProviderCard` 配列を組み立てる stateful container、`ProviderCardView` は `ProviderCard` だけを描画する value-only leaf とする。パネルの中身をポップオーバー流用からカード表示へ差し替える。ポップオーバー自体は変更しない。

**Tech Stack:** Swift 6.2 / SwiftUI / XCTest / SwiftPM

**設計書:** [`14-provider-cards-design.md`](14-provider-cards-design.md)

## Global Constraints

- ビルドとテストにはフル Xcode が必要。検証コマンドは `swift build` と `swift test` を個別に実行する（`;` `&&` で連結しない）
- `TakometaCore` は UI 詳細（SwiftUI の型・色の具体値）を持たない
- 値が取得できない場合に 0% を表示しない（リングを 0% で描かない）
- エージェントは `main` へ直接コミットしない。本計画は `feat/14-provider-cards` ブランチで行う（設計書のコミットが乗っている）
- コミットメッセージは日本語の Conventional Commits 形式
- **Task 3 の実機確認は委譲対象外**。委譲先は Task 1〜2 と Task 3 の CHANGELOG・コミット・push・PR 作成のみを行う

---

### Task 1: ProviderCard とフォーマッタを追加する

**Files:**
- Create: `Sources/TakometaCore/Label/ProviderCard.swift`
- Modify: `Sources/TakometaCore/Label/MenuBarLabelFormatter.swift`（`formatProviderCards` を追加）
- Test: `Tests/TakometaCoreTests/ProviderCardFormatterTests.swift`

**Interfaces:**
- Consumes: 既存の `resolveProviders` / `rankedBefore` / `style(for:freshness:now:)` / `baseName(for:)` / `filtered(_:by:)`（いずれも `MenuBarLabelFormatter.swift` 内の private static。**同一ファイル内に追加すること**で到達する）
- Produces:
  - `ProviderCard`（`name: String` / `ring: Ring` / `rows: [Row]` / `isStale: Bool`）
  - `ProviderCard.Ring`（`.gauge(percent: Int, style: SegmentStyle)` / `.unavailable` / `.authenticationRequired`）
  - `ProviderCard.Row`（`label: String` / `percent: Int` / `style: SegmentStyle`）
  - `MenuBarLabelFormatter.formatProviderCards(codex:claude:filter:now:order:kindOrders:) -> [ProviderCard]`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/TakometaCoreTests/ProviderCardFormatterTests.swift` を新規作成する。

```swift
import XCTest
@testable import TakometaCore

final class ProviderCardFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        id: String, scope: RateLimitScope, used: Double,
        kind: WindowKind? = .weekly, resetsIn: TimeInterval? = 3600
    ) -> RateLimitWindow {
        RateLimitWindow(
            id: id, label: id, scope: scope, usedPercent: used,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) }, kind: kind)
    }

    private func cards(
        codex: (windows: [RateLimitWindow], freshness: Freshness)? = nil,
        claude: (windows: [RateLimitWindow], freshness: Freshness)? = nil,
        filter: DisplayFilter = DisplayFilter(),
        kindOrders: [ProviderID: [WindowKindCategory]] = [:]
    ) -> [ProviderCard] {
        MenuBarLabelFormatter.formatProviderCards(
            codex: codex, claude: claude, filter: filter,
            now: now, kindOrders: kindOrders)
    }

    func testRingUsesMostConstrainedVisibleWindow() {
        let result = cards(
            codex: ([
                window(id: "s", scope: .session, used: 34.9, kind: .session),
                window(id: "w", scope: .weeklyAll, used: 65.2),
            ], .fresh),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Codex")
        XCTAssertEqual(result[0].ring, .gauge(percent: 65, style: .normal))
    }

    func testRowsFollowKindOrderAndUseShortNames() {
        let result = cards(
            codex: ([
                window(id: "s", scope: .session, used: 34, kind: .session),
                window(id: "w", scope: .weeklyAll, used: 52),
                window(id: "g", scope: .model(id: "g", displayName: "GPT"), used: 10),
            ], .fresh),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)),
            kindOrders: [.codex: [.model, .session, .weekly]])

        XCTAssertEqual(result[0].rows.map(\.label), ["GPT", "5h", "1w"])
        XCTAssertEqual(result[0].rows.map(\.percent), [10, 34, 52])
    }

    func testUnavailableProducesUnavailableRingWithoutRows() {
        let result = cards(
            codex: ([], .unavailable),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result[0].ring, .unavailable)
        XCTAssertTrue(result[0].rows.isEmpty)
    }

    func testEmptyVisibleWindowsProducesUnavailableRing() {
        // 種別フィルタで全枠が非表示になった場合も 0% を描かず unavailable にする
        let result = cards(
            codex: ([window(id: "w", scope: .weeklyAll, used: 52)], .fresh),
            filter: DisplayFilter(
                codex: ProviderDisplayFilter(showWeekly: false),
                claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result[0].ring, .unavailable)
    }

    func testAuthenticationRequiredProducesLockRing() {
        let result = cards(
            codex: ([window(id: "w", scope: .weeklyAll, used: 52)], .authenticationRequired),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result[0].ring, .authenticationRequired)
        XCTAssertTrue(result[0].rows.isEmpty)
    }

    func testStaleSetsFlagButKeepsGauge() {
        let result = cards(
            codex: ([window(id: "w", scope: .weeklyAll, used: 52)], .stale),
            filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

        XCTAssertTrue(result[0].isStale)
        XCTAssertEqual(result[0].ring, .gauge(percent: 52, style: .normal))
    }

    func testUnrepresentablePercentFallsBackToFullGauge() {
        let cases = [Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude]

        for used in cases {
            let result = cards(
                codex: ([window(id: "w", scope: .weeklyAll, used: used)], .fresh),
                filter: DisplayFilter(claude: ProviderDisplayFilter(show: false)))

            guard case .gauge(let percent, _) = result[0].ring else {
                return XCTFail("表現不能な値が危険側の gauge へ退化していない: \(used)")
            }
            XCTAssertEqual(percent, 100)
            XCTAssertEqual(result[0].rows.map(\.percent), [100])
        }
    }

    func testHiddenProviderProducesNoCard() {
        let result = cards(
            codex: ([window(id: "w", scope: .weeklyAll, used: 52)], .fresh),
            claude: ([window(id: "w", scope: .weeklyAll, used: 10)], .fresh),
            filter: DisplayFilter(codex: ProviderDisplayFilter(show: false)))

        XCTAssertEqual(result.map(\.name), ["Claude"])
    }

    func testProviderOrderFollowsOrderArgument() {
        let result = MenuBarLabelFormatter.formatProviderCards(
            codex: ([window(id: "w", scope: .weeklyAll, used: 52)], .fresh),
            claude: ([window(id: "s", scope: .session, used: 10, kind: .session)], .fresh),
            filter: DisplayFilter(),
            now: now,
            order: [.claude, .codex])

        XCTAssertEqual(result.map(\.name), ["Claude", "Codex"])
    }
}
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
swift test --filter ProviderCardFormatterTests
```

期待: `ProviderCard` が存在せずコンパイルエラー。

- [ ] **Step 3: ProviderCard を実装する**

`Sources/TakometaCore/Label/ProviderCard.swift` を新規作成する。

```swift
/// パネルのカード表示1枚分。組み立ては MenuBarLabelFormatter.formatProviderCards が行い、
/// View はこの値を描くだけにする。将来 WidgetKit へ移すときは timeline provider が
/// この値を組み立てて同じ View へ渡す（設計書 §4）。
public struct ProviderCard: Sendable, Equatable {
    /// リングが何を描くか。値がないケースを分離し、0% のリングを描かせない
    public enum Ring: Sendable, Equatable {
        case gauge(percent: Int, style: SegmentStyle)
        case unavailable
        case authenticationRequired
    }

    public struct Row: Sendable, Equatable {
        public let label: String
        public let percent: Int
        public let style: SegmentStyle

        public init(label: String, percent: Int, style: SegmentStyle) {
            self.label = label
            self.percent = percent
            self.style = style
        }
    }

    public let name: String
    public let ring: Ring
    public let rows: [Row]
    public let isStale: Bool

    public init(name: String, ring: Ring, rows: [Row], isStale: Bool) {
        self.name = name
        self.ring = ring
        self.rows = rows
        self.isStale = isStale
    }
}
```

- [ ] **Step 4: formatProviderCards を実装する**

`Sources/TakometaCore/Label/MenuBarLabelFormatter.swift` の `formatCombinedIcons` の直後に追加する。**同一ファイルに置くこと**（private ヘルパーへの到達に必要）。

```swift
    public static func formatProviderCards(
        codex: (windows: [RateLimitWindow], freshness: Freshness)?,
        claude: (windows: [RateLimitWindow], freshness: Freshness)?,
        filter: DisplayFilter,
        now: Date,
        order: [ProviderID] = [.codex, .claude],
        kindOrders: [ProviderID: [WindowKindCategory]] = [:]
    ) -> [ProviderCard] {
        let resolved = resolveProviders(
            codex: codex, claude: claude, filter: filter,
            order: order, labels: [:], kindOrders: kindOrders)
        return resolved.map { item in
            card(for: item, now: now)
        }
    }

    private static func card(for item: ResolvedProvider, now: Date) -> ProviderCard {
        let name = item.provider == .codex ? "Codex" : "Claude"

        if item.freshness == .authenticationRequired {
            return ProviderCard(
                name: name, ring: .authenticationRequired, rows: [], isStale: false)
        }
        guard item.freshness != .unavailable,
              let top = item.windows.sorted(by: rankedBefore).first
        else {
            return ProviderCard(name: name, ring: .unavailable, rows: [], isStale: false)
        }

        let ordered = WindowKindOrdering.sorted(
            item.windows, order: item.kindOrder,
            category: { windowKindCategory(for: $0.scope) })
        let rows = ordered.map { window in
            ProviderCard.Row(
                label: baseName(for: window.scope),
                percent: cardPercent(window.usedPercent),
                style: style(for: window, freshness: item.freshness, now: now))
        }
        return ProviderCard(
            name: name,
            ring: .gauge(
                percent: cardPercent(top.usedPercent),
                style: style(for: top, freshness: item.freshness, now: now)),
            rows: rows,
            isStale: item.freshness == .stale)
    }

    private static func cardPercent(_ usedPercent: Double) -> Int {
        Int(exactly: usedPercent.rounded(.down)) ?? 100
    }
```

`resolveProviders` は `filter` で枠を絞った `windows` を返すため、`item.windows` が空 = 表示対象の枠が0個であり、`unavailable` へ落ちる（テスト `testEmptyVisibleWindowsProducesUnavailableRing` が固定する）。
`Int` へ表現できない非有限値・範囲外値は trap や 0% 表示にせず、既存 `GaugeLevel` と同じく危険側の 100% へ倒す。

- [ ] **Step 5: テストが通ることを確認する**

```bash
swift test --filter ProviderCardFormatterTests
```

期待: PASS。

- [ ] **Step 6: テスト全体を通す**

```bash
swift test
```

期待: 全 PASS（既存への変更は formatter への純追加のみで、既存テストは影響を受けない想定。**既存テストが落ちたら期待値を書き換えず停止して報告すること**）。

- [ ] **Step 7: コミット**

```bash
git add Sources/TakometaCore/Label/ProviderCard.swift \
        Sources/TakometaCore/Label/MenuBarLabelFormatter.swift \
        Tests/TakometaCoreTests/ProviderCardFormatterTests.swift
git commit -m "feat: パネルのカード表示用モデル ProviderCard を追加

リングの値選択（最逼迫枠）と色は既存の rankedBefore / style を再利用し、
値が取得できないケースは Ring の別ケースとして分離して 0% リングを
描かせない。

Refs #14"
```

---

### Task 2: ProviderCardsView を作りパネルへ載せる

**Files:**
- Create: `Sources/TakometaApp/ProviderCardsView.swift`
- Modify: `Sources/TakometaApp/TakometaApp.swift`（カード内容とサイズ監視依存を接続）
- Modify: `Sources/TakometaApp/FloatingPanelController.swift`（内容変更時の手動サイズ追従）
- Modify: `.docs/plans/14-provider-cards-design.md`（手動測定の設計判断を記録）
- Test: `Tests/TakometaAppTests/ProviderCardsRenderingTests.swift`
- Test: `Tests/TakometaAppTests/FloatingPanelControllerTests.swift`

**Interfaces:**
- Consumes: Task 1 の `ProviderCard` / `formatProviderCards`、既存の `UsageStore` / `SettingsStore` / `SettingsSupply`
- Produces: `ProviderCardsView(store:settingsStore:)` と、カード1枚を描く `ProviderCardView(card:)`（テスト・プレビュー・将来の WidgetKit から個別に使うため分離する）

- [ ] **Step 1: View を実装する**

`Sources/TakometaApp/ProviderCardsView.swift` を新規作成する。

```swift
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
```

`menuBarInput(from:)` は既存の関数（`MenuBarLabelView.swift`）。snapshot がなくても freshness を保持する経路として #8 で導入済みのものを再利用する。

- [ ] **Step 2: パネルの中身とサイズ追従を差し替える**

`Sources/TakometaApp/TakometaApp.swift` の `FloatingPanelController` 生成箇所を変更し、描画用 root と監視する依存を分離する。

```swift
        _panelController = State(initialValue: FloatingPanelController(
            settingsStore: settingsStore,
            observeContentChanges: {
                observeProviderCardsPanelChanges(
                    store: store, settingsStore: settingsStore)
            },
            makeContent: { _ in
                providerCardsPanelContent(
                    store: store, settingsStore: settingsStore)
            }))
```

同ファイルに描画用 root と Observation が読む依存を追加する。

```swift
@MainActor
func providerCardsPanelContent(
    store: UsageStore,
    settingsStore: SettingsStore
) -> AnyView {
    AnyView(ProviderCardsView(store: store, settingsStore: settingsStore).fixedSize())
}

@MainActor
func observeProviderCardsPanelChanges(store: UsageStore, settingsStore: SettingsStore) {
    _ = store.states
    _ = store.revision
    _ = settingsStore.providers
}
```

`Sources/TakometaApp/FloatingPanelController.swift` では `Observation` を import し、`observeContentChanges` と hosting を保持する。`sizingOptions = []` は #11 の無限ループ回避のため維持し、複合 View で 0x0 になり得る `view.fittingSize` ではなく `sizeThatFits(in:)` を使う。

```swift
    private let observeContentChanges: () -> Void
    private let makeContent: (FloatingPanelController) -> AnyView
    private var panel: NSPanel?
    private var hosting: NSHostingController<AnyView>?

    private static let contentSizeProposal = CGSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude)

    init(
        settingsStore: SettingsStore,
        observeContentChanges: @escaping () -> Void = {},
        makeContent: @escaping (FloatingPanelController) -> AnyView
    ) {
        self.settingsStore = settingsStore
        self.observeContentChanges = observeContentChanges
        self.makeContent = makeContent
        super.init()
        observeContentSizeChanges()
        // 既存の NotificationCenter observer 登録は続ける
    }

    func refreshContentSize() {
        guard let panel, let hosting else { return }
        let fittingSize = hosting.sizeThatFits(in: Self.contentSizeProposal)
        guard fittingSize != panel.contentLayoutRect.size else { return }
        panel.setContentSize(fittingSize)
        clampToVisibleScreen(panel)
    }

    private func observeContentSizeChanges() {
        withObservationTracking {
            observeContentChanges()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshContentSize()
                self.observeContentSizeChanges()
            }
        }
    }
```

`show()` は panel を保持した直後に `refreshContentSize()` を呼ぶ。`makePanel()` は `makeContent(self)` で hosting を作ってプロパティへ保持し、初期サイズも次で与える。

```swift
        hosting.sizingOptions = []
        self.hosting = hosting
        panel.contentViewController = hosting
        panel.setContentSize(hosting.sizeThatFits(in: Self.contentSizeProposal))
```

- [ ] **Step 3: 描画スモークテストを書く**

`Tests/TakometaAppTests/ProviderCardsRenderingTests.swift` を新規作成する。

```swift
import SwiftUI
import XCTest
@testable import TakometaApp
import TakometaCore

@MainActor
final class ProviderCardsRenderingTests: XCTestCase {
    private func render(_ card: ProviderCard) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: ProviderCardView(card: card).fixedSize())
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff))
    }

    private func maxAlpha(_ rep: NSBitmapImageRep) -> Double {
        var best = 0.0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                best = max(best, Double(color.alphaComponent))
            }
        }
        return best
    }

    func testCardRendersNonEmptyImage() throws {
        let rep = try render(ProviderCard(
            name: "Codex",
            ring: .gauge(percent: 53, style: .warning),
            rows: [ProviderCard.Row(label: "1w", percent: 53, style: .warning)],
            isStale: false))

        XCTAssertGreaterThan(rep.pixelsWide, 0)
        XCTAssertGreaterThan(maxAlpha(rep), 0.5)
    }

    func testStaleCardIsDimmed() throws {
        let card = ProviderCard(
            name: "Codex",
            ring: .gauge(percent: 53, style: .normal),
            rows: [], isStale: false)
        let staleCard = ProviderCard(
            name: "Codex",
            ring: .gauge(percent: 53, style: .normal),
            rows: [], isStale: true)

        let fresh = maxAlpha(try render(card))
        let stale = maxAlpha(try render(staleCard))

        // 多層 View では opacity が層ごとに掛かり合成で累積するため、
        // fresh × 0.6 の厳密一致は成立しない（不透明背景 0.6 の上に文字 0.51 が
        // 重なると合成アルファは約 0.80 になる）。減光が適用されていることを
        // 上下の境界で固定する: 減光なし(=fresh)より確実に薄く、消えてはいない
        XCTAssertGreaterThan(fresh, 0.95, "fresh カードの背景が不透明で描かれていない")
        XCTAssertLessThan(stale, fresh * 0.9, "stale カードに減光が効いていない")
        XCTAssertGreaterThan(stale, fresh * 0.5, "stale カードが薄すぎる（読めない）")
    }
}
```

- [ ] **Step 4: パネルサイズ追従テストを書く**

`Tests/TakometaAppTests/FloatingPanelControllerTests.swift` にテスト用 provider と、実 `NSPanel` の高さ・幅が内容変更へ追従する2テストを追加する。テスト用 `SettingsStore` は既存 `makeStore()` で UserDefaults を隔離する。

```swift
private struct FloatingPanelTestProvider: UsageProvider {
    let id: ProviderID = .codex
    let normalInterval: TimeInterval = 300

    func fetch() async throws -> UsageSnapshot {
        throw UsageFetchError.transient(reason: "test")
    }

    func updates() -> AsyncStream<UsageSnapshot> {
        AsyncStream { $0.finish() }
    }
}

    func testUsageStateChangeRefreshesProviderCardsHeight() async throws {
        let (settingsStore, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(directory: directory.appendingPathComponent("cache"))
        try cache.save(UsageSnapshot(
            provider: .codex,
            windows: [
                RateLimitWindow(
                    id: "session", label: "session", scope: .session,
                    usedPercent: 20, resetsAt: nil, kind: .session),
                RateLimitWindow(
                    id: "weekly", label: "weekly", scope: .weeklyAll,
                    usedPercent: 40, resetsAt: nil, kind: .weekly),
            ],
            fetchedAt: Date(),
            source: .codexAppServer))
        let usageStore = UsageStore(
            providers: [FloatingPanelTestProvider()],
            cache: cache,
            scheduler: TimerScheduler())
        let controller = FloatingPanelController(
            settingsStore: settingsStore,
            observeContentChanges: {
                observeProviderCardsPanelChanges(
                    store: usageStore, settingsStore: settingsStore)
            }
        ) { _ in
            providerCardsPanelContent(
                store: usageStore, settingsStore: settingsStore)
        }

        controller.show()
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? NSPanel }.first {
            $0.title == "Takometa"
        })
        defer { panel.orderOut(nil) }
        let initialHeight = panel.contentLayoutRect.height
        XCTAssertGreaterThan(initialHeight, 0)

        usageStore.start()
        try await waitUntil { panel.contentLayoutRect.height > initialHeight }

        XCTAssertGreaterThan(panel.contentLayoutRect.height, initialHeight)
    }

    func testProviderVisibilityChangeRefreshesProviderCardsWidth() async throws {
        let (settingsStore, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let usageStore = UsageStore(
            providers: [FloatingPanelTestProvider()],
            cache: SnapshotCache(directory: directory.appendingPathComponent("cache")),
            scheduler: TimerScheduler())
        let controller = FloatingPanelController(
            settingsStore: settingsStore,
            observeContentChanges: {
                observeProviderCardsPanelChanges(
                    store: usageStore, settingsStore: settingsStore)
            }
        ) { _ in
            providerCardsPanelContent(
                store: usageStore, settingsStore: settingsStore)
        }

        controller.show()
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? NSPanel }.first {
            $0.title == "Takometa"
        })
        defer { panel.orderOut(nil) }
        let initialWidth = panel.contentLayoutRect.width

        settingsStore.update(provider: ProviderID.codex.rawValue) { $0.show = false }
        try await waitUntil { panel.contentLayoutRect.width < initialWidth }

        XCTAssertLessThan(panel.contentLayoutRect.width, initialWidth)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
```

既存の手動更新テストも `view.fittingSize` ではなく `hosting.sizeThatFits(in:)` の測定値へ復元することを固定する。

- [ ] **Step 5: ビルドとテストを通す**

```bash
swift build
```

```bash
swift test
```

期待: 全 PASS。

- [ ] **Step 6: コミット**

```bash
git add Sources/TakometaApp/ProviderCardsView.swift \
        Sources/TakometaApp/FloatingPanelController.swift \
        Sources/TakometaApp/TakometaApp.swift \
        Tests/TakometaAppTests/ProviderCardsRenderingTests.swift \
        Tests/TakometaAppTests/FloatingPanelControllerTests.swift \
        .docs/plans/14-provider-cards-design.md
git commit -m "feat: パネルを Stats 風のリングゲージカード表示にする

パネルは「眺める用」としてカード表示（リング＋内訳行）へ差し替え、
詳細（リセット・ペース・操作）はポップオーバーの担当のまま変えない。
ProviderCardView は ProviderCard のみを入力に取り、将来の WidgetKit
移植で timeline provider から再利用できる形にした。

Refs #14"
```

---

### Task 3: 仕上げ

> **委譲時の注意:** 実機目視確認は依頼元が行う。委譲先は以下のみを実施し、PR 本文に「実機目視確認は未実施」と明記する。

- [ ] **Step 1: CHANGELOG を更新する**

`CHANGELOG.md` の `[Unreleased]` の `### Added` に追記する。

```markdown
- フローティングパネルを Stats 風のリングゲージカード表示にした。プロバイダごとに1カードで、リングが最も逼迫した枠の使用率を、下の内訳が全枠の使用率を示す。リセット時刻やペースなどの詳細はメニューバーのポップオーバーで引き続き確認できる
```

- [ ] **Step 2: コミットして push し PR を作成する**

```bash
git add CHANGELOG.md
git commit -m "docs: カード表示の追加を CHANGELOG へ追記

Refs #14"
```

```bash
git push -u origin feat/14-provider-cards
```

```bash
gh pr create --title "フローティングパネルを Stats 風のリングゲージカードにする" --body "$(cat <<'BODY'
Closes #14

## 変更内容

- `ProviderCard`（Core の値型）と `formatProviderCards` を追加。リングの値選択（最逼迫枠）と色は既存の `rankedBefore` / `style` を再利用
- `ProviderCardsView` / `ProviderCardView` を追加し、フローティングパネルの中身をポップオーバー流用からカード表示へ差し替え
- ポップオーバーは変更なし（「調べる用」として詳細表示を維持）
- 退化状態は #4 の決定を踏襲（値なし→`--`、要認証→鍵、stale→減光0.6＋⏱）

設計書: `.docs/plans/14-provider-cards-design.md`

## 検証

- `swift build` / `swift test` 完走
- 実機目視確認は未実施（依頼元が実施する）

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

---

## レビューサイクル

コード変更を含むため、`swift build` / `swift test` 通過後に次のレビュアーを起動し、flag された確信度80%以上の指摘が0になるまで「修正 → 再レビュー」を反復する。

| 条件 | レビュアー |
|---|---|
| コード変更（常時） | `pr-review-toolkit:code-reviewer` |
| 新しい型を追加（Task 1） | `pr-review-toolkit:type-design-analyzer` |
| テストを追加（Task 1・2） | `pr-review-toolkit:pr-test-analyzer` |
| コメントを追加（全タスク） | `pr-review-toolkit:comment-analyzer` |

try-catch / フォールバックを新規に書かないため `silent-failure-hunter` は対象外。
