# #20 プロバイダロゴ表示 実装計画

> **For agentic workers:** 本計画はタスク単位で実装する。各タスク末尾の検証コマンドを実行し、緑を確認してからコミットする。チェックボックス（`- [ ]`）で進捗を管理する。

**Goal:** メニューバーの `CL` / `CX` 文字列プレフィックスをプロバイダロゴ（Claude = 同梱 SVG、Codex = SF Symbols `terminal`）に置き換え、カスタムラベル機能を廃止する。

**Architecture:** Core の `MenuBarLabel` / `MenuBarColumns` をプロバイダ単位のグループ構造へ変更し、プレフィックス文字列の生成を廃止。ProviderID → ロゴの写像は表示層の `ProviderLogoView` に閉じる。正本は設計書 `.docs/plans/20-provider-logos-design.md`。

**Tech Stack:** Swift 6.2 / SwiftUI / SwiftPM（フル Xcode 26.6 必須）

**レビューサイクル実施者:** 実装エージェント（Codex）が委譲先で完結させる。タスクごとの `swift build` / `swift test` に加え、全タスク完了後に設計書の検証 rubric 1〜7 を自己検証する。

## Global Constraints

- 値が取得できない場合に 0% を表示しない（既存原則。`freshness` 分岐を壊さない）
- 「アイコン」という語を本機能に使わない。コード・UI 文言・コミットメッセージでは「プロバイダロゴ / providerLogo」と呼ぶ（既存 `DisplayMode.compact` = 「アイコン表示」との衝突回避）
- Core（TakometaCore）に SVG ファイル名・SF Symbols 名を置かない。写像は表示層のみ
- アセット `Sources/TakometaApp/Resources/claude-logo.svg` は本ブランチにコミット済み。**新規取得・改変をしない**
- ベースライン: `swift test` は `FloatingPanelControllerTests.testRefreshContentSizeRestoresHostingMeasuredSize` が既知 failure（0 unexpected）。この1件は合否判定から除外
- **指示と実態が矛盾したら、推測で埋めずに停止して報告する**

---

### Task 1: Core に providerDisplayName を追加

**Files:**
- Modify: `Sources/TakometaCore/Model/UsageModel.swift`（`ProviderID` 定義の直後）
- Test: `Tests/TakometaCoreTests/MenuBarLabelFormatterTests.swift`（末尾に追加）

**Interfaces:**
- Produces: `public func providerDisplayName(_ provider: ProviderID) -> String` — `.codex` → `"Codex"`、`.claude` → `"Claude"`。以降の全タスクの読み上げテキストがこれを使う。

- [ ] **Step 1: 失敗するテストを書く**

```swift
final class ProviderDisplayNameTests: XCTestCase {
    func testDisplayNames() {
        XCTAssertEqual(providerDisplayName(.codex), "Codex")
        XCTAssertEqual(providerDisplayName(.claude), "Claude")
    }
}
```

- [ ] **Step 2: `swift test --filter ProviderDisplayNameTests` でコンパイルエラー（未定義）を確認**
- [ ] **Step 3: `UsageModel.swift` に実装**

```swift
/// UI・読み上げ用のプロバイダ表示名。旧 CL / CX 略称の後継。
public func providerDisplayName(_ provider: ProviderID) -> String {
    switch provider {
    case .codex: return "Codex"
    case .claude: return "Claude"
    }
}
```

なお `SettingsView.swift:331` に同名の private ヘルパーが既にある。本タスクで Core 版を追加した後、SettingsView の private 版2つ（`ProviderID` 版・`String` 版）を Core 版利用へ置き換えて重複を消す（`String` 版は `ProviderID(rawValue:)` で変換してから Core 版を呼ぶ形に書き換える）。

- [ ] **Step 4: `swift test --filter ProviderDisplayNameTests` で PASS、`swift build` 成功を確認**
- [ ] **Step 5: コミット** `feat: プロバイダ表示名を Core へ追加`

---

### Task 2: 1行表示のグループ構造化と ProviderLogoView

**Files:**
- Modify: `Sources/TakometaCore/Label/MenuBarLabelFormatter.swift`
- Modify: `Sources/TakometaApp/MenuBarLabelView.swift`
- Create: `Sources/TakometaApp/ProviderLogoView.swift`
- Modify: `Package.swift`（`TakometaApp` ターゲットに `resources: [.process("Resources")]`）
- Test: `Tests/TakometaCoreTests/MenuBarLabelFormatterTests.swift`（全面更新）、`Tests/TakometaAppTests/MenuBarLabelViewTests.swift`（追随）

**Interfaces:**
- Consumes: `providerDisplayName(_:)`（Task 1）
- Produces:

