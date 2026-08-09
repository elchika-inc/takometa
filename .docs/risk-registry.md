# Risk Registry — 明示受容した例外（ACCEPTED_RISKS）

ルールを弱めて違反を隠す代わりに、受容した例外をここに記録する（AGENTS.md 重要な設計原則）。
各エントリは「内容 / 受容理由 / アンカー（`anchor`） / 再検討条件」を持つ。解消したら削除せず `(resolved: YYYY-MM-DD)` を付ける。
`anchor` は、この受容が破れたことを受容者以外の何が検知するかを示す、レビューループの外側にある観測（standards DOCS_OPS §3）。受容内容を再記述するだけの別のレビュー結果・計画・台帳を anchor にしない。

## RISK-001: Claude のロゴを identification 目的で同梱する
- date: 2026-08-09
- confidence: high
- location: `Sources/TakometaApp/Resources/claude-logo.svg` / `NOTICE` / `.docs/plans/20-provider-logos-design.md`「リスク」節
- status: accepted
- reason: メニューバーで Codex / Claude を一目で判別させるため、simple-icons（CC0 1.0）が配布する Claude のスパークマークを無改変で同梱する。Anthropic の公開ブランドガイドラインは調査時点で参照できず（`anthropic.com/brand` は 404）、公開リポジトリでの再配布を明示許可する一次情報を確認できなかった。識別目的の使用（nominative use）・無改変・`NOTICE` での商標帰属明記により許容範囲と判断するが、法的保証はない。OpenAI 側はロゴ使用に事前の書面同意を要求しており（App Developer Terms）、simple-icons も OpenAI / ChatGPT / Codex を Defensible に分類して収録を見送っているため、Codex 側は同梱せず SF Symbols `terminal` で代替した。
- anchor: Anthropic からの使用停止・変更の申し入れ（GitHub Issue・メール等のリポジトリ外からの連絡）。および simple-icons が `icons/claude.svg` を削除・ライセンス変更した事実（`github.com/simple-icons/simple-icons` の当該ファイルの存在と `LICENSE.md` で観測できる。OpenAI 系の収録可否は simple-icons#14748 で追える）。
- 再検討条件: 上記の申し入れを受けた場合、または Anthropic が第三者向けブランドガイドラインを公開した場合。差し替えは表示層の `ProviderLogoView` に閉じており、Core は `ProviderID` しか知らないため影響範囲は同ファイルとアセットに限られる。
