/// 使用率を針の角度5段階へ量子化したもの。
/// SF Symbols 名への写像は表示層が持つ ─ Core は UI 詳細を知らない。
public enum GaugeLevel: Sendable, Equatable, CaseIterable {
    case zero, low, mid, high, max

    /// 使用率を5段階へ量子化する。境界は下限を含む（20% ちょうどは `.low`）。
    ///
    /// NaN・無限大は `default` に落ちて `.max` になる。これは意図した挙動で、
    /// 異常値は危険側へ倒す。針が振り切れていれば利用者が異常に気づける。
    public static func forUsedPercent(_ percent: Double) -> GaugeLevel {
        switch percent {
        case ..<20: return .zero
        case ..<40: return .low
        case ..<60: return .mid
        case ..<80: return .high
        default: return .max
        }
    }
}

/// アイコンが何を描くか。値がないケースを `GaugeLevel` から分離することで、
/// 「値が取得できないときに 0% を表示しない」原則を型で守る。
public enum MenuBarIconGlyph: Sendable, Equatable {
    case gauge(GaugeLevel)
    case unavailable
    case authenticationRequired
}

public struct MenuBarIcon: Sendable, Equatable {
    public let glyph: MenuBarIconGlyph
    public let style: SegmentStyle
    public let isStale: Bool
    public let accessibilityText: String

    public init(
        glyph: MenuBarIconGlyph,
        style: SegmentStyle,
        isStale: Bool,
        accessibilityText: String
    ) {
        self.glyph = glyph
        self.style = style
        self.isStale = isStale
        self.accessibilityText = accessibilityText
    }
}

public struct MenuBarIcons: Sendable, Equatable {
    public let icons: [MenuBarIcon]

    public init(icons: [MenuBarIcon]) {
        self.icons = icons
    }

    /// VoiceOver 用。プロバイダの区切りは半角スペース2つ。
    /// 区切り幅は `MenuBarColumns.accessibilityText` のグループ区切りに揃える。
    public var accessibilityText: String {
        icons.map(\.accessibilityText).joined(separator: "  ")
    }
}