```swift
public struct MenuBarLabel: Sendable, Equatable {
    public struct Group: Sendable, Equatable {
        public let provider: ProviderID
        public let segments: [LabelSegment]
        public init(provider: ProviderID, segments: [LabelSegment])
    }
    public let groups: [Group]
    public init(groups: [Group])
    /// VoiceOver 用。各グループを「<providerDisplayName> <セグメント連結>」で読み、
    /// グループ区切りは半角スペース2つ（MenuBarColumns.accessibilityText と同じ規約）。
    public var accessibilityText: String
}
```

- `format(provider:windows:freshness:now:mode:kindOrder:)` は `[LabelSegment]` を返す形へ変更（`customPrefix` パラメータ削除、プレフィックスセグメント生成なし）
- `formatCombined(codex:claude:filter:now:mode:order:kindOrders:)` は `MenuBarLabel`（groups 構造）を返す（`labels` パラメータ削除）
- `ProviderLogoView(provider: ProviderID)` — `.claude` は `Bundle.module` の `claude-logo.svg` を `NSImage` で読み `Image(nsImage:).renderingMode(.template)`、`.codex` は `Image(systemName: "terminal")`。読み込み失敗は `os_log` で記録し `Image(systemName: "sparkles")` へフォールバック。`static let` でキャッシュ（初回描画時に1度だけ読み込み）

実装上の注意:
- `resolvedPrefix` / `resolvedPrefixTitle` はこのタスクでは 2行表示（`columnGroup`）がまだ参照しているため、1行経路からの参照だけを外す。削除は Task 3 で行う
- プロバイダ間の区切りセグメント `"  "` は生成しない。`MenuBarSegmentView` がグループを `HStack(spacing: 8)` で並べ、グループ内は従来どおり spacing 0。ロゴは `ProviderLogoView().frame(height: 12)` 相当でテキストとベースライン中央揃え
- `MenuBarLabelView` の 1行分岐は `label.groups.isEmpty` 判定・`accessibilityLabel(label.accessibilityText)` へ変更
- `formatCombined` 既存の「区切り `"  "` セグメント挿入」ロジックは削除

- [ ] **Step 1: MenuBarLabelFormatterTests を新構造へ書き換え、失敗を確認**

代表テスト（他の既存ケースも同じ変換方針で書き換える。プレフィックス文字列 `"CL "` / `"CX "` と区切り `"  "` への言明は削除し、`groups[i].provider` への言明に置き換える）:

```swift
func testCombinedGroupsCarryProviderAndNoPrefixSegments() {
    let label = MenuBarLabelFormatter.formatCombined(
        codex: (windows: [sessionWindow(percent: 34)], freshness: .fresh),
        claude: (windows: [sessionWindow(percent: 16)], freshness: .fresh),
        filter: DisplayFilter(), now: now, mode: .full)
    XCTAssertEqual(label.groups.map(\.provider), [.codex, .claude])
    for group in label.groups {
        XCTAssertFalse(group.segments.contains { $0.text.contains("CX") || $0.text.contains("CL") })
    }
}

func testAccessibilityTextIncludesProviderNames() {
    // 値あり・値なし（"--"）・stale（"⏱"）・要認証（"🔒"）の4経路すべてで
    // "Codex" / "Claude" が読み上げに含まれることを検証するケースを作る
    let label = MenuBarLabelFormatter.formatCombined(
        codex: (windows: [], freshness: .unavailable),
        claude: (windows: [sessionWindow(percent: 16)], freshness: .fresh),
        filter: DisplayFilter(), now: now, mode: .full)
    XCTAssertTrue(label.accessibilityText.contains("Codex --"))
    XCTAssertTrue(label.accessibilityText.contains("Claude"))
}
```

- [ ] **Step 2: Core を実装（MenuBarLabel 構造変更・format 系変更）し、`swift test --filter MenuBarLabelFormatterTests` PASS を確認**
- [ ] **Step 3: `Package.swift` に resources 宣言を追加し、`ProviderLogoView.swift` を実装**
- [ ] **Step 4: `MenuBarLabelView.swift` の1行分岐と `MenuBarSegmentView` を追随させ、`swift build` 成功を確認**
- [ ] **Step 5: アセット読み込みテストを追加して PASS を確認**

```swift
// Tests/TakometaAppTests/ に追加（例: ProviderLogoViewTests.swift）
func testClaudeLogoAssetLoads() {
    let url = Bundle.module.url(forResource: "claude-logo", withExtension: "svg")
    XCTAssertNotNil(url)
    XCTAssertNotNil(url.flatMap { NSImage(contentsOf: $0) })
}
```

