# PROJECT_GOAL — Takometa

本文書が Takometa のゴールと完了条件の正本である。

## Outcome

Codex と Claude Code のレート制限（5時間枠・週間枠・モデル固有枠）を、macOS メニューバーで常時確認できるようにする。

## Scope

- Codex: `codex app-server` の JSON-RPC 経由での制限取得と通知購読。
- Claude Code: OAuth usage 経路での制限取得と、`statusLine` によるフォールバック取得（2026-07-20 に Phase 1 では OAuth のみとし Phase 2 で再評価する決定を行い、再評価の結果 Phase 2 で実装済み）。
- `MenuBarExtra` 常駐 UI（メニューバー短縮表示 + ポップオーバー詳細）。
- 鮮度（fresh / stale / unavailable / authenticationRequired / rateLimitReached）の区別表示。
- 各制限ウィンドウの平均消費ペース（スナップショット単体からのステートレス算出）と直近ペース（履歴ベース）、上限到達予測（平均から算出。ポップオーバー中心 + 危険時のみメニューバー強調）。

## OutOfScope

- Cursor / Gemini / Copilot 等の他プロバイダー対応。
- API 利用料金・コスト集計、利用履歴グラフ、複数アカウント。
- Mac App Store 配布（署名・公証・Homebrew Cask は Phase 2 で再評価）。

## Constraints

- 既存ログイン情報を読み取り専用で再利用する。独自サーバー・独自アカウントを持たない。
- 通信先は OpenAI / Anthropic の公式ホストのみ。
- 秘密（トークン・Cookie）をログ・fixture・UI へ露出しない。
- Swift 6.2 + SwiftUI、`LSUIElement` 常駐アプリ。
- ソースコードは MIT ライセンスで公開する。ビルド済みアプリの配布は身内向けの直接配布に限り、GitHub Release でのバイナリ配布・Homebrew Cask への登録・Apple の署名と公証は行わない。

## SuccessCriteria

以下を満たしたときに Outcome を達成したとみなす。

- [ ] Full モードで Codex の5時間枠・週間枠がメニューバー上で常時確認できる。
- [ ] Full モードで Claude Code の5時間枠・週間枠・使用率上位2モデル固有枠が常時確認でき、取得可能な全モデル固有枠はポップオーバーで確認できる。
- [ ] ポップオーバーから全制限とリセット時刻を確認できる。
- [ ] 新しいモデル固有枠がアプリ更新なしでラベル付き行として表示される。
- [ ] 取得不能時に 0% と表示せず、stale / unavailable として区別される。
- [ ] 各制限ウィンドウについて、現在ペース維持時の到達予測（またはリセットまで持つ見込み）がポップオーバーで確認できる。
- [ ] 直近の消費ペースが平均と区別してポップオーバーで確認できる。
- [ ] 公式画面（Codex / Claude Code の `/usage`）との実機突合で使用率とリセット時刻が一致する。

## DoneCriteria（現フェーズ: Phase 3-B ソース公開）

- [ ] 新規 public リポジトリが存在し、`LICENSE` が REST API で `MIT` として検出される。
- [ ] `SECURITY.md` が脆弱性の私的報告経路を示している。
- [ ] 公開リポの初期コミット時点で、旧リポの内部作業記録（設計書・レビュー記録・引き継ぎ・競合調査・アイデア文書）が1件も含まれない。公開後に新規作成する設計書は `plans/` へ置く。
- [ ] `swift build` / `swift test` / `scripts/make-release.sh` が公開リポで完走する。

## Deliverables

- Phase 0: 取得スパイク CLI + fixture 一式 + 判定記録（実施済み）。
- Phase 1: MVP アプリ（実施済み）。
- Phase 2: 表示・設定・通知・配布準備（実施済み）。
- Phase 3-A: 使用量履歴と直近ペース（実施済み）。
- Phase 3-B: 公開リポジトリ + `LICENSE` + `SECURITY.md`。
