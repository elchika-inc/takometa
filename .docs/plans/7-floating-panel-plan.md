# フローティングパネル 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 使用量の詳細を常時最前面のフローティングパネルとして表示できるようにする。

**Architecture:** SwiftUI の `Window` シーンを1つ追加し、既存の `ProviderPopoverView` をそのまま載せる。`windowLevel(.floating)` で最前面に固定する。開閉状態は `SettingsStore` を正本として `provider-settings.json` に保存し、位置・サイズは OS の frame 復元に任せる。`TakometaCore` の変更は設定項目1つの追加のみ。

**Tech Stack:** Swift 6.2 / SwiftUI / XCTest / SwiftPM

**設計書:** [`7-floating-panel-design.md`](7-floating-panel-design.md) — 判断の根拠はすべてこちらにある。

## Global Constraints

- ビルドとテストにはフル Xcode 26.6 が必要。Command Line Tools のみでは `PreviewsMacros` が不足してビルドできない
- 検証コマンドは `swift build` と `swift test`。`;` や `&&` で連結せず個別に実行する
- `TakometaCore` は UI 詳細を持たない。ウィンドウ ID や SwiftUI の型は `TakometaApp` 側にのみ書く
- エージェントは `main` へ直接コミットしない。本計画の実装は `feat/7-floating-panel` ブランチで行う（設計書のコミット `d381528` が既に乗っている）
- コミットメッセージは日本語の Conventional Commits 形式（既存履歴に準拠）
- **Task 4 の実機確認は委譲対象外**。委譲先は Task 1〜3 と、Task 4 のうち CHANGELOG・コミット・PR のみを行う

## 事前確認

- [ ] **ブランチを確認する**

```bash
git branch --show-current
```

期待: `feat/7-floating-panel`。異なる場合は `git checkout feat/7-floating-panel`。

---

### Task 1: 設定項目 showsFloatingPanel を追加する

パネルの開閉状態を永続化する。既存の `menuBarLineCount` と同じ経路に乗せる。

**Files:**
- Modify: `Sources/TakometaCore/Settings/SettingsDocument.swift`
- Modify: `Sources/TakometaCore/Settings/SettingsStore.swift`
- Test: `Tests/TakometaCoreTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: なし
- Produces: `SettingsStore.showsFloatingPanel: Bool`（読み取り専用プロパティ）と `SettingsStore.updateShowsFloatingPanel(_ shows: Bool)`。永続化キーは `"showsFloatingPanel"`、既定値は `false`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/TakometaCoreTests/SettingsStoreTests.swift` のクラス内に追加する。既存の `withTemporaryDirectory` / `writeJSON` / `makeStore` / `jsonObject(in:)` ヘルパーを使う。**fixture は必ず `writeJSON` で書くこと**（`withTemporaryDirectory` は URL を返すだけでディレクトリの実体を作らない）。

```swift
func testShowsFloatingPanelDefaultsToFalseWhenKeyIsAbsent() throws {
    try withTemporaryDirectory { directory in
        try writeJSON("""
        {"version":1,"displayMode":"full","providerOrder":["codex","claude"],"providers":{}}
        """, in: directory)

        let store = try makeStore(directory: directory)
        XCTAssertFalse(store.showsFloatingPanel)
    }
}

func testShowsFloatingPanelRoundTrips() throws {
    try withTemporaryDirectory { directory in
        let store = try makeStore(directory: directory)
        XCTAssertFalse(store.showsFloatingPanel)

        store.updateShowsFloatingPanel(true)

        let saved = try jsonObject(in: directory)
        XCTAssertEqual(saved["showsFloatingPanel"] as? Bool, true)

        let reloaded = try makeStore(directory: directory)
        XCTAssertTrue(reloaded.showsFloatingPanel)
    }
}

func testShowsFloatingPanelIgnoresNonBooleanValue() throws {
    try withTemporaryDirectory { directory in
        try writeJSON("""
        {"version":1,"displayMode":"full","showsFloatingPanel":"yes",
         "providerOrder":["codex","claude"],"providers":{}}
        """, in: directory)

        let store = try makeStore(directory: directory)
        XCTAssertFalse(store.showsFloatingPanel)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
swift test --filter SettingsStoreTests
```

