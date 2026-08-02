# メニューバー表示モードの再設計 — 設計書

- Issue: [#4](https://github.com/elchika-inc/takometa/issues/4)
- 作成日: 2026-08-02
- 状態: 設計確定（実装計画は別ファイル）

## 1. 背景と問題

拡張ディスプレイを外して内蔵ディスプレイのみにすると、Takometa のラベルがメニューバーから消える。macOS はステータスアイテムがあふれると予告なく切り捨てるため、アプリ側で取れる対策は「占有幅を選べるようにする」ことに限られる。

`MenuBarLabelView` は SwiftUI ビューを `ImageRenderer` で画像化してラベルに渡しており（`Sources/TakometaApp/MenuBarLabelView.swift:33`, `:42`）、`.fixedSize()` により幅が足りなくても縮まない。入らなければ丸ごと消える。

あわせて、現行の `Balanced` と `Full` に実質的な差がないことが実測で判明した。

### 実測結果

`select(windows:mode:)`（`Sources/TakometaCore/Label/MenuBarLabelFormatter.swift:375`）における `Full` と `Balanced` の差は、モデル固有枠の表示上限（`:404` の `limit = mode == .full ? 2 : 1`）と `+N` の有無（`:410`）だけである。モデル固有枠が0〜1個の環境では、両モードの出力は文字単位で完全に一致する。

| 既存テスト | モード | 入力のモデル枠 | 期待値 |
|---|---|---|---|
| `MenuBarLabelFormatterTests.swift:301` | `.full` | 1個 | `CX 34\|52\|G78` |
| `MenuBarLabelFormatterTests.swift:338` | `.balanced` | 3個 | `CX 34\|52\|G78` |
| `MenuBarLabelFormatterTests.swift:346` | `.compact` | 0個 | `CL W65` |

上2件は入力が異なるため、これ自体は両モードの同一性を示すものではない。同一性は `select`（`:404`）の `limit` 分岐から導かれる ─ モデル固有枠が0〜1個なら `limit` が2でも1でも選ばれる枠は変わらず、`overflow` も0になるため、`.full` と `.balanced` は同じ出力を返す。

また `format(provider:...)`（`:150`）はプロバイダ単位で呼ばれ、その内部で `select` が走る。したがって既存 `.compact` は「全体で1枠」ではなく「**プロバイダごとに最逼迫1枠**」である。

## 2. 設計方針

3つのモードの軸を「占有幅の段階」に統一し、意味を1段ずつ下へずらす。

| モード | UI 表示 | 中身 | 概算幅 | 実装 |
|---|---|---|---|---|
| `.full` | Full | session + weekly + モデル枠最大2 + `+N` | 約180pt | 現行維持 |
| `.balanced` | Balanced | プロバイダごとに最逼迫1枠（`H`/`W`/略称つき） | 約90pt | 現 `.compact` のロジックを移設 |
| `.compact` | Compact | ゲージアイコンのみ | 約25pt／プロバイダ | 新規 |

廃止されるのは旧 `.balanced`（モデル枠1個）のみ。

`select` の変更は次の2点に閉じる。

- `case .full, .balanced:` を `.full` 専用にし、`limit = mode == .full ? 2 : 1` を `limit = 2` の定数へ単純化する
- 現 `.compact` の本体（最逼迫1枠 + `H`/`W` 接頭辞）を `.balanced` へ移す

`.compact` は `select` を通らない別経路（4章）へ分岐する。

### 2行表示への波及

`formatCombinedColumns`（`:223`）も同じ `select(windows:mode:)` を呼ぶ（`:269`）。モードの再配置は2行表示側へ自動的に波及し、追加実装を要しない。

## 3. Compact モードの表現

### 3.1 二重符号化

- **針の角度** = 使用率（5段階に量子化）
- **色** = ペース（既存の `style(for:)`（`:466`）をそのまま再利用）

`style(for:)` は使用率ではなく `UsagePace.willLastToReset` で warning を決めており、100% 到達のみ critical とする。したがって針と色は互いに独立した情報を担い、アイコン1個で2軸を伝えられる。

### 3.2 使用する SF Symbols

以下は macOS 26.x 上で `NSImage(systemSymbolName:accessibilityDescription:)` が非 nil を返すことを実測で確認済み。

| 使用率 | `GaugeLevel` | シンボル |
|---|---|---|
| 0% 以上 20% 未満 | `.zero` | `gauge.with.dots.needle.0percent` |
| 20% 以上 40% 未満 | `.low` | `gauge.with.dots.needle.33percent` |
| 40% 以上 60% 未満 | `.mid` | `gauge.with.dots.needle.50percent` |
| 60% 以上 80% 未満 | `.high` | `gauge.with.dots.needle.67percent` |
| 80% 以上 | `.max` | `gauge.with.dots.needle.100percent` |

入力は `rankedBefore`（`:428`）で選ばれた、そのプロバイダの最逼迫枠の `usedPercent`。100% を超える値（Codex が返しうる）は `.max` に落ちる。

### 3.3 アイコンの個数

表示 ON のプロバイダごとに1個とする。`ProviderDisplayFilter.show` と `providerOrder` は `resolveProviders`（`:118`）が既に解決しているため、3モードで表示対象と並び順が自動的に一致する。

### 3.4 退化ケース

| 状態 | 表現 | テキスト版での対応物 |
|---|---|---|
| 値が取得できない（`freshness == .unavailable`） | `questionmark.circle`（グレー） | `CX --` |
| 表示対象の枠が0個（種別フィルタで全 OFF 等） | `questionmark.circle`（グレー） | `CX --` |
| 要認証 | `lock.circle`（グレー） | `🔒` |
| 古い値（stale） | 同じアイコン・同じ色を `opacity 0.45` で描く | `⏱` |
| 表示 ON のプロバイダが0個 | `MenuBarIcons.icons` が空。既存 `EmptyMenuBarLabelView`（`gauge.medium`）へ | 同左 |

上2つは「そのプロバイダのアイコンが `unavailable` になる」ケース、最下段は「アイコンが1個も生成されない」ケースであり、別物として扱う。前者はテキスト版が `CX --` を出す条件（`MenuBarLabelFormatter.swift:160`, `:165`）と一致させる。

stale をマーク追加ではなく不透明度で表すのは、幅を1ピクセルも増やさないため。Compact の存在理由が幅である以上、ここでマークを足すと目的と矛盾する。色相は残るため warning / critical の判別も維持される。

要認証はテキスト版と挙動が異なる点に注意する。テキスト版は値を表示したうえで `🔒` を添える（`appendFreshnessMark`, `MenuBarLabelFormatter.swift:482`）が、Compact は「1プロバイダ＝1グリフ」を厳守するため値を捨てて `lock.circle` を出す。認証切れの状態では値が更新されないので、古い数値を出し続けるより「再ログインが要る」という行動可能な情報を優先する。

`questionmark.gauge` は実測で存在しないことを確認したため候補から除外した。

## 4. 型とデータフロー

### 4.1 追加する型（`Sources/TakometaCore/Label/MenuBarIcons.swift`）

```swift
/// 使用率を針の角度5段階へ量子化したもの。
/// SF Symbols 名への写像は表示層が持つ ─ Core は UI 詳細を知らない。
public enum GaugeLevel: Sendable, Equatable, CaseIterable {
    case zero, low, mid, high, max
}

/// アイコンが何を描くか。値がないケースを型で分離する。
public enum MenuBarIconGlyph: Sendable, Equatable {
    case gauge(GaugeLevel)
    case unavailable
    case authenticationRequired
}

public struct MenuBarIcon: Sendable, Equatable {
    public let glyph: MenuBarIconGlyph
    public let style: SegmentStyle
    public let isStale: Bool
    public let accessibilityText: String
}

public struct MenuBarIcons: Sendable, Equatable {
    public let icons: [MenuBarIcon]
    public var accessibilityText: String { /* 下記の規則で連結 */ }
}
```

各 `MenuBarIcon.accessibilityText` は `"<プロバイダラベル> <枠名> <使用率>%"` を基本とし、退化ケースでは使用率の代わりに状態語を置く（値なし → `"取得できません"`、要認証 → `"要認証"`）。stale のときは末尾に `"（更新が古い）"` を付す。`MenuBarIcons.accessibilityText` はそれらを**半角スペース2つ**で連結する。区切り幅は `MenuBarColumns.accessibilityText`（`Sources/TakometaCore/Label/MenuBarColumns.swift:33`）のグループ区切りと同じ規則に揃える。

例: `Codex 週間 49%  Claude 5時間 20%（更新が古い）`

`MenuBarIconGlyph` を enum にしたのは、「値が取得できない場合に 0% を表示しない」という AGENTS.md の設計原則を型で守るため。`GaugeLevel` 単体を持たせると、値がないときに `.zero` を入れる余地が生まれ、画面上は使用率0%と区別できなくなる。`unavailable` を別ケースにすれば、表示層の `switch` が網羅性チェックで漏れを弾く。

### 4.2 フォーマッタ

`MenuBarLabelFormatter.formatCombinedIcons(...)` を追加する。シグネチャは `formatCombinedColumns` に揃え、`resolveProviders` を再利用する。

### 4.3 データフロー

```
UsageStore ─→ MenuBarLabelView
                  ├ displayMode == .compact → formatCombinedIcons()  → MenuBarIcons  → MenuBarIconsView   ─┐
                  ├ lineCount == .two       → formatCombinedColumns() → MenuBarColumns → MenuBarColumnsView ─┤
                  └ それ以外                → formatCombined()        → MenuBarLabel   → MenuBarSegmentView ─┤
                                                                                                             │
                                                                          ImageRenderer → NSImage → MenuBarExtra
```

アイコンも既存2形式と同じ `ImageRenderer` 経路に乗せる。`MenuBarExtra` の label は複雑なレイアウトを直接描画できないため、既存コードが画像化している方針をそのまま踏襲する。

## 5. 設定の移行

### 5.1 冪等性という論点

「読み込み時に `compact` → `balanced`、`balanced` → `full` と書き換える」という素直な移行は冪等ではない。移行後に保存された `balanced` を次回起動で再び読むと `full` へ繰り上がり、起動のたびにモードが上がり続ける。移行済みの値と未移行の値が同じ文字列になることが原因である。

回避には「移行済みだと分かる印」が要る。印の置き場所はスキーマバージョンか値そのものの2択。

### 5.2 採用案 — `.compact` の rawValue を `"icon"` にする

```swift
public enum DisplayMode: String, Sendable, CaseIterable {
    case full                  // "full"
    case balanced              // "balanced"
    // rawValue が case 名と異なるのは意図的。旧版の "compact"（＝最逼迫1枠）と
    // 新しいアイコン表示を永続化層で区別し、移行を冪等にするため。
    case compact = "icon"
}
```

| 保存値 | 読み込み結果 | 出力の変化 | 冪等性 |
|---|---|---|---|
| `"compact"`（旧） | `.balanced` | なし（`CL W65` のまま） | 保存時 `"balanced"` となり以降は下の行へ入る |
| `"balanced"`（旧） | `.full` | **条件付き**（下記 5.4） | 形式上は非冪等だが、保存値が `"full"` となり1段で停止する |
| `"full"` | `.full` | なし | 冪等 |
| `"icon"`（新） | `.compact` | ─ | 冪等 |

新しいアイコン表示は自発的に選んだときのみ有効になる。

### 5.4 旧 `balanced` からの移行だけは無条件に無変化ではない

旧 `.balanced` はモデル固有枠を1個まで表示し、新 `.full` は2個まで表示して超過分を `+N` で示す。したがって移行後の出力は次のように分かれる。

| モデル固有枠の個数 | 旧 `balanced` の出力 | 新 `full` の出力 | 変化 |
|---|---|---|---|
| 0〜1個 | `CX 34\|52\|G78` | `CX 34\|52\|G78` | なし |
| 2個以上 | `CX 34\|52\|G78` | `CX 34\|52\|G78\|F65 +1` | **1枠増える** |

2026-08-02 時点の実データ（`Tests/TakometaCoreTests/Fixtures/claude/live_masked.json`）では、Claude のモデル固有枠は Fable の1個、Codex は `secondary: null` で0個。したがって現時点の実環境では出力は変わらない。Claude が2個以上返すようになった時点で幅が増える。

移行先を `.balanced`（1枠）ではなく `.full` にしたのは、旧 `balanced` 利用者が許容していた幅に近いのが `.full` だからである。幅を能動的に減らしたい場合は、移行後に `.balanced` または `.compact` を選び直せばよい。

### 5.3 設定ファイルの version は 1 のまま据え置く

`SettingsStore.swift:72` は `version == 1` 以外を read-only モードへ落とす。version を 2 へ上げると旧バージョンの Takometa で設定を保存できなくなる。rawValue で移行を表現すれば version を触らずに済み、旧アプリは未知の `"icon"` を `?? .full`（`SettingsStore.swift:174` の既存フォールバック）で安全に読み飛ばす。

## 6. 設定 UI

`SettingsView.swift:89` の行数 Picker を Compact 選択中は無効化し、理由を併記する。

```swift
Picker("メニューバーの行数", selection: menuBarLineCountBinding) { ... }
    .disabled(settingsStore.displayMode == .compact)

if settingsStore.displayMode == .compact {
    Text("Compact はアイコンのみのため行数は適用されません")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

`menuBarLineCount` の保存値は書き換えない。Balanced / Full へ戻した時点で元の行数が復活する。

## 7. テスト

### 7.1 境界値（新規 `MenuBarIconsTests`）

- `0 / 19.9 / 20 / 39.9 / 40 / 59.9 / 60 / 79.9 / 80 / 100 / 120` に対する `GaugeLevel`
- 100 超が `.max` に落ちること
- `unavailable` / `authenticationRequired` が `.gauge` を返さないこと

### 7.2 移行の冪等性（既存 `SettingsMigrationTests` に追加）

- `"compact"` を読む → `.balanced` → 保存 → `"balanced"` → 再読込 → `.balanced` のまま
- `"balanced"` を読む → `.full` → 保存 → `"full"` → 再読込 → `.full`
- `"icon"` を読む → `.compact`
- 未知の値 → `.full` へフォールバック（既存挙動の維持）

### 7.3 回帰の要（既存 `MenuBarLabelFormatterTests` の付け替え）

- `testCompactShowsMostConstrainedBasicWithKindPrefix`（`:346`）を `.balanced` へ付け替え、**期待値 `CL W65` は据え置く**。期待値を変えずに通ることが「旧 `compact` 利用者の見た目が変わらない」ことの証明になる。期待値も同時に書き換えると、この設計目標が検証されないまま緑になる
- `testBalancedShowsBasicsAndMostConstrainedNonBasic`（`:338`）は旧 `.balanced` の挙動（モデル枠1個）を検証するものであり、その挙動自体が廃止される。`.full` へ付け替えたうえで**期待値を `CX 34|52|G78|F65 +1` へ更新**し、テスト名を `testLegacyBalancedInputRendersAsFullAfterMigration` へ改める。これは 5.4 の「モデル枠2個以上では1枠増える」を固定するテストになる
- `MenuBarColumnsFormatterTests` に、2行表示でも `.balanced` が1枠になることの確認を1件追加

7.3 の2件は期待値の扱いが逆になる。前者は「変わらないこと」を、後者は「変わること」を固定する。どちらも移行の意味論そのものを表現している。

## 8. 影響範囲

| ファイル | 変更 |
|---|---|
| `Sources/TakometaCore/Label/MenuBarIcons.swift` | 新規（型＋量子化） |
| `Sources/TakometaCore/Label/MenuBarLabelFormatter.swift` | `select` の分岐整理、`formatCombinedIcons` 追加 |
| `Sources/TakometaCore/Settings/SettingsStore.swift` | `DisplayMode` の rawValue 移行 |
| `Sources/TakometaApp/MenuBarLabelView.swift` | 3分岐化、`MenuBarIconsView` 追加 |
| `Sources/TakometaApp/SettingsView.swift` | 行数 Picker の無効化＋説明 |
| `Tests/TakometaCoreTests/MenuBarIconsTests.swift` | 新規 |
| `Tests/TakometaCoreTests/MenuBarLabelFormatterTests.swift` | モード付け替え |
| `Tests/TakometaCoreTests/MenuBarColumnsFormatterTests.swift` | 1件追加 |
| `Tests/TakometaCoreTests/SettingsMigrationTests.swift` | 移行テスト追加 |

## 9. リスクと退路

| # | リスク | 退路 |
|---|---|---|
| 1 | 針の角度がメニューバーサイズ（約18pt）で判別できるか未検証。33% と 50% の差が読めない恐れ | `GaugeLevel` の量子化関数1つの変更で3段階（`0/50/100percent`）へ縮退できる設計にしてある |
| 2 | stale の `opacity 0.45` と warning の橙が紛らわしい恐れ | 実機確認で不透明度を調整する |
| 3 | 旧 `"balanced"` → `.full` の移行が形式上は非冪等 | 1段で停止することを 7.2 のテストで固定する |
| 4 | 旧 `balanced` 利用者は、モデル固有枠が2個以上になった時点で表示が1枠増える（5.4）。現在の設定値は `balanced` であり該当する | 2026-08-02 時点の実データではモデル枠が1個以下のため実害なし。増えた時点で `.balanced` / `.compact` を選び直せる。7.3 のテストでこの挙動を固定する |

1〜2は実機確認が必要な項目であり、実装後の検証で判定する。

## 10. スコープ外

- メニューバー以外への表示（ウィジェット・フローティングパネル）。WidgetKit のウィジェットはサンドボックス必須かつ本体とのデータ共有に App Group entitlement を要し、App Group 識別子は Team ID プレフィックスを必要とする。現行の ad-hoc 署名（`scripts/lib/make-bundle.sh:67`）では成立せず、Apple Developer Program への加入と配布フロー全体の再構築が前提になる。別 Issue として扱う
- Full の表示上限の変更・設定項目化
