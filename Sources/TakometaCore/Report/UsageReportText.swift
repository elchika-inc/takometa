import Foundation

/// 人間向けのテキスト出力（`--json` 省略時）。
///
/// **JSON と丸め規則が異なる**——人間向けは既存 UI と同じく切り捨て、JSON は丸めない。
/// 混同を避けるため JSON の組み立て（`UsageReport.swift`）とファイルを分けている。
///
/// `locale` / `calendar` を引数で受け取るのは、日付書式とタイムゾーンが
/// 実行環境で変わるとテストが不安定になるため。
public enum UsageReportText {
    public static func render(
        _ report: UsageReport,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        report.providers
            .map { section(for: $0, now: now, calendar: calendar, locale: locale) }
            .joined(separator: "\n\n")
    }

    private static func section(
        for provider: ProviderReport,
        now: Date, calendar: Calendar, locale: Locale
    ) -> String {
        guard provider.available, let windows = provider.windows else {
            return "\(provider.id.rawValue)  （\(unavailableText(provider.reason))）"
        }

        let age = provider.ageSeconds.map { "\(elapsedText(seconds: $0))に取得" } ?? "取得時刻不明"
        var lines = ["\(provider.id.rawValue)  （\(age)）"]

        if windows.isEmpty {
            lines.append("  （表示できる枠がありません）")
        }
        for window in windows {
            lines.append(line(for: window, now: now, calendar: calendar, locale: locale))
        }
        return lines.joined(separator: "\n")
    }

    private static func line(
        for window: WindowReport,
        now: Date, calendar: Calendar, locale: Locale
    ) -> String {
        var text = "  \(windowLabel(window))  \(percentText(window.usedPercent))"
        if let resetsAt = window.resetsAt {
            let date = RelativeDateText.text(
                for: resetsAt, now: now, calendar: calendar, locale: locale)
            text += "  リセット: \(date)"
        }
        return text
    }

    /// 取得できなかった理由。`absent` と `unreadable` を別の文言にする（N-10）
    static func unavailableText(_ reason: UnavailableReason?) -> String {
        switch reason {
        case .absent, nil: return "取得していません"
        case .unreadable: return "キャッシュを読めませんでした"
        }
    }

    /// 枠の表記。**生の識別子を使わず** `scope` と `index` から導く（N-2b）。
    /// 表記は既存 UI（`SettingsView.windowKindOrderLabel`）に揃える。
    static func windowLabel(_ window: WindowReport) -> String {
        let base: String
        switch window.scope {
        case .session: return "5時間枠"
        case .weeklyAll: return "週間枠"
        case .model: base = "モデル固有枠"
        case .other: base = "その他"
        }

        let number = window.index.map { " #\($0)" } ?? ""
        let duration = durationText(window)
        return "\(base)\(number)\(duration)"
    }

    /// 継続時間の括弧書き。`window` が nil なら括弧ごと省略する。
    ///
    /// モデル固有枠は5時間枠と週間枠が両方あるため、継続時間を落とすと
    /// 両者が同じ表記になり情報が失われる（Codex は実際に両方を生成する）。
    private static func durationText(_ window: WindowReport) -> String {
        switch window.window {
        case nil: return ""
        case .session: return "（5時間）"
        case .weekly: return "（週間）"
        case .other:
            guard let minutes = window.windowMinutes else { return "" }
            return "（\(minutes)分）"
        }
    }

    /// **切り捨て**る。既存 UI（`ProviderPopoverView` / `MenuBarLabelFormatter`）と同じ。
    /// 99.6 を 100% と表示すると、まだ余裕があるのに到達済みに見える。
    /// `Int` の範囲外なら trap させず、固定文言へ安全に倒す。
    static func percentText(_ usedPercent: Double) -> String {
        guard let value = Int(exactly: usedPercent.rounded(.down)) else { return "値不明" }
        return "\(value)%"
    }

    /// 経過時間。桁上げして「7200分0秒前」のような読みにくい表記を避ける
    static func elapsedText(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)秒前" }
        if seconds < 3600 { return "\(seconds / 60)分\(seconds % 60)秒前" }
        if seconds < 86400 { return "\(seconds / 3600)時間\(seconds % 3600 / 60)分前" }
        return "\(seconds / 86400)日前"
    }
}
