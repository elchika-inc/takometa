import CoreGraphics
import Foundation   // accessibilityText の trimmingCharacters(in:) に必要

/// 2行表示の1列。上段（title）と下段（value）を持つ。
///
/// title / value はいずれも**空文字にしない**（N-6）。空文字だと `Text` の高さが 0 になり
/// 列の高さが揃わず、メニューバーの高さ制限を超える。
/// - title に入りうる値: 枠名・プロバイダーラベル・"他"（overflow）・"--"（値なし）・" "（マーク列）
/// - value に入りうる値: 使用率の整数値・"+n"（overflow）・鮮度マーク・" "（ラベル列と "--" 列）
public struct MenuBarColumn: Sendable, Equatable {
    public let title: String
    public let value: String
    public let style: SegmentStyle

    public init(title: String, value: String, style: SegmentStyle) {
        self.title = title
        self.value = value
        self.style = style
    }
}

/// プロバイダーごとの列のグループ。区切り線は描画側が groups の間へ入れる。
public struct MenuBarColumns: Sendable, Equatable {
    public let groups: [[MenuBarColumn]]

    public init(groups: [[MenuBarColumn]]) {
        self.groups = groups
    }

    /// VoiceOver 用。各列を "title value" で連結する。
    /// value が空白のみの列（ラベル列・"--" 列）は title だけ、
    /// title が空白のみの列（鮮度マーク列）は value だけを出す。
    /// 列の区切りは半角スペース1つ、グループの区切りは半角スペース2つ。
    public var accessibilityText: String {
        groups
            .map { group in
                group
                    .map { column -> String in
                        let title = column.title.trimmingCharacters(in: .whitespaces)
                        let value = column.value.trimmingCharacters(in: .whitespaces)
                        if value.isEmpty { return title }
                        if title.isEmpty { return value }
                        return "\(title) \(value)"
                    }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .joined(separator: "  ")
    }
}

/// 2行表示の寸法。実ビュー（`MenuBarColumnsView`）と計測用 spike の双方が参照する正本。
///
/// メニューバーの高さは 22pt。
///
/// **各行の高さはフォントサイズちょうどへ詰める**（`.frame(height:)`）。SwiftUI の `Text` は
/// フォントサイズに対して余分な行高を持つため（10pt フォントで 13pt）、詰めない場合は
/// 上段7 / 下段10 が上限だった。詰めることで合計 22pt まで使える。
///
/// 上段を小さく・下段を大きくして数値の可読性を優先する（メニューバー系アプリの慣例）。
/// 実測（詰めあり）: 8/11=19pt、9/12=21pt、**9/13=22pt（採用）**、8/14=22pt、7/14=21pt、
/// 10/13=23pt（超過）。8/14 は他のメニューバーアプリと並べると数値が大きすぎたため 9/13 とした。
public enum MenuBarColumnsMetrics {
    public static let titleFontSize: CGFloat = 9
    public static let valueFontSize: CGFloat = 13
    public static let columnSpacing: CGFloat = 5
    public static let groupSpacing: CGFloat = 7
    public static let dividerWidth: CGFloat = 1
    public static let dividerHeight: CGFloat = 16
}
