import Foundation

/// 日時を表示用の文字列へ整形する。当日・翌日・前日は相対表記にする。
/// 相対表記にならない場合の書式は従来（`date: .abbreviated`）を維持する。
public enum RelativeDateText {
    public static func text(
        for target: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current,
        includesSeconds: Bool = false
    ) -> String {
        let timeStyle: Date.FormatStyle.TimeStyle = includesSeconds ? .standard : .shortened

        guard let prefix = relativeDayPrefix(for: target, now: now, calendar: calendar) else {
            return target.formatted(style(
                date: .abbreviated, time: timeStyle, calendar: calendar, locale: locale))
        }

        let time = target.formatted(style(
            date: .omitted, time: timeStyle, calendar: calendar, locale: locale))
        return "\(prefix) \(time)"
    }

    /// 当日・翌日・前日のときだけ接頭辞を返す。それ以外は nil。
    ///
    /// 日数差分ではなく `isDate(_:inSameDayAs:)` で判定する。DST が 00:00 に切り替わる
    /// タイムゾーン（Havana 等）では `startOfDay` が 01:00 を返し、差分計算だと
    /// 23時間を「0日」・47時間を「1日」と数えて誤判定するため。
    private static func relativeDayPrefix(
        for target: Date,
        now: Date,
        calendar: Calendar
    ) -> String? {
        if calendar.isDate(target, inSameDayAs: now) { return "本日" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(target, inSameDayAs: tomorrow) {
            return "明日"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(target, inSameDayAs: yesterday) {
            return "昨日"
        }
        return nil
    }

    private static func style(
        date: Date.FormatStyle.DateStyle,
        time: Date.FormatStyle.TimeStyle,
        calendar: Calendar,
        locale: Locale
    ) -> Date.FormatStyle {
        Date.FormatStyle(
            date: date,
            time: time,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone)
    }
}