注意: テストターゲットから `Bundle.module` はアプリターゲットのバンドルを指さない。`ProviderLogoView` 側にバンドル URL を返す static プロパティ（例: `static var claudeLogoURL: URL?`）を持たせ、テストはそれを検証する形にする。

- [ ] **Step 6: `swift test` で failure が既知1件のみを確認し、コミット** `feat: 1行表示をプロバイダロゴ+グループ構造へ変更`

---

### Task 3: 2行表示のグループ構造化と spike 追随

**Files:**
- Modify: `Sources/TakometaCore/Label/MenuBarColumns.swift`
- Modify: `Sources/TakometaCore/Label/MenuBarLabelFormatter.swift`（`columnGroup` / `formatCombinedColumns`、`resolvedPrefix` / `resolvedPrefixTitle` 削除）
- Modify: `Sources/TakometaApp/MenuBarLabelView.swift`（`MenuBarColumnsView`）
- Modify: `Sources/takometa-spike/main.swift`（`measureMenuBarColumns`）
- Test: `Tests/TakometaCoreTests/MenuBarColumnsTests.swift` / `MenuBarColumnsFormatterTests.swift` / `MenuBarColumnTitleTests.swift`（追随）

**Interfaces:**
- Produces:

```swift
public struct MenuBarColumns: Sendable, Equatable {
    public struct Group: Sendable, Equatable {
        public let provider: ProviderID
        public let columns: [MenuBarColumn]
        public init(provider: ProviderID, columns: [MenuBarColumn])
    }
    public let groups: [Group]
    public init(groups: [Group])
    public var accessibilityText: String  // 各グループ先頭に providerDisplayName を読む
}
```

- `formatCombinedColumns(codex:claude:filter:now:mode:order:kindOrders:)`（`labels` 削除）

実装上の注意:
- labelColumn（title=CL/CX・value=" " の列）と dashColumn 生成のうち labelColumn を削除。「値なし」時は `--` 列のみ残る
- `MenuBarColumn` の doc コメント（「title に入りうる値: …プロバイダーラベル…」）から旧記述を落とす
- `MenuBarColumnsView` はグループ先頭に `ProviderLogoView(provider: group.provider)` を2行ぶち抜き縦センターで置く（`HStack` 内で `frame(height: 16)` 目安）
- spike の `measureMenuBarColumns` は labelColumn タプルを削除し、ロゴ相当を `Image(systemName: "terminal").frame(height: 16)` のプレースホルダーで模擬して高さ計測の忠実性を保つ（`("CL", " ")` / `("CX", " ")` タプルを全削除）
- `columnGroup` から `resolvedPrefixTitle` の参照を外す。Compact 経路が Task 4 まで参照するため、helper 本体は残す

- [ ] **Step 1: MenuBarColumns 系テストを新構造へ書き換え、失敗を確認**（labelColumn への言明 → `groups[i].provider` への言明。`accessibilityText` は「Codex 5h 34 …」形式へ期待値変更）
- [ ] **Step 2: Core を実装し `swift test --filter 'MenuBarColumns'` PASS を確認**
- [ ] **Step 3: `MenuBarColumnsView` と spike を追随させ、`swift build` と `swift run takometa-spike menubar-metrics` の高さ判定 OK を確認**
- [ ] **Step 4: `swift test` で failure が既知1件のみを確認し、コミット** `feat: 2行表示をプロバイダロゴ+グループ構造へ変更`

---

### Task 4: Compact（ゲージ）モードの読み上げと labels 削除

**Files:**
- Modify: `Sources/TakometaCore/Label/MenuBarLabelFormatter.swift`（`formatCombinedIcons` / `icon(for:now:)`）
- Modify: `Sources/TakometaApp/MenuBarLabelView.swift`（プレビューの `"CX 週間枠 10%"` 等 → `"Codex 週間枠 10%"` 等）
- Test: `Tests/TakometaCoreTests/MenuBarIconsTests.swift`、`Tests/TakometaAppTests/MenuBarIconsRenderingTests.swift`（追随）

**Interfaces:**
- `formatCombinedIcons(codex:claude:filter:now:order:)`（`labels` パラメータ削除）
- `MenuBarIcon.accessibilityText` の内容が `"Codex 週間枠 34%"` / `"Claude 要認証"` 形式になる（構造は不変）

