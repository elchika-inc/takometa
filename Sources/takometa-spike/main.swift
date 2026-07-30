import AppKit
import Foundation
import SwiftUI
import TakometaCore
import TakometaFixtureSupport

/// 表示・保存は必ず FixtureSanitizer を通す（Global Constraints）。
func printSanitized(raw: Data) {
    guard let cleaned = try? FixtureSanitizer.sanitizedData(from: raw),
          let text = String(data: cleaned, encoding: .utf8) else {
        print("(サニタイズ失敗のため生レスポンスは表示しない)")
        return
    }
    print(text)
}

func emitFixtureIfRequested(raw: Data, emitPath: String?) throws {
    guard let emitPath else { return }
    let cleaned = try FixtureSanitizer.sanitizedData(from: raw)
    let url = URL(fileURLWithPath: emitPath)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try cleaned.write(to: url)
    print("fixture written: \(emitPath)")
}

/// 成功判定: 妥当なウィンドウ1つ以上 + 取得時刻（設計書 §4/§5）。
func judge(windows: [RateLimitWindow], fetchedAt: Date, unknownKeys: [String]) -> Int32 {
    if !unknownKeys.isEmpty {
        print("unknown keys (values not shown): \(unknownKeys.joined(separator: ", "))")
    }
    let valid = windows.filter { (0...100).contains($0.usedPercent) }
    guard !valid.isEmpty else {
        print("RESULT: FAIL — 妥当なウィンドウが1つも無い（空応答・全欠損は成功にしない）")
        return 1
    }
    print("RESULT: OK — windows=\(valid.count) fetchedAt=\(fetchedAt)")
    for w in valid {
        let reset = w.resetsAt.map { "resets \($0)" } ?? "resets: unknown"
        print("  [\(w.label)] \(w.usedPercent)% \(reset)")
    }
    return 0
}

let args = CommandLine.arguments
let emitIndex = args.firstIndex(of: "--emit-fixture")
if let emitIndex, !args.indices.contains(emitIndex + 1) {
    print("usage: takometa-spike <codex|claude|statusline|menubar-metrics> [--emit-fixture <path>]")
    exit(1)
}
let emitPath: String? = emitIndex.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
let command = args.count > 1 ? args[1] : "help"

let exitCode: Int32
switch command {
case "codex":
    do {
        let result = try CodexAppServerClient().fetchRateLimits(notificationWait: 30)
        printSanitized(raw: result.raw)
        try emitFixtureIfRequested(raw: result.raw, emitPath: emitPath)
        print("observed notifications: \(result.observedNotifications.joined(separator: ", "))")
        exitCode = judge(
            windows: result.decoded.windows, fetchedAt: Date(),
            unknownKeys: result.decoded.unknownKeys)
    } catch {
        print("RESULT: FAIL — \(error)")
        exitCode = 1
    }

case "claude":
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var code: Int32 = 1
    Task.detached {
        let outcome = await ClaudeOAuthUsageFetcher.fetch()
        switch outcome {
        case .success(let decoded, let raw):
            printSanitized(raw: raw)
            do {
                try emitFixtureIfRequested(raw: raw, emitPath: emitPath)
            } catch {
                print("RESULT: FAIL — fixture 保存失敗: \(String(describing: type(of: error)))")
                code = 1
                semaphore.signal()
                return
            }
            print("crosscheck five_hour/seven_day: \(decoded.crosscheck)")
            code = judge(
                windows: decoded.windows, fetchedAt: Date(),
                unknownKeys: decoded.unknownKeys)
        case .authenticationRequired:
            print("RESULT: AUTH_REQUIRED — Claude Code で再ログイン後に再実行（これは判定としては成功）")
            code = 2
        case .failure(let reason):
            print("RESULT: FAIL — \(reason)")
            code = 1
        }
        semaphore.signal()
    }
    semaphore.wait()
    exitCode = code

case "statusline":
    let settings = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
    if let data = try? Data(contentsOf: settings),
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       root["statusLine"] != nil {
        print("RESULT: OK — statusLine 設定あり（フォールバック経路は利用可能）")
        exitCode = 0
    } else {
        print("RESULT: UNCONFIGURED — statusLine 未設定（判定記録に記載する。失敗ではない）")
        exitCode = 0
    }

case "menubar-metrics":
    measureMenuBarColumns()
    exitCode = 0

default:
    print("usage: takometa-spike <codex|claude|statusline|menubar-metrics> [--emit-fixture <path>]")
    exitCode = 1
}
exit(exitCode)

/// 2行表示の寸法を計測する。MenuBarColumnsView はアプリ target にあり import できないため、
/// レイアウトを複製して MenuBarColumnsMetrics だけを共有する。
@MainActor
func measureMenuBarColumns() {
    struct Probe: View {
        let groups: [[(String, String)]]

        var body: some View {
            HStack(spacing: MenuBarColumnsMetrics.groupSpacing) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 {
                        Rectangle()
                            .frame(
                                width: MenuBarColumnsMetrics.dividerWidth,
                                height: MenuBarColumnsMetrics.dividerHeight)
                            .opacity(0.25)
                    }
                    HStack(spacing: MenuBarColumnsMetrics.columnSpacing) {
                        ForEach(Array(group.enumerated()), id: \.offset) { _, column in
                            // 実ビュー（MenuBarColumnsView）と同じく行の高さを詰める。
                            // 詰め方が食い違うと計測が実ビューを反映しない
                            VStack(spacing: 0) {
                                Text(column.0)
                                    .font(.system(size: MenuBarColumnsMetrics.titleFontSize))
                                    .frame(height: MenuBarColumnsMetrics.titleFontSize)
                                Text(column.1)
                                    .font(.system(
                                        size: MenuBarColumnsMetrics.valueFontSize,
                                        weight: .semibold).monospacedDigit())
                                    .frame(height: MenuBarColumnsMetrics.valueFontSize)
                            }
                        }
                    }
                }
            }
            .fixedSize()
        }
    }

    let cases: [(String, [[(String, String)]])] = [
        ("実データ相当", [
            [("CX", " "), ("1w", "66"), ("GPT-5.3…", "0")],
            [("CL", " "), ("5h", "16"), ("1w", "20"), ("Fable", "11")],
        ]),
        ("overflow + stale", [
            [("CX", " "), ("5h", "34"), ("1w", "52"), ("GPT", "78"), ("Fable", "65"),
             ("他", "+1"), (" ", "⏱")],
        ]),
        ("値なし", [[("CX", " "), ("--", " ")]]),
    ]

    let limit = NSStatusBar.system.thickness
    print("メニューバー高さ: \(limit)pt")
    print("フォント: 上段 \(MenuBarColumnsMetrics.titleFontSize)pt / 下段 \(MenuBarColumnsMetrics.valueFontSize)pt")
    for (name, groups) in cases {
        let renderer = ImageRenderer(content: Probe(groups: groups))
        renderer.scale = 2
        guard let size = renderer.nsImage?.size else { continue }
        let verdict = size.height <= limit ? "OK" : "超過"
        // %@ には幅指定が効かないため、列揃えは padding で行う
        let padded = name.padding(toLength: max(name.count, 18), withPad: " ", startingAt: 0)
        print(String(format: "  %@ %.1f x %.1f pt  %@", padded, size.width, size.height, verdict))
    }
}
