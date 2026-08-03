# Stats 風リングゲージカード 設計書

- Issue: [#14](https://github.com/elchika-inc/takometa/issues/14)
- 作成日: 2026-08-03
- 状態: 設計確定（実装計画は [`14-provider-cards-plan.md`](14-provider-cards-plan.md)）

## 1. 背景と決定

Stats（exelban/stats）のウィジェット——リングゲージ＋中央に%＋下に内訳——の見た目をフローティングパネルへ取り入れる。本物の WidgetKit ウィジェットは署名制約（#7 §1 と同一）により採らず、カードの View を将来 WidgetKit へ移植可能な形で作る。

役割分担を Stats に倣う: **パネル＝眺める用**（カード）、**ポップオーバー＝調べる用**（現状の詳細表示を変更しない）。

## 2. カードの構成

プロバイダごとに1カード。Stats の CPU/RAM ウィジェットと同型。

```
┌──────────┐ ┌──────────┐
│    ╭──╮    │ │    ╭──╮    │
│    │32%│   │ │    │53%│   │
│    ╰──╯    │ │    ╰──╯    │
│   Claude   │ │   Codex    │
│ ● 5h   32% │ │ ● 1w   53% │
│ ● 1w   17% │ │ ● Spark 0% │
│ ● Fable 10%│ └──────────┘
└──────────┘
```

- **リング** = そのプロバイダの最逼迫枠の使用率。選択は既存 `rankedBefore`、色は既存 `style(for:)`（normal / warning 橙 / critical 赤）を再利用する
- **内訳行** = 表示対象の全枠の「短い枠名＋%」。枠名は既存 `baseName(for:)`（`5h` / `1w` / モデル表示名）、並びは枠種別設定（`kindOrder`）に従う
- リセット時刻・ペース・更新ボタンは載せない（ポップオーバーの担当）

## 3. 退化状態（#4 の決定を踏襲）

| 状態 | カードの表現 |
|---|---|
| 値が取得できない／表示枠0個 | リング中央に `--`（**0% のリングを描かない**）、内訳行なし |
| 要認証 | リング中央に鍵アイコン、内訳行なし |
| stale | カード全体を減光（opacity 0.6）＋プロバイダ名の横に ⏱ |
| 表示 OFF のプロバイダ | カードを作らない |

stale の減光値はメニューバーアイコン（0.45）より弱い 0.6 とする。カードは面積が大きく 0.45 では読めなくなるため。判別性は #6 と同じ手法（ImageRenderer での比較描画）で実装後に確認する。

## 4. アーキテクチャ

#4 の `MenuBarIcons` と同じパターン。**選択と色のロジックは Core、View は写すだけ**。

```
TakometaCore:
  ProviderCard（値型: name / ring / rows / isStale）
  MenuBarLabelFormatter.formatProviderCards(...)  ← resolveProviders / rankedBefore /
                                                     style / baseName を再利用
TakometaApp:
  ProviderCardsView（ProviderCard の配列を描くだけ）
  FloatingPanelController.makeContent を ProviderCardsView へ差し替え
```

`formatProviderCards` は `MenuBarLabelFormatter.swift` 内に置く。再利用する4ヘルパーがすべて `private static` であり、同一ファイル内の宣言からのみ到達できるため。ファイル分離より再利用を優先する（ヘルパーの可視性を internal へ広げると公開面が増える）。

将来の WidgetKit 移植では、Widget の timeline provider が `ProviderCard` を組み立てて同じ View に渡す。View が `UsageStore` を直接見ないのはこのため。

## 5. スコープ外

- 使用量推移グラフ（履歴はあるが、カード定着後に判断）
- WidgetKit 化（署名導入とセットで別 Issue）
- メニューバー表示・ポップオーバーの変更
- カードのサイズ・枚数のカスタマイズ設定（YAGNI）

## 6. テストと実機確認

- Core: `formatProviderCards` の単体テスト（リング選択・退化状態・行の並び・フィルタ・percent の床関数）
- App: カードが非空画像として描画されるスモークテスト（ImageRenderer）
- 実機（依頼元が実施）: パネルでの見た目、stale 減光の判別性、パネルサイズの追従
