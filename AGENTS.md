# takometa

## Project Overview

Codex と Claude Code のレート制限（5時間枠・週間枠・モデル固有枠）を macOS メニューバーで常時確認できる個人向けネイティブアプリ「Takometa（タコメータ）」。

- ゴール・完了条件の正本: [.docs/PROJECT_GOAL.md](.docs/PROJECT_GOAL.md)
- 現在フェーズ: Phase 3-B（ソース公開）。Phase 3-A までのアプリ機能を実装済み。

## Tech Stack

- スタック: Swift 6.2 + SwiftUI の macOS ネイティブアプリ（`MenuBarExtra` 常駐・`LSUIElement`）。
- Cloudflare Web スタック（pnpm / Vite Plus / biome / design-tokens / legal）は本リポジトリでは適用外。
- standards_version: 2026-07-18 (rev.35)。
- branch_policy: `unprotected`（public リポジトリでは branch protection を利用できるが、現時点では設定していない。エージェントの `main` 直接 push 禁止は DOCS_OPS.md §5 の MUST により運用する）。

## Key Commands

ビルドとテストにはフル Xcode 26.6 が必要です。Command Line Tools のみでは `PreviewsMacros` が不足してビルドできません。

- dev: `swift build`
- test: `swift test`
- app: `scripts/make-app.sh`
- spike: `swift run takometa-spike <codex|claude|statusline> [--emit-fixture <path>]`
- check: 未採用（`swift build` / `swift test` と配布スクリプト内ゲートで検証）
- release: `scripts/make-release.sh <version>`（ローカルタグとクリーンな作業ツリーが必要）
- deploy: N/A（ソースは public、ビルド済みアプリは身内向けに直接配布）

## Architecture

現在の構成（正本は各フェーズの設計書）:

```
Codex app-server ── CodexUsageProvider ─┐
                                        ├─ UsageStore ─ MenuBarExtra / Popover
Claude OAuth ────── ClaudeUsageProvider ┤
Claude statusLine ─ fallback snapshot ──┘
```

- UI は認証ファイル・JSON-RPC・OAuth レスポンスを直接解釈せず、正規化された `UsageSnapshot` のみを見る。
- モデル固有枠は固定プロパティにせず、ラベル付き配列（動的な `RateLimitWindow`）として扱う。

## 重要な設計原則（What NOT to Do）

- 値が取得できない場合に 0% を表示しない。`RateLimitWindow` 自体を作らず、stale / unavailable を区別して表示する。
- OAuth トークン・Cookie・Authorization ヘッダーをログ・fixture・UI へ出さない。認証情報は読み取り専用で扱う。
- 通信先を OpenAI / Anthropic の公式ホスト以外へ広げない。
- 非公開データ形状（Claude OAuth usage レスポンス等）を安定 API として扱わない。デコーダーを隔離し、fixture テストと不明フィールドのログで変更を検知する。
- HTTP 200 / exit 0 / 空配列だけを成功条件にしない。妥当な制限ウィンドウ1つ以上と取得時刻を確認して成功扱いにする。
- エージェントは main へ直接コミットしない。作業ブランチへのコミットと PR 作成までは自律で行い、main へのマージは人間が承認する（正本: standards DOCS_OPS.md §5）。

## エージェント連携

- dev-data-safety: local（外部サービスへの書き込みなし。認証情報は読み取り専用）。
- routes: N/A（Web UI なし。画面は MenuBarExtra とポップオーバーのみ）。
