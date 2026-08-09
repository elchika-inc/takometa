# #20 プロバイダロゴ表示 設計書

Issue: https://github.com/elchika-inc/takometa/issues/20

## 背景・目的

メニューバーの1行テキスト表示・2行カラム表示は、プロバイダを `CL` / `CX` という文字列プレフィックスで識別している。一目で判別しにくいため、アイコン（プロバイダロゴ）に置き換える。

## 用語

- **プロバイダロゴ（providerLogo）**: 本設計で導入する、プロバイダ識別用のグラフィック。既存の `DisplayMode.compact`（rawValue `"icon"`、UI 表記「アイコン表示」= ゲージアイコン）とは別概念。コード・設定文言・ドキュメントで「アイコン」と呼ばず「プロバイダロゴ」と呼ぶ。

## 決定事項と経緯

| 項目 | 決定 | 経緯 |
|---|---|---|
| Claude のロゴ | simple-icons の `claude.svg`（スパークマーク） | 公式ロゴ同梱を検討したが、Anthropic の公開ブランドガイドラインは 404 で再配布許可の一次情報が確認できず。simple-icons は CC0 1.0 で配布しており OSS の実務標準 |
| Codex のロゴ | SF Symbols `terminal` | OpenAI はロゴ使用に事前の書面同意を要求（Brand Guidelines / App Developer Terms）。simple-icons も OpenAI / ChatGPT / Codex を「Defensible（商標権者が防衛的）」と分類して収録を見送っている（simple-icons#14748）ため、同梱はどの経路でもリスクが高い。`apple.terminal` は Apple 製品アイコンのため使わない |
| 色 | モノクロ（テーマ追従、`.primary`） | macOS メニューバー慣例。数値の警告色（オレンジ/赤）を埋もれさせない |
| 適用範囲 | メニューバーの1行表示・2行表示 | ポップオーバーのカード（Codex / Claude のフルネーム）と設定画面の表記は現状維持 |
| カスタムラベル機能 | 廃止（ロゴ固定） | 設定画面の「プロバイダラベル（最大6文字）」入力欄と関連経路を削除。永続化済みの値は読まずに放置（マイグレーション不要） |

### 実測済みの前提

- NSImage は本環境（macOS 26）で SVG を直接読み込める（`NSImage(contentsOfFile:)` で 24×24 が得られることを確認済み）。SVG→PDF 等の変換パイプラインは不要。
- SF Symbols `terminal` / `sparkles` は実在する（`NSImage(systemSymbolName:)` で確認済み）。
- ベースライン: main 時点で `swift build` 成功、`swift test` は 540 件中 `FloatingPanelControllerTests.testRefreshContentSizeRestoresHostingMeasuredSize` のみ既知 failure（0 unexpected）。本変更起因ではない。

## スコープ外

- ポップオーバー（`ProviderCardsView` / `ProviderPopoverView`）へのロゴ追加
- 設定画面の表記変更（カスタムラベル入力欄の削除は除く）
- Compact（ゲージアイコン）モードの見た目変更 — 幅圧縮が存在目的のためロゴは足さない。読み上げテキストのみ更新する

## アセット

- `Sources/TakometaApp/Resources/claude-logo.svg` — simple-icons `claude.svg` を無改変で同梱（本ブランチにコミット済み。実装タスクへの入力であり、実装ステップで入手させない）
- `Package.swift` の `TakometaApp` ターゲットに `resources` 宣言を追加
- リポジトリルートに `NOTICE` を新規作成: simple-icons の出典・CC0 1.0 の明記、Claude / Anthropic / OpenAI / Codex の商標が各社に帰属する旨の帰属表示

## アーキテクチャ変更

### Core（TakometaCore）— プレフィックス文字列の廃止とグループ構造化

UI 詳細（SVG ファイル名・SF Symbols 名）は Core に置かない。Core は `ProviderID` を露出し、ロゴへの写像は表示層が持つ（既存の `GaugeLevel` → SF Symbols 名と同じ原則）。

1. **`MenuBarLabel`（1行表示）**: フラットな `segments` から、プロバイダ単位のグループ構造へ変更する。

   ```swift
   public struct MenuBarLabel {
       public struct Group {
           public let provider: ProviderID
           public let segments: [LabelSegment]
       }
       public let groups: [Group]
   }
   ```

   - `format()` はプレフィックスセグメント（`"CL "` 等）を生成しない。
   - プロバイダ間の区切りセグメント（`"  "`）も生成しない。区切りは表示層のレイアウト（`HStack` spacing）へ移す。

2. **`MenuBarColumns`（2行表示）**: `groups: [[MenuBarColumn]]` にプロバイダを持たせ、labelColumn（title=CL/CX・value=空白の無理やりな列）を削除する。

   ```swift
   public struct MenuBarColumns {
       public struct Group {
           public let provider: ProviderID
           public let columns: [MenuBarColumn]
       }
       public let groups: [Group]
   }
   ```

3. **削除**: `resolvedPrefix` / `resolvedPrefixTitle` / `format(customPrefix:)` / `formatCombined(labels:)` / `formatCombinedColumns(labels:)` / `formatCombinedIcons(labels:)` の customPrefix・labels 系パラメータと `SettingsSupply.providerLabels`。

