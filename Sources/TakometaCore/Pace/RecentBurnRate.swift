import Foundation

/// 直近60分の傾き。
///
/// **「瞬間バーンレート」と呼ばない**——実体は直近60分の両端差分であり、
/// より短い窓を想起させる語は避ける（設計書「用語」§）。
///
/// 最小二乗法を使わないのは、記録が「変化時のみ＋ハートビート」で等間隔でなく、
/// 密な区間に引きずられるため。両端の差分なら間隔に依存しない。
public enum RecentBurnRate {
    static let lookback: TimeInterval = 3600
    static let minimumSpan: TimeInterval = 300

    /// 手順の順序を変えないこと（N-12）。各段で集合が減るため、
    /// 減らした後に再判定しなければ NaN が出る。
    public static func calculate(points: [HistoryPoint], now: Date) -> Double? {
        // 0. 昇順チェック。abs を使わないだけでは完全逆順しか倒せず、
        //    シャッフルは誤った正値を返すため（N-13）
        guard zip(points, points.dropFirst()).allSatisfy({ $0.at <= $1.at }) else { return nil }

        // 1. 直近 60 分を抽出
        let cutoff = now.addingTimeInterval(-lookback)
        let recent = points.filter { $0.at >= cutoff }

        // 2. 空判定。3 より前に置く（末尾参照を伴う実装でも落ちないように）
        guard !recent.isEmpty else { return nil }

        // 3. 末尾側で最初に見つかる非 nil の resetsAt を基準に、末尾から遡って連続区間。
        //    基準を「最新点の resetsAt」にしてはならない——最新点が nil のとき
        //    sameWindow(T, nil) が偽になり、直前の正常な点がすべて境界になる（N-5）
        let kept: [HistoryPoint]
        if let baseline = recent.reversed().compactMap(\.resetsAt).first {
            var accumulated: [HistoryPoint] = []
            for point in recent.reversed() {
                // resetsAt が nil の点は境界にしない。nil は「窓が変わった」ではなく
                // 「取得できなかった」であり、同一視すると欠測1点で系列が切れる
                if let resetsAt = point.resetsAt,
                   !WindowIdentity.sameWindow(resetsAt, baseline) { break }
                accumulated.append(point)
            }
            kept = accumulated.reversed()
        } else {
            kept = recent   // 非 nil の resetsAt が1つも無ければフィルタしない
        }

        // 4. 2点未満の判定は 3 の後（NaN を出さないため・N-12）
        guard kept.count >= 2, let oldest = kept.first, let latest = kept.last else { return nil }

        // 5. 時間差。abs を使わない（順序が破れたら nil へ倒す・N-13）
        let span = latest.at.timeIntervalSince(oldest.at)
        guard span >= minimumSpan else { return nil }

        // 6. 傾き
        let slope = (latest.usedPercent - oldest.usedPercent) / (span / 3600)

        // 7. 負値ガード。0 は真値なので返す（N-6）
        guard slope >= 0 else { return nil }

        // 8.
        return slope
    }
}
