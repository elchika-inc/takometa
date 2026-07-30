import Foundation
import TakometaCore

// このバイナリはキャッシュを読むだけで、OpenAI / Anthropic へ通信しない（N-1）。
// TakometaFixtureSupport へ依存しない（N-8）。

let usageText = """
takometa — Takometa が取得済みのレート制限を表示する

使い方:
  takometa usage [--json]     キャッシュ済みの使用量を表示する
  takometa --help             このヘルプを表示する
  takometa usage --help       このヘルプを表示する

オプション:
  --json    JSON で出力する

終了コード:
  0  使用量の枠を1件以上出力できた
  1  使用量の枠が0件（未取得・読み取り不能・空のキャッシュ）
  2  引数エラー

注意:
  - 表示する値は常駐アプリが取得してキャッシュしたもので、このコマンドは通信しない。
    JSON では fetchedAt / ageSeconds、通常表示では相対経過時間で
    いつ時点の値かを判断すること。
  - モデル固有枠は scope と序数（index）で表す。序数は API が返す順序に依存するため、
    実行ごとに同じ枠が同じ番号になることを保証しない。
  - schemaVersion はフィールドの削除・意味変更で上がる。追加では上がらない。
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n\n\(usageText)\n".utf8))
    exit(2)
}

func writeOut(_ text: String) {
    FileHandle.standardOutput.write(Data("\(text)\n".utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())

// ヘルプは引数列全体がヘルプの形のときだけ通す。--help が混ざっているだけでは
// 通さない（bogus --help / usage --bogus --help を exit 0 にしないため）。
let helpForms: [[String]] = [["--help"], ["-h"], ["usage", "--help"], ["usage", "-h"]]
if helpForms.contains(arguments) {
    writeOut(usageText)
    exit(0)
}

guard let subcommand = arguments.first else {
    fail("エラー: サブコマンドを指定してください")
}
guard subcommand == "usage" else {
    // 入力値を反射しない（N-2）。正しい形式は usage テキストで示す。
    fail("エラー: 未知のサブコマンドです")
}

var wantsJSON = false
for argument in arguments.dropFirst() {
    switch argument {
    case "--json": wantsJSON = true
    default: fail("エラー: 未知のオプションです")
    }
}

// 基準時刻は1つだけ作って共有する。Date() を2回評価すると ageSeconds / expired の
// 判定基準と人間向けの「本日 / 明日」判定の基準がずれる
let now = Date()
let built = UsageReportBuilder.build(cache: SnapshotCache(), now: now)

// 読み取り失敗は握りつぶさず標準エラーへ出す。標準出力の JSON は汚さない（N-5 / N-10）
for warning in built.warnings {
    FileHandle.standardError.write(Data("\(warning)\n".utf8))
}

if wantsJSON {
    do {
        let data = try UsageReportJSON.encode(built.report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        // 例外メッセージを出さない（N-2）
        FileHandle.standardError.write(Data("エラー: JSON の生成に失敗しました\n".utf8))
        exit(1)
    }
} else {
    writeOut(UsageReportText.render(built.report, now: now))
}

// 妥当な窓を1件も出力できていないなら 1（N-6）
exit(built.report.hasUsableWindow ? 0 : 1)