期待: `showsFloatingPanel` が存在せずコンパイルエラー。

- [ ] **Step 3: SettingsDocument にフィールドを追加する**

`Sources/TakometaCore/Settings/SettingsDocument.swift` を次に置き換える。

```swift
public struct SettingsDocument: Sendable, Equatable {
    public var version: Int
    public var displayMode: DisplayMode
    public var providerOrder: [String]
    public var menuBarLineCount: MenuBarLineCount
    public var showsFloatingPanel: Bool
    public var providers: [String: ProviderSettings]

    public init(
        version: Int = 1,
        displayMode: DisplayMode = .full,
        providerOrder: [String] = [ProviderID.codex.rawValue, ProviderID.claude.rawValue],
        menuBarLineCount: MenuBarLineCount = .one,
        showsFloatingPanel: Bool = false,
        providers: [String: ProviderSettings] = [
            ProviderID.codex.rawValue: ProviderSettings(),
            ProviderID.claude.rawValue: ProviderSettings(),
        ]
    ) {
        self.version = version
        self.displayMode = displayMode
        self.providerOrder = providerOrder
        self.menuBarLineCount = menuBarLineCount
        self.showsFloatingPanel = showsFloatingPanel
        self.providers = providers
    }
}
```

- [ ] **Step 4: SettingsStore の8箇所を変更する**

`Sources/TakometaCore/Settings/SettingsStore.swift` を順に変更する。**`menuBarLineCount` を書いている箇所の直後に、同じ形で `showsFloatingPanel` を足す**のが基本方針。

1. プロパティ宣言（`:7` の直後）

```swift
    public private(set) var showsFloatingPanel: Bool
```

2. `init` の初期化（`menuBarLineCount = .one` の直後）

```swift
        showsFloatingPanel = false
```

3. `init` 内の `makeRootObject` 呼び出し（`:38-42`）に引数を追加

```swift
            rootObject = Self.makeRootObject(
                displayMode: displayMode,
                providerOrder: providerOrder,
                menuBarLineCount: menuBarLineCount,
                showsFloatingPanel: showsFloatingPanel,
                providers: providers)
```

4. 更新メソッドを追加（`updateMenuBarLineCount` の直後）

```swift
    public func updateShowsFloatingPanel(_ shows: Bool) {
        showsFloatingPanel = shows
        save()
    }
```

5. `apply(_:)` に追加

```swift
        showsFloatingPanel = document.showsFloatingPanel
```

6. `regenerateDefaults()` 内の `makeRootObject` 呼び出しにも同じ引数を追加（3 と同じ形）

7. `save()` の書き込み（`object["menuBarLineCount"] = ...` の直後）

```swift
        object["showsFloatingPanel"] = showsFloatingPanel
```

8. `decodeDocument(from:)` の読み取りと `SettingsDocument` 構築

```swift
        let showsPanel = object["showsFloatingPanel"] as? Bool ?? false
```

```swift
        return SettingsDocument(
            version: integer(from: object["version"]) ?? 1,
            displayMode: mode,
            providerOrder: normalizeProviderOrder(
                rawOrder,
                providerIDs: Set(decodedProviders.keys)),
            menuBarLineCount: lineCount,
            showsFloatingPanel: showsPanel,
            providers: decodedProviders)
```

9. `makeRootObject` の引数と返り値（`:259-278`）

```swift
    private static func makeRootObject(
        displayMode: DisplayMode,
        providerOrder: [String],
        menuBarLineCount: MenuBarLineCount,
        showsFloatingPanel: Bool,
        providers: [String: ProviderSettings]
    ) -> [String: Any] {
        var rawProviders: [String: Any] = [:]
        for (id, settings) in providers {
            var rawSettings: [String: Any] = [:]
            replaceKnownFields(in: &rawSettings, with: settings)
            rawProviders[id] = rawSettings
        }
        return [
            "version": 1,
            "displayMode": displayMode.rawValue,
            "providerOrder": providerOrder,
            "menuBarLineCount": menuBarLineCount.rawValue,
            "showsFloatingPanel": showsFloatingPanel,
            "providers": rawProviders,
        ]
    }
```