4. **アクセシビリティ**: プロバイダ名は `providerDisplayName(ProviderID) -> String`（"Codex" / "Claude"）として Core に置き、全読み上げ経路（1行・2行・Compact・値なし・要認証）の先頭に含める。例: 「Claude 5h 16% …」「Codex 要認証」。既存の "CL 要認証" 等は置き換える。

### 表示層（TakometaApp）

1. **`ProviderLogoView`（新規）**: `ProviderID` を受け取り描画する。
   - `.claude`: `Bundle.module` の `claude-logo.svg` を `NSImage` で読み込み、`Image(nsImage:).renderingMode(.template)` + `.foregroundStyle(.primary)` で描画。
   - `.codex`: `Image(systemName: "terminal")`。
   - ロゴ読み込み失敗時（バンドル破損等）は握りつぶさず `os_log` で記録し、SF Symbols `sparkles` へフォールバックする（アイコン固定の決定に従い、テキスト CL には戻さない）。読み込みは起動後の初回描画時に1度だけ行いキャッシュする。
2. **1行表示（`MenuBarSegmentView`）**: グループごとに `ProviderLogoView`（高さ ≈ フォントサイズ 12pt 相当）+ セグメント群を `HStack` で並べる。グループ間 spacing は従来の `"  "` セグメントと同等の視覚間隔にする。
3. **2行表示（`MenuBarColumnsView`）**: グループ先頭に、2行ぶち抜きで縦センターに `ProviderLogoView` を置く。labelColumn 由来の VStack は不要になる。
4. **Compact モード**: 描画は現状維持。`accessibilityText` のみ Core 側の変更（プロバイダ名化）が反映される。
5. **`accessibilityLabel`**: 1行表示は従来 `label.text` を渡していた。新構造では `MenuBarLabel` にプロバイダ名込みの `accessibilityText` を持たせ、それを渡す（2行・Compact と同じ方式に揃える）。

### 設定画面（SettingsView）

- カスタムラベルの `TextField` と説明文（「空欄で既定（CX/CL）に戻ります」）を削除する。
- 永続化キーは削除せず、読み取らないだけにする（将来同名キーを別用途に再利用しない — 旧値が残存しているため）。

### spike（takometa-spike）

- `menubar-metrics` サブコマンド（`measureMenuBarColumns`）の計測 fixture で使う `("CL", " ")` / `("CX", " ")` の labelColumn 相当は、新グループ構造に追随する。ロゴは同サイズのプレースホルダー画像（SF Symbols）で模擬し、高さ計測が実ビューを反映し続けるようにする。

## テスト方針

- 本変更は表示仕様の変更であり、CL/CX プレフィックスを前提とする既存テストは「旧仕様の素材」ではなく更新対象。新構造（groups・provider・accessibilityText）に合わせて書き換える。
- 追加するテスト:
  - formatter: 各表示モードでグループの `provider` と並び順・区切りセグメント不在を検証
  - accessibility: 全経路（値あり・値なし・stale・要認証）で "Codex" / "Claude" が読み上げに含まれることを検証
  - アセット: `Bundle.module` から `claude-logo.svg` が読み込めることを検証（存在＋`NSImage` 化成功まで。「表示される」ことの検証は目視確認で補う）
- 既知 failure（`FloatingPanelControllerTests.testRefreshContentSizeRestoresHostingMeasuredSize`）は本変更の合否判定から除外する。

## 検証 rubric（SuccessCriteria）

1. `swift build` が成功する
2. `swift test` の failure が既知の1件（上記）のみである
3. `grep -rn 'resolvedPrefix\|customPrefix\|providerLabels' Sources/` が 0 件
4. `grep -rn '"CL[" ]\|"CX[" ]' Sources/TakometaCore Sources/TakometaApp` が 0 件（プレビューの読み上げ例 `"CX 週間枠 10%"` 等も対象に含む。spike の表記更新は 5. で確認）
5. `grep -n '"CL"\|"CX"' Sources/takometa-spike/main.swift` が 0 件（`menubar-metrics` サブコマンドの計測 fixture がロゴ相当の模擬に追随していること）
6. `scripts/make-app.sh` で生成したアプリを起動し、メニューバー1行・2行表示でロゴが表示されることを目視確認（実行者: 人間）
7. `NOTICE` に simple-icons 出典・CC0・商標帰属が記載されている

## リスク

- **商標**: simple-icons 経由でも Claude スパークマークの商標権は Anthropic に帰属する。識別目的の使用（nominative use）で改変なし・帰属明記のため許容範囲と判断するが、法的保証はない。要請があれば差し替える前提（ACCEPTED_RISKS として記録）。
- **非対称な見た目**: Claude はブランドロゴ・Codex は汎用シンボルで統一感が落ちる。simple-icons への OpenAI 収録が解禁された場合に差し替え可能なよう、写像は `ProviderLogoView` に閉じる。
- **SVG 読み込みの OS 依存**: NSImage の SVG 対応は macOS 13+ の挙動。本アプリのデプロイターゲット（macOS 14+）では問題ないことを実測済み。
