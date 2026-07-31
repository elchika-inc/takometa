# Takometa

> Codex と Claude Code のレート制限を macOS メニューバーで常時確認できる常駐アプリ

[![standards](https://img.shields.io/badge/standards-2026--07--18_(rev.35)-blue)](https://github.com/elchika-inc/standards/blob/main/CHANGELOG.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

タコメーター（回転計）× タコ 🐙 のダブルミーニング。AI コーディングエージェントの5時間枠・週間枠・モデル固有枠の使用率を、メニューバーで確認できる個人向けネイティブアプリです。

ソースコードは MIT ライセンスで公開しています。ビルド済みアプリの配布は身内向けの直接配布に限っており、GitHub Release でのバイナリ配布や Homebrew Cask への登録は行っていません。Apple の署名・公証も行っていないため、自分でビルドするか、配布を受けた DMG を使ってください。

## Features

- Codex と Claude Code の5時間枠・週間枠・モデル固有枠を統合表示
- 使用率、リセット時刻、データ鮮度、平均ペース、上限到達予測を表示
- プロバイダー・枠種別・表示順をプロバイダー別に設定
- 使用率・消費量・上限到達などの通知をプロバイダー別に設定
- 既存のログイン情報を読み取り専用で再利用
- JSON 設定で未知のプロバイダー情報を保持

## Development

ビルドとテストにはフル Xcode 26.6 が必要です。Command Line Tools のみでは `PreviewsMacros` が不足してビルドできません。

| コマンド | 内容 |
|---|---|
| `swift build` | デバッグビルド |
| `swift test` | 単体テスト |
| `scripts/make-app.sh [version]` | host arch の開発用 `.app` を `dist/` に生成 |
| `scripts/make-release.sh <version>` | universal の配布用 zip と SHA256 を生成 |
| `swift run takometa-spike <codex\|claude\|statusline> [--emit-fixture <path>]` | 取得スパイク |

## Documents

```
.docs/
  PROJECT_GOAL.md                 # ゴールと完了条件（正本）
  RELEASE.md                      # リリース・配布手順と記録
  plans/                          # issue 番号付きの設計書・実装計画
```

## Security Notes

- 認証情報は読み取り専用で扱い、更新・削除・ログアウトを行わない
- 通信先は OpenAI / Anthropic の公式ホストだけに限定する
- トークン、Cookie、Authorization ヘッダーをログ・fixture・UI・配布物へ出さない
- fixture は `TakometaFixtureSupport` の `FixtureSanitizer` を必ず通す

## 配布を受けた方へ

次の本文は zip 同梱の `はじめにお読みください.txt` および `.docs/RELEASE.md` の配布テンプレートと同一です。

<!-- TAKOMETA_GUIDE_BEGIN -->
# Takometa はじめにお読みください

この案内は Takometa の更新・アンインストールや Keychain 許可の取り消しにも使います。案内は DMG の中に入っています。後日も使うので、この案内をコピーして保存するか、受け取った DMG を消さずに残しておいてください。

## 照合手順

配布者から DMG と SHA256 ファイルを別々の経路で受け取り、同じフォルダへ保存します。ターミナルでそのフォルダへ移動し、次を実行してください。`VERSION` は受け取った版（例: `0.1.0`）へ置き換えます。

```
shasum -a 256 -c "Takometa-VERSION.dmg.sha256"
```

`OK` と表示された場合だけ先へ進みます。DMG と SHA256 を別経路で受け取れない場合、この照合で検出できるのは転送中の破損までで、改竄検知にはなりません。

## 動作要件

- コンパイル上の下限は macOS 15.0 です。実際の動作確認は macOS 26.3.1 でのみ行っており、macOS 15〜25 は未検証です。
- Codex CLI または Claude Code の少なくとも一方を利用していれば使えます。使っていない側は後述の設定で非表示にできます。
- Codex CLI は `/opt/homebrew/bin/codex`、`/usr/local/bin/codex`、`~/.local/bin/codex` のいずれかにある必要があります。別の場所にある場合は再インストールするか、`~/.local/bin/codex` へ実体を指すシンボリックリンクを作成してください。
- Claude の使用量取得には、Claude Code でログイン済みである必要があります。

## インストールと初回起動

1. DMG をダブルクリックして開きます。Takometa.app と Applications フォルダへのショートカットが並んだウィンドウが開きます。
2. Takometa.app を、同じウィンドウ内の Applications ショートカットへドラッグします。管理者パスワードを求められたら入力してください（アプリ導入では通常の操作です）。
3. DMG を取り出します（デスクトップまたは Finder のサイドバーにあるディスクの取り出しアイコンを押します）。
4. `アプリケーション`（`/Applications`）フォルダを開き、`Takometa.app` をダブルクリックします。展開元の DMG からは起動しないでください。
5. ブロックされなかった場合は、そのまま次の「起動できたことの確認方法」へ進みます。
6. ブロックされた場合は、最初の起動試行の後にシステム設定を開き、「プライバシーとセキュリティ」の画面を下へスクロールします。直前にブロックされた Takometa についての通知と許可の操作が表示されるので、それを実行します（Touch ID かパスワードでの認証を求められたら認証してください）。その後もう一度 `/Applications/Takometa.app` を開きます。なお画面名やボタンの文言は macOS のバージョンによって異なることがあります。位置と流れで読み替えてください。

GUI の許可経路が使えない場合に限り、次のコマンドで Takometa.app の quarantine 属性だけをバンドル内部まで取り除いてから、もう一度開きます。

```
xattr -dr com.apple.quarantine "/Applications/Takometa.app"
```

## 起動できたことの確認方法

Takometa は Dock に表示されません。画面上部のメニューバーに Takometa の使用率表示が現れ、クリックしてポップオーバーを開けることを確認してください。資格情報が無く使用率を取得できない場合でも、ポップオーバー下部のバージョンとビルド表示を確認できれば起動しています。

## 使っていないプロバイダーを非表示にする方法

ポップオーバーの「設定」を開き、Codex または Claude タブを選びます。使っていない側の「表示する」を OFF にしてください。少なくとも一方は表示したままにしてください。

## Keychain 認可

Takometa は Claude の使用量取得のため、Keychain の `Claude Code-credentials` を `/usr/bin/security` コマンド経由で読み取り専用利用します。資格情報の更新・削除・ログアウトは行いません。認可ダイアログには Takometa ではなく `security` と表示されます。

ダイアログには「拒否」「許可」「常に許可」に相当する3つの選択肢が表示されます。**一度だけ許可する選択肢**（「常に許可」ではない方）を選んでください。選択肢の文言は macOS のバージョンによって異なることがあります。

「常に許可」は選ばないでください。許可先が Takometa ではなく `/usr/bin/security` になるため、以後は別のプロセスも無確認で資格情報を取得でき、Takometa を削除しても許可が残ります。拒否した場合、Claude の使用量は取得できません。Codex の取得には影響しません。

すでに「常に許可」を選んだ場合は「キーチェーンアクセス」アプリで `Claude Code-credentials` を開き、「アクセス制御」の項目にある、アクセスを許可されたアプリケーションの一覧から `/usr/bin/security` を選んで削除してください。

## 更新手順

1. Takometa の設定を開き、「全般」タブの「ログイン時に Takometa を開く」を OFF にします。
2. ポップオーバーの「終了」を押して Takometa を終了します。
3. 新版の DMG を照合して開き、新しい案内を保存します。
4. 新版をまだ起動せず、Takometa.app を Applications ショートカットへドラッグして旧版を置き換えます（置き換えの確認が出たら許可します）。
5. `/Applications/Takometa.app` を開きます。初回起動と同様に、ブロックされなかった場合とブロックされた場合の手順を分け、必要ならシステム設定で許可します。
6. メニューバーからポップオーバーを開き、表示されたバージョンとビルドが新版へ変わったことを確認します。
7. 必要なら「ログイン時に Takometa を開く」を再び ON にします。

## アンインストール手順

1. 設定の「ログイン時に Takometa を開く」を OFF にします。
2. ポップオーバーの「終了」を押します。
3. Finder で `/Applications/Takometa.app` をゴミ箱へ移動します。
4. 設定や取得済みスナップショットも消す場合は、Finder の「フォルダへ移動」で `~/Library/Application Support/Takometa` を開き、そのフォルダを削除します。
5. Keychain の「常に許可」はアプリ削除では取り消されません。選択済みの場合は「Keychain 認可」の手順で別途取り消します。

## 利用条件

Takometa のソースコードは MIT ライセンスで公開しています。ソースの利用・改変・再配布はライセンスの条件に従って自由に行えます。

この DMG は Apple の署名・公証を受けていない配布物で、動作保証や損害への保証はありません。DMG を誰かへ渡す場合は、この案内も一緒に渡してください。受け取った側が照合手順と Keychain 認可の注意を読まないまま導入することを避けるためです。

## バージョンの確認方法

メニューバーの Takometa をクリックし、ポップオーバー下部の「バージョン」と「ビルド」を確認します。不具合報告や更新確認では両方を伝えてください。版の判別は「バージョン」の値を基準にします。

## 不具合・質問

配布者へ直接連絡してください。報告には Takometa のバージョンとビルド、macOS のバージョン、問題が Codex・Claude のどちらで起きたか、表示されたエラー文、再現手順を含めてください。認証トークン、Keychain の内容、Authorization ヘッダーは送らないでください。

## Apple の署名・公証

このアプリは身内向けの小規模な直接配布であり、Apple Developer Program の Developer ID 署名と公証を行っていません。そのため初回起動や更新時に macOS の警告が表示されます。警告を回避するために Gatekeeper 全体の設定を変更しないでください。
<!-- TAKOMETA_GUIDE_END -->

## License

[MIT](LICENSE) © 2026 Naoto Nishikawa

ソースコードの利用・改変・再配布は MIT ライセンスの条件に従って自由に行えます。配布される DMG は Apple の署名・公証を受けておらず、動作保証はありません。

セキュリティ上の問題を見つけた場合は、公開 Issue ではなく [SECURITY.md](SECURITY.md) の経路で報告してください。
