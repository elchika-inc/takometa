# Claude Code モデル自動切替（レート制限閾値による降格・復帰）設計書

- Issue: [#18](https://github.com/elchika-inc/takometa/issues/18)
- 状態: 設計（実装前）
- 決定経緯: 2026-08-08 のブレインストーミング。対象範囲・監視方式・復帰方針・再開方針はユーザー決定、数値既定は提案をユーザーが承認

## 1. 目的と背景

Claude Code のレート制限使用率が閾値を超えたとき、既定モデルを自動で安価なモデルへ降格し、枠回復後に自動復帰させる。

Claude Code の製品仕様上、実行中セッションのモデルを外部から変更する手段はない（公式ドキュメントで確認済み: フック出力にモデル指定フィールドはない・`~/.claude/settings.json` の `model` は起動時のみ読まれる・`fallbackModel` はレート制限エラーでは発火しない）。したがって本機構の切替が効くのは**次に起動するセッションから**であり、実行中セッションへは通知で `/model` の手動実行を促すに留める。

監視方式は3案（Claude Code statusline 駆動・launchd 常駐ウォッチャー・takometa 組み込み）を比較し、**takometa 組み込み**を採用した（ユーザー決定）。takometa は既に Claude の使用率を正規化済み `UsageSnapshot` として保持しており、データ源を重複させずに済む。トレードオフとして「表示専用アプリにローカル設定ファイルへの書き込み副作用を持たせる」点は、オプトイン（既定 OFF）で緩和する。

## 2. 決定済みポリシー

| 項目 | 決定 | 決定者 |
|---|---|---|
| 対象 | Claude Code のみ（Codex は対象外） | ユーザー |
| 判定入力 | Claude の全 `RateLimitWindow`（5時間枠・週間枠・モデル固有枠）の `usedPercent` の最大値 | 提案を承認 |
| 段階 | `<70%` → base ／ `70–90%` → sonnet ／ `≥90%` → haiku | 提案を承認 |
| ヒステリシス | 5pt（復帰は 65% / 85% を下回ったときのみ） | 提案を承認 |
| stale / unavailable | 判定せず現状維持（「取れない＝0%」で誤復帰させない） | 提案を承認（既存の What NOT to Do の踏襲） |
| 復帰 | 自動復帰あり。遷移はログと macOS 通知に残す | ユーザー |
| 手動変更の検出時 | 自動切替を停止（suspended）して通知。再開は Settings の手動再有効化のみ | ユーザー |
| 有効化 | Settings のトグルによるオプトイン（既定 OFF） | 提案を承認 |

- base = 機能有効化時に `~/.claude/settings.json` の `model` から読み取って保存した値（現環境では `claude-fable-5[1m]`）。コードに決め打ちしない。
- sonnet / haiku の具体的なモデル文字列（例: `claude-sonnet-5`）は実装計画で確定する。ユーザー環境で有効な値を実測してから決める。

## 3. 構成

```
ClaudeUsageProvider ─ UsageStore ─┬─ MenuBarExtra / Popover（既存）
                                  └─ ModelSwitchController（新規）
                                       ├─ SwitchPolicy（純粋な状態機械）
                                       └─ ClaudeSettingsWriter（settings.json 書換）
```

### コンポーネント責務

| コンポーネント | 種別 | 責務 |
|---|---|---|
| `SwitchPolicy` | 新規（TakometaCore） | `UsageSnapshot` と現在状態から次状態と実行すべきアクション（書換・通知・停止）を返す純粋ロジック。I/O なし |
| `ClaudeSettingsWriter` | 新規（TakometaCore） | `~/.claude/settings.json` の `model` キーの読み取りと書き換え。一時ファイル＋rename のアトミック書き込み。`model` 以外のキー・値を変更しない |
| `ModelSwitchController` | 新規（TakometaApp） | `UsageStore` の更新を購読し、Policy → Writer → 通知を接続。状態ファイルの管理 |
| `SettingsView` | 既存改修 | 自動切替トグル（既定 OFF）の追加 |
| `ProviderPopoverView` | 既存改修 | 現在の段階（base / sonnet / haiku / suspended）の表示 |
| `NotificationDispatcher` | 既存利用 | 遷移・停止の macOS 通知 |

既存の設計原則「UI は正規化された `UsageSnapshot` のみを見る」を踏襲し、`SwitchPolicy` も `UsageSnapshot` だけを入力とする（生の OAuth レスポンスや認証ファイルを見ない）。

## 4. 状態機械

状態: `disabled`（トグル OFF）／ `active(stage)`（stage ∈ base, sonnet, haiku）／ `suspended`（手動変更検出）

| 現在状態 | イベント | 次状態 | アクション |
|---|---|---|---|
| disabled | トグル ON | active(base) | settings.json から base を読み取り状態ファイルへ保存 |
| active(*) | トグル OFF | disabled | base へ書き戻し（書換可能な場合のみ）、状態ファイル更新 |
| active(base) | max使用率 ≥ 70% | active(sonnet) | 書換＋通知＋ログ |
| active(base/sonnet) | max使用率 ≥ 90% | active(haiku) | 書換＋通知＋ログ |
| active(sonnet) | max使用率 < 65% | active(base) | 書換＋通知＋ログ |
| active(haiku) | max使用率 < 85% | active(sonnet) | 書換＋通知＋ログ |
| active(haiku) | max使用率 < 65% | active(base) | 書換＋通知＋ログ（sonnet を経由せず直接復帰） |
| active(*) | snapshot が stale / unavailable | 現状維持 | なし |
| active(*) | 書換前チェックで手動変更検出 | suspended | 書換せず通知＋ログ |
| suspended | 使用率の変動 | suspended | なし（監視は再開しない） |
| suspended | Settings で再有効化 | active(base) | base を再取得して保存（手動変更後の値を新しい base とするかは再有効化時にユーザーの現在値をそのまま base として読み直す） |

## 5. settings.json 書き換えプロトコル

1. 書き換えの直前に現在の `model` 値を読み取る
2. 現在値が「保存済みの base」「自分が最後に書いた値」のどちらでもない場合、手動変更とみなして `suspended` へ遷移し、書き換えない
3. 遷移が必要な場合のみ、一時ファイルへ全文を書き出して rename（アトミック）
4. 状態ファイル（`~/Library/Application Support/Takometa/model-switch-state.json` を想定。正確な配置は実装計画で確定）へ `base` / `lastWritten` / `stage` / 遷移ログ（日時・旧→新・根拠の使用率）を記録

補足:

- takometa は単一インスタンス前提のため、自プロセス内の書き込み競合は考慮しない。Claude Code 自身や他ツールが `settings.json` を書き換えた場合は手順2の手動変更検出で拾う
- 書き換えは `model` 値のみの最小差分を優先する（JSON 全体の再シリアライズでキー順が変わると、ユーザーが手で管理しているファイルに差分ノイズが出るため）。実現方法は実装計画で確定する

## 6. 制約・受容リスク

- 切替が効くのは次に起動するセッションから。実行中セッションへは通知で `/model` の手動実行を促す（受容）
- takometa が起動していない間は機構ごと停止する（メニューバー常駐アプリのため常時起動前提。受容）
- `AGENTS.md` の dev-data-safety 記述を「ローカル設定ファイル（`~/.claude/settings.json`）への書き込みあり（オプトイン時のみ）」へ更新する（実装 PR に含める）

## 7. 実装時の実測項目（Measure First）

実装計画を書く前に以下を実測し、結果を実装計画に確定値として記載する:

1. `/model` の実行が `~/.claude/settings.json` へ書き戻されるか（書き戻される場合は手動変更検出の経路に入る。版依存の可能性）
2. `UsageSnapshot` に週間枠・モデル固有枠がどのラベルで入ってくるか（実データで確認し、`usedPercent` 最大値の対象を確定）
3. `settings.json` 書き換え後の Claude Code 新セッションが実際に降格先モデルで起動するか（実機で1回検証）
4. sonnet / haiku としてユーザー環境で有効なモデル文字列

## 8. テスト計画

- `SwitchPolicy` 単体テスト（純粋関数のため fixture 不要）:
  - 閾値境界: 69.9% / 70.0% / 89.9% / 90.0%
  - ヒステリシス: sonnet で 66% → 復帰しない、64.9% → base へ復帰。haiku で 86% → 維持、84.9% → sonnet へ
  - stale / unavailable スナップショットで現状維持
  - suspended では使用率によらず遷移しない
- `ClaudeSettingsWriter` テスト（一時ディレクトリの fixture settings.json）:
  - `model` 以外の全キーが書き換え後も保存される
  - 手動変更（想定外の現在値）で書き換えせず検出を報告する
  - 書き込み失敗時に元ファイルが壊れない（一時ファイル方式の検証）
- `ModelSwitchController`: 遷移時に通知と状態ファイル記録が行われる（テスト可能な範囲で）

## 9. スコープ外

- Codex のモデル切替（対象外と決定済み）
- 実行中セッションへの即時反映（製品仕様上不可）
- statusline・launchd 等の takometa 外の監視経路
- 閾値・降格先の設定 UI（初版は固定値。可変化は必要が実証されてから）
