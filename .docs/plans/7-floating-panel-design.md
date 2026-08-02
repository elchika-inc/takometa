# フローティングパネル 設計書

- Issue: [#7](https://github.com/elchika-inc/takometa/issues/7)
- 作成日: 2026-08-02
- 状態: 設計確定（実装計画は別ファイル）

## 1. 背景

「メニューバー以外にも使用量を表示したい」という要望に対し、[#4](https://github.com/elchika-inc/takometa/issues/4) のブレストで手段を検討した。

WidgetKit のウィジェットは採らない。Widget Extension はサンドボックス必須で、本体アプリとのデータ共有には App Group entitlement を要し、App Group 識別子は Team ID プレフィックスを必要とする。現行の配布は ad-hoc 署名（`scripts/lib/make-bundle.sh:67` の `codesign --force --sign -`）であり、Team ID を持たない。採用するには Apple Developer Program への加入と配布フロー全体の再構築が前提になり、PROJECT_GOAL の Constraints「ビルド済みアプリは身内向けの直接配布」「Apple の署名と公証は行わない」と衝突する。

「デスクトップに常時見える」という目的だけなら、署名構成を一切変えずに**常時最前面のフローティングパネル**で達成できる。本設計はこちらを採る。

## 2. 実測で確認したこと

以下は 2026-08-02 に `swiftc -typecheck -target arm64-apple-macosx15.0` で型検査を通した。本リポジトリの `platforms: [.macOS(.v15)]` の範囲内で利用できる。

```swift
Window("probe", id: "probe") { Text("x") }
    .windowLevel(.floating)
    .windowResizability(.contentSize)
    .defaultWindowPlacement { _, _ in WindowPlacement(.bottomTrailing) }
```

したがって `NSPanel` を自前で生成し `NSHostingView` を載せて `level` / `collectionBehavior` / `setFrameAutosaveName` を手で設定する必要はない。CLAUDE.md の解決手段の優先順位における「フレームワーク組み込み機能」で解決できるため、自前実装へは降りない。

## 3. アーキテクチャ

### 3.1 シーンを1つ追加する

`Sources/TakometaApp/TakometaApp.swift` の `body` は現在 `MenuBarExtra` と `Settings` の2シーン。ここに3つ目を追加する。

```swift
Window("Takometa", id: TakometaApp.panelWindowID) {
    ProviderPopoverView(store: store, settingsStore: settingsStore)
}
.windowLevel(.floating)
.windowResizability(.contentSize)
```

`panelWindowID` は `TakometaApp` の `static let` として定義する。`Window` の宣言側と `openWindow(id:)` の呼び出し側で同じ文字列を使う必要があり、literal を2か所に置くと片方だけ変えたときに黙って開かなくなるため。

**表示ビューは新規に作らない。** `ProviderPopoverView` をそのまま載せる。同ビューは `.frame(width: 360)` を持ち高さは内容依存であるため、`windowResizability(.contentSize)` と組み合わせると窓サイズが内容に追従する。

`TakometaCore` の変更は設定項目1つの追加のみで、表示ロジックには一切触れない。

### 3.2 開閉の導線

`ProviderPopoverView` 最下段の `HStack`（`SettingsLink` と「終了」が並ぶ行）にボタンを1つ追加する。

```
バージョン 0.0.0-dev          [◱ パネル] [⚙ 設定] [⏻ 終了]
ビルド 27a09c3
```

トグルではなくボタンとし、`settingsStore.showsFloatingPanel` の値でラベルとアイコンを切り替える（表示中は「パネルを隠す」）。既存の2つがボタンであるため見た目が揃う。

## 4. 状態の永続化と同期

### 4.1 保存するもの／しないもの

| 対象 | 保存先 | 理由 |
|---|---|---|
| 開閉状態 | `provider-settings.json` の `showsFloatingPanel: Bool` | アプリ固有の意思。既存の `menuBarLineCount` と同じ経路に乗せる |
| 位置・サイズ | 保存しない | `Window` シーンは id 単位で OS が frame を復元する。自前で持つと二重管理になる |

`showsFloatingPanel` は `SettingsDocument` と `SettingsStore` に `menuBarLineCount` と同じ形で追加する（後者は計9箇所）。既定値は `false`。

**移行は不要。** 新しいキーであり、既存ファイルに無ければ既定値が入るだけである。[#4](https://github.com/elchika-inc/takometa/issues/4) の `DisplayMode` のような「既存の値の意味がずれる」変更ではない。

### 4.2 状態のずれを防ぐ

開閉を動かす経路が2つあることが、本設計で唯一の論点である。

1. ポップオーバーのボタン → 設定を書き換える → 窓が開閉する
2. **窓の閉じるボタン（×）** → 窓が閉じる → 設定は `true` のまま残る

2 を放置すると「設定上は表示中なのに窓がない」状態になり、再起動で勝手に復活する。同じ事実を指す状態が2か所にあると、片方だけが動く経路が必ず生まれる。

**設定を正本とし、実体の変化を必ず設定へ書き戻す。** 窓が閉じられたことを検知して `showsFloatingPanel` を `false` にする。検知手段は 6章のリスク2として実測する。

### 4.3 起動時の復元

`showsFloatingPanel == true` なら起動時に窓を開く。

`openWindow` は `@Environment(\.openWindow)` 経由でしか取得できず、`Scene` の直下では使えない。したがって `MenuBarExtra` の label 内の View で呼ぶ（既存の `.task { store.start() }` と同じ位置）。この構成が成立することは型検査で確認済み（2026-08-02）。

```swift
MenuBarExtra { ... } label: {
    MenuBarLabelView(...)
        .task {
            store.start()
            if settingsStore.showsFloatingPanel { openWindow(id: Self.panelWindowID) }
        }
}
```

`openWindow` を持つ `@Environment` は View に置く必要があるため、`MenuBarLabelView` へ渡すか、label をラップする小さな View を挟む。どちらを採るかは実装計画で決める。

## 5. データフロー

```
UsageStore ─┬─→ MenuBarLabelView    （メニューバー）
            └─→ ProviderPopoverView ─┬─→ MenuBarExtra のポップオーバー
                                     └─→ Window シーン（フローティングパネル）
                                            ↑
SettingsStore.showsFloatingPanel ───────────┘（openWindow / dismissWindow）
```

同一のビューを2か所へ載せるため、表示内容は常に一致する。表示ロジックの重複はない。

## 6. 実装時に実測が必要な項目

いずれも机上で決められない性質のもので、実装してから実機で確かめる。3件とも「外れたら AppKit へ1段降りる」という同じ形の退路があり、設計全体は崩れない。

| # | 未確認 | 確かめ方 | 退路 |
|---|---|---|---|
| 1 | `LSUIElement` アプリで `openWindow` したとき窓が前面に出るか | 実機で開く | `NSApp.activate(ignoringOtherApps:)` を添える |
| 2 | 窓を閉じたことを SwiftUI 側で検知できるか（`onDisappear` の発火） | ログを仕込んで実機確認 | `NSWindow.delegate` を設定して `windowWillClose` で書き戻す |
| 3 | 位置・サイズが再起動後に復元されるか | 動かして再起動 | `setFrameAutosaveName` を明示的に設定する |

## 7. テスト

自動テストで守れるのは `TakometaCore` 側のみ。

- `showsFloatingPanel` の往復（保存 → 再読込で値が保たれる）
- キーが無い既存ファイルを読むと `false` になる（既定値）
- 既存の `SettingsStoreTests` / `SettingsMigrationTests` が壊れないこと

表示層（窓が浮くか、閉じたら設定が戻るか、位置が復元されるか）は 6章の実機確認が担当する。**実機確認の項目は実装計画に明記し、委譲対象から外す。**

## 8. 影響範囲

| ファイル | 変更 |
|---|---|
| `Sources/TakometaCore/Settings/SettingsDocument.swift` | `showsFloatingPanel` を追加 |
| `Sources/TakometaCore/Settings/SettingsStore.swift` | 同上（プロパティ・既定値・encode・decode・update） |
| `Sources/TakometaApp/TakometaApp.swift` | `Window` シーンを追加、起動時の復元 |
| `Sources/TakometaApp/ProviderPopoverView.swift` | 開閉ボタンを追加 |
| `Tests/TakometaCoreTests/SettingsStoreTests.swift` | 往復と既定値のテストを追加 |
| `CHANGELOG.md` | `[Unreleased]` へ追記 |

## 9. スコープ外

- WidgetKit ウィジェット（1章の署名制約のため）
- パネル専用の要約ビュー。詳細表示で足りるかを使ってから判断する（YAGNI）
- パネルの複数枚表示・プロバイダ別パネル
