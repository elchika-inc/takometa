import Foundation

/// ペース行の書式化。
///
/// **view の private func に置かない。** `TakometaApp` は executable target で
/// テスト対象に入らず、表示規則（直近 nil のとき平均のみ・平均 nil のとき行ごと出さない・
/// 予測は平均から）が一切検査できなくなる。
public enum PaceText {
    /// 既存の上限到達注意に加え、直近の消費が平均より速い場合も注意表示にする。
    public static func requiresAttention(_ pace: UsagePace, recent: Double?) -> Bool {
        !pace.willLastToReset
            || recent.map { $0 > pace.averagePercentPerHour } == true
    }

    /// `nil` を返したら行ごと出さない。
    /// **平均が算出できないときは直近があっても `nil`**（既存 UI が
    /// `if let pace = UsagePace.calculate(...)` の中でのみ描画する構造を保つ）
    public static func description(
        _ pace: UsagePace?,
        recent: Double?,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        guard let pace else { return nil }

        let average = String(format: "平均 %.1f%%/h", pace.averagePercentPerHour)
        // 直近が算出できないときは平均のみ。「直近 --」のような欠測表示はしない（N-4）
        let head = recent.map { average + String(format: "・直近 %.1f%%/h", $0) } ?? average

        // 実績（平均・直近）と見通しは改行で分ける。1行に連結すると幅360の
        // ポップオーバーで末尾が切り詰められ、上限到達予測の日時が読めなくなる（#9）
        if pace.willLastToReset {
            return "\(head)\nリセットまで持つ見込み"
        }
        if let projected = pace.projectedLimitAt {
            // 上限到達予測は引き続き平均から（N-7）。直近から予測すると
            // 一時的な急使用で不安定な予測が出る
            let when = RelativeDateText.text(
                for: projected, now: now, calendar: calendar, locale: locale)
            return "\(head)\n上限到達予測 \(when)"
        }
        return head
    }
}
