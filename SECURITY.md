# Security Policy

## Supported Versions

最新のリリース版のみをサポート対象とします。過去バージョンへの修正の後方移植は行いません。

| Version | Supported |
|---------|-----------|
| latest  | ✅        |

## Reporting a Vulnerability

セキュリティ上の問題を発見した場合は、**公開 Issue には書かず**、GitHub Security Advisories から報告してください。

- [Report a vulnerability](https://github.com/naoto24kawa/takometa/security/advisories/new)

個人が開発している小規模なプロジェクトのため、初回返答までに**7日程度（暦日）**かかることがあります。資格情報の漏洩につながる問題は優先して対応します。対応状況は GitHub Security Advisory で共有します。

## このアプリが扱う資格情報

Takometa は使用量の取得のために、以下を**読み取り専用**で利用します。更新・削除・ログアウトは行いません。

- Keychain の `Claude Code-credentials`（`/usr/bin/security` コマンド経由）
- Codex CLI の認証情報（`codex app-server` の JSON-RPC 経由）

通信先は OpenAI / Anthropic の公式ホストに限定しています。取得した資格情報をログ・fixture・UI・配布物へ出力しない方針を採っており、`Tests/TakometaFixtureSupportTests/FixtureSanitizerTests.swift` と `Tests/TakometaCoreTests/CodenameLeakTests.swift` で検査しています。

この方針に反する挙動を発見した場合は、上記の経路で報告してください。
