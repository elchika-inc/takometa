@AGENTS.md

# Claude Code固有ルール

- `/memory` で共通契約の読込を確認する。
- Claude Code固有設定を共通契約へ混在させない。
- 実行オーナー・開発サイクル・出力形式・レビュー選定・マージゲート・失敗時対応・マージコンフリクト解決の正本は [`~/.claude/references/project-template.md`](~/.claude/references/project-template.md)。
- `PROJECT_GOAL` のフィールド定義とデフォルトは [`~/.claude/references/project-goal.md`](~/.claude/references/project-goal.md)。リポジトリの正本は `AGENTS.md` から参照する。
- `superpowers:brainstorming` / `superpowers:writing-plans` の設計書は `.docs/plans/<issue-number>-<feature-name>-design.md`、実装計画は `.docs/plans/<issue-number>-<feature-name>-plan.md` に置く（このリポジトリでは prefix に Issue 番号を使う。共通規約の正本: standards `DOCS_OPS.md §3`）。
- React / Tailwind 向けの `~/.claude/DESIGN.md` と `~/.claude/references/design-golden-ratio.md` は適用外とし、UI 設計原則は `AGENTS.md` に従う。