- [ ] **Step 5: テストが通ることを確認する**

```bash
swift test
```

期待: 全 PASS。`showsFloatingPanel` は新規キーのため、既存ファイルを読むテストは `?? false` で既定値が入り影響を受けない。**もし既存テストが落ちたら、期待値を書き換えず停止して報告すること**（新規キー追加で既存挙動が変わるのは想定外であり、実装の誤りを示す）。

- [ ] **Step 6: コミット**

```bash
git add Sources/TakometaCore/Settings/SettingsDocument.swift \
        Sources/TakometaCore/Settings/SettingsStore.swift \
        Tests/TakometaCoreTests/SettingsStoreTests.swift
git commit -m "feat: パネルの開閉状態を保存する設定項目を追加

showsFloatingPanel を menuBarLineCount と同じ経路で永続化する。新規キーの
ため既定値 false が入るだけで、既存の設定ファイルへの影響はない。

Refs #7"
```

---

### Task 2: Window シーンと開閉ボタンを追加する

パネルを実体として出し、ポップオーバーから開閉できるようにする。

**Files:**
- Modify: `Sources/TakometaApp/TakometaApp.swift`
- Modify: `Sources/TakometaApp/ProviderPopoverView.swift`

**Interfaces:**
- Consumes: Task 1 の `SettingsStore.showsFloatingPanel` / `updateShowsFloatingPanel(_:)`
- Produces: `TakometaApp.panelWindowID`（`static let`、値は `"takometa-panel"`）。Task 3 の起動時復元がこの ID を使う

- [ ] **Step 1: ウィンドウ ID とシーンを追加する**

`Sources/TakometaApp/TakometaApp.swift` の `struct TakometaApp: App {` の直後に定数を置く。

```swift
    /// Window シーンの宣言側と openWindow(id:) の呼び出し側で共有する。
    /// literal を2か所に置くと、片方だけ変えたときに黙って開かなくなる。
    static let panelWindowID = "takometa-panel"
```

`body` の `Settings { ... }` の直後にシーンを追加する。

```swift
        Window("Takometa", id: Self.panelWindowID) {
            ProviderPopoverView(store: store, settingsStore: settingsStore)
        }
        .windowLevel(.floating)
        .windowResizability(.contentSize)
```

- [ ] **Step 2: ポップオーバーに開閉ボタンを追加する**

`Sources/TakometaApp/ProviderPopoverView.swift` の最下段 `HStack` にある `SettingsLink` の**手前**へボタンを追加する。

```swift
                Button(
                    settingsStore.showsFloatingPanel ? "パネルを隠す" : "パネルを表示",
                    systemImage: "macwindow"
                ) {
                    settingsStore.updateShowsFloatingPanel(!settingsStore.showsFloatingPanel)
                }
```

`ProviderPopoverView` はパネルの中身としても使われるため、パネル内にも同じボタンが出る。これは意図した挙動で、パネル側からも閉じられる。

- [ ] **Step 3: 設定変更を窓の開閉へ結びつける**

`Sources/TakometaApp/TakometaApp.swift` の `MenuBarExtra` の label に付いている修飾子群へ追加する。`openWindow` / `dismissWindow` は `@Environment` 経由でしか取れず `Scene` 直下では使えないため、label 内の View で扱う。

`MenuBarLabelView(...)` に続く修飾子の最後に次を足す。

```swift
                .modifier(FloatingPanelPresenter(
                    windowID: Self.panelWindowID,
                    isPresented: settingsStore.showsFloatingPanel))
```

同ファイルの末尾に `FloatingPanelPresenter` を追加する。

```swift
/// 設定を正本として窓の開閉を追従させる。openWindow / dismissWindow は
/// View の Environment からしか取れないため、label 側へ寄せている。
private struct FloatingPanelPresenter: ViewModifier {
    let windowID: String
    let isPresented: Bool

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onChange(of: isPresented, initial: false) { _, shows in
            if shows {
                openWindow(id: windowID)
            } else {
                dismissWindow(id: windowID)
            }
        }
    }
}
```