- [ ] **Step 1: MenuBarIcons 系テストの期待値を providerDisplayName 形式へ書き換え、失敗を確認**
- [ ] **Step 2: `icon(for:now:)` の `prefix` を `providerDisplayName(item.provider)` へ置き換え、`labels` 経路を削除して PASS を確認**（`resolveProviders` の `label` プロパティと `labels` パラメータ、および参照ゼロになった `resolvedPrefix` / `resolvedPrefixTitle` はここで全削除する）
- [ ] **Step 3: プレビュー文字列を更新し `swift build` 成功を確認**
- [ ] **Step 4: `swift test` で failure が既知1件のみを確認し、コミット** `feat: ゲージ表示の読み上げをプロバイダ名へ統一`

---

### Task 5: カスタムラベル機能の削除

**Files:**
- Modify: `Sources/TakometaApp/SettingsView.swift`（「表示ラベル」Section と `labelBinding` を削除）
- Modify: `Sources/TakometaCore/Settings/SettingsSupply.swift`（`providerLabels` 削除)
- Modify: `Sources/TakometaCore/Settings/ProviderSettings.swift`（`label` プロパティ・CodingKey・init 引数を削除）
- Modify: `Sources/TakometaCore/Settings/SettingsStore.swift`（dictionary decode / encode から `label` を削除。既存の未知キーは保持）
- Test: `Tests/TakometaCoreTests/SettingsSupplyTests.swift` / `ProviderSettingsTests.swift` / `SettingsMigrationTests.swift`（追随）

**Interfaces:**
- Consumes: なし（削除のみ）
- Produces: `ProviderSettings` から `label` が消える。**永続化済みの `label` キーは `decodeIfPresent` ベースのため無視されてエラーにならないこと**をテストで固定する

実装上の注意: `SettingsStoreTests` の `label` 自体を検証するテストは削除する。欠落時の既定値や型不一致耐性を検証するテストは、`usageThreshold` など存続するフィールドへ置き換えて残す。

- [ ] **Step 1: 「旧 label キーを含む JSON をデコードしてもエラーにならない」テストを追加**

```swift
func testDecodingIgnoresLegacyLabelKey() throws {
    let json = #"{"label": "MyCX", "show": true}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ProviderSettings.self, from: json)
    XCTAssertTrue(decoded.show)
}
```

- [ ] **Step 2: `label` 関連コードを削除し、既存テストの `label` 言及を除去して `swift test` PASS（既知1件除く）を確認**
- [ ] **Step 3: コミット** `feat: プロバイダラベル設定を廃止（ロゴ固定化）`

---

### Task 6: NOTICE・ドキュメント・最終検証

**Files:**
- Create: `NOTICE`
- Modify: `CHANGELOG.md`（`[Unreleased]` へ追記）

- [ ] **Step 1: `NOTICE` を作成**

```text
Takometa NOTICE

本アプリは以下のサードパーティ素材を含みます。

## Claude ロゴ（Sources/TakometaApp/Resources/claude-logo.svg）
- 出典: simple-icons (https://github.com/simple-icons/simple-icons) の claude.svg（無改変）
- ライセンス: CC0 1.0 Universal (https://creativecommons.org/publicdomain/zero/1.0/)
- 商標: Claude および Anthropic は Anthropic PBC の商標です。本アプリはプロバイダ識別の
  目的でのみ表示し、Anthropic による後援・承認を意味しません。

## その他の商標
- OpenAI および Codex は OpenAI, L.L.C. の商標です。本アプリはこれらのロゴを含みません。
```

- [ ] **Step 2: `CHANGELOG.md` の `[Unreleased]` に追記**

```markdown
### Changed
- メニューバーの CL / CX 表記をプロバイダロゴ（Claude はスパークマーク、Codex はターミナルシンボル）に変更
### Removed
- プロバイダ表示ラベルのカスタマイズ設定（ロゴ固定化に伴い廃止。保存済みの値は無視される）
```

- [ ] **Step 3: 設計書の検証 rubric 1〜7 を上から順に実行し、結果を PR 本文に記録**（rubric 6 の目視確認のみ「実行者: 人間」として PR に残す）
- [ ] **Step 4: コミット・push・PR 作成**（base: `main`、本文に GOAL / TESTS / INSPECTION_STATUS / RISKS / ACCEPTED_RISKS を記載。ACCEPTED_RISKS には設計書「リスク」節の商標リスクを引用）

---

## Self-Review 済み事項

- 設計書の全要件（Core グループ化 / ProviderLogoView / カスタムラベル削除 / spike 追随 / NOTICE / 読み上げ統一）に対応タスクあり
- 型名・シグネチャは Task 間で一致（`MenuBarLabel.Group` / `MenuBarColumns.Group` / `providerDisplayName`）
- 検証コマンドは実測済みベースラインに基づく（既知 failure 1件 / grep プローブは実装前 11件・16件を検出）