- [ ] **Step 4: ビルドを通す**

```bash
swift build
```

期待: エラーなし。

- [ ] **Step 5: テスト全体を通す**

```bash
swift test
```

期待: 全 PASS。

- [ ] **Step 6: コミット**

```bash
git add Sources/TakometaApp/TakometaApp.swift Sources/TakometaApp/ProviderPopoverView.swift
git commit -m "feat: 常時最前面のフローティングパネルを追加

Window シーンへ既存の ProviderPopoverView をそのまま載せ、windowLevel を
floating に固定した。開閉はポップオーバー最下段のボタンから行い、設定の
変更に窓が追従する。

Refs #7"
```

---

### Task 3: 起動時の復元と閉じたことの書き戻しを実装する

設定と実体のずれを防ぐ。設計書 §4.2 の核心部分。

**Files:**
- Modify: `Sources/TakometaApp/TakometaApp.swift`

**Interfaces:**
- Consumes: Task 2 の `panelWindowID` と `FloatingPanelPresenter`
- Produces: なし（表示層の末端）

- [ ] **Step 1: 起動時の復元を追加する**

`FloatingPanelPresenter` の `body(content:)` に `.task` を足す。`onChange` は値が変わったときにしか発火しないため、起動直後の復元には別の入口が要る。

```swift
    func body(content: Content) -> some View {
        content
            .task {
                if isPresented { openWindow(id: windowID) }
            }
            .onChange(of: isPresented, initial: false) { _, shows in
                if shows {
                    openWindow(id: windowID)
                } else {
                    dismissWindow(id: windowID)
                }
            }
    }
```

- [ ] **Step 2: 窓が閉じられたことを設定へ書き戻す**

`Sources/TakometaApp/TakometaApp.swift` の `Window` シーンの中身に `onDisappear` を足す。

```swift
        Window("Takometa", id: Self.panelWindowID) {
            ProviderPopoverView(store: store, settingsStore: settingsStore)
                .onDisappear {
                    settingsStore.updateShowsFloatingPanel(false)
                }
        }
        .windowLevel(.floating)
        .windowResizability(.contentSize)
```

**この `onDisappear` がウィンドウの閉じるボタンで発火するかは未検証**（設計書 §6 のリスク2）。Task 4 の実機確認で判定する。発火しない場合の退路は設計書に記載済み。

- [ ] **Step 3: ビルドを通す**

```bash
swift build
```

期待: エラーなし。

- [ ] **Step 4: テスト全体を通す**

```bash
swift test
```

期待: 全 PASS。

- [ ] **Step 5: コミット**

```bash
git add Sources/TakometaApp/TakometaApp.swift
git commit -m "feat: パネルの開閉状態を起動時に復元し閉じたら書き戻す

設定を正本とし、窓が閉じられたら設定へ false を書き戻す。同じ事実を指す
状態が2か所にあると片方だけ動く経路が生まれるため、実体の変化を必ず設定へ
戻す。

Refs #7"
```

---

### Task 4: 実機確認と仕上げ

**Files:**
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: Task 1〜3 のすべて
- Produces: なし

> **委譲時の注意:** Step 1〜4 は実機確認であり委譲対象外。委譲先は Step 5 以降のみを行い、PR 本文に「実機目視確認は未実施」と明記する。

- [ ] **Step 1: アプリをビルドして起動する**

```bash
scripts/make-app.sh
```

```bash
open dist/Takometa.app
```

- [ ] **Step 2: 設計書 §6 のリスク1を判定する**

メニューバーのポップオーバーから「パネルを表示」を押す。

- パネルが前面に出るか。出ない場合は `FloatingPanelPresenter` の `openWindow` 呼び出しの直後に `NSApp.activate(ignoringOtherApps: true)` を足す
- 他アプリを前面にしてもパネルが浮いたままか（`windowLevel(.floating)` の確認）

- [ ] **Step 3: 設計書 §6 のリスク2を判定する**

パネルの閉じるボタン（×）を押し、設定ファイルを確認する。

```bash
python3 -c "
import json, pathlib
p = pathlib.Path.home() / 'Library/Application Support/Takometa/provider-settings.json'
print(json.load(p.open()).get('showsFloatingPanel'))
"
```

期待: `False`。`True` のままなら `onDisappear` が発火していない。退路は `NSWindow.delegate` を設定して `windowWillClose` で書き戻す方式（設計書 §6）。

- [ ] **Step 4: 設計書 §6 のリスク3を判定する**

パネルを任意の位置へ動かし、アプリを終了して再起動する。

- パネルが自動で開くか（起動時復元）
- 同じ位置・サイズで開くか。異なる場合は `setFrameAutosaveName` の明示が必要

- [ ] **Step 4b: 閉じた状態が保たれることを確認する**

`showsFloatingPanel` が `false` の状態でアプリを終了し、再起動する。

- パネルが**開かない**こと

macOS のウィンドウ状態復元が `Window` シーンを勝手に開き直す可能性があるため、明示的に確認する。開いてしまう場合は、シーンに `.restorationBehavior(.disabled)` を付ける（存在しなければ `NSWindow.isRestorable` を `false` にする）。

- [ ] **Step 4c: ボタン3つが幅360に収まることを確認する**

ポップオーバー最下段に「パネルを表示」「設定」「終了」の3ボタンが並ぶ。`ProviderPopoverView` は `.frame(width: 360)` 固定であるため、収まらないと折り返しや切り詰めが起きる。

収まらない場合の対処は次のいずれか。実機で見て決める。

- 追加したボタンだけ `.labelStyle(.iconOnly)` にする
- ボタン行を2段に分ける

- [ ] **Step 5: CHANGELOG を更新する**

`CHANGELOG.md` の `[Unreleased]` に追記する。

```markdown
### Added

- 使用量の詳細を常時最前面のフローティングパネルとして表示できるようにした。メニューバーのポップオーバー最下段の「パネルを表示」から開閉でき、開いた状態と位置はアプリを再起動しても保たれる
```

- [ ] **Step 6: コミットしてプッシュする**

```bash
git add CHANGELOG.md
git commit -m "docs: フローティングパネルの追加を CHANGELOG へ追記

Refs #7"
```

```bash
git push -u origin feat/7-floating-panel
```

- [ ] **Step 7: PR を作成する**

```bash
gh pr create --title "常時最前面のフローティングパネルを追加する" --body "$(cat <<'BODY'
Closes #7

## 変更内容

使用量の詳細を常時最前面のフローティングパネルとして表示できるようにした。

- SwiftUI の `Window` シーンへ既存の `ProviderPopoverView` をそのまま載せる（新規ビューなし）
- `windowLevel(.floating)` で最前面に固定
- 開閉はポップオーバー最下段のボタン。開閉状態は `provider-settings.json` へ保存し起動時に復元
- 位置・サイズは OS の frame 復元に任せる

WidgetKit を採らなかった理由（App Group entitlement が Team ID 付き署名を要し、ad-hoc 署名と配布方針に反する）は設計書 `.docs/plans/7-floating-panel-design.md` §1 に記載。

## 検証

- `swift build` / `swift test` 完走
- 実機目視確認は未実施

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

---

## レビューサイクル

コード変更を含むため、プロジェクト CLAUDE.md のレビューサイクル表に従い、`swift build` / `swift test` 通過後に次のレビュアーを起動する。flag された確信度80%以上の指摘が0になるまで「修正 → 再レビュー」を反復する。

| 条件 | レビュアー |
|---|---|
| コード変更（常時） | `pr-review-toolkit:code-reviewer` |
| テストを追加（Task 1） | `pr-review-toolkit:pr-test-analyzer` |
| コメントを追加（全タスク） | `pr-review-toolkit:comment-analyzer` |

新しい型を追加しないため `type-design-analyzer` は対象外。try-catch / フォールバックを書かないため `silent-failure-hunter` も対象外。
