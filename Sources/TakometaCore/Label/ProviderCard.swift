/// パネルのカード表示1枚分。組み立ては MenuBarLabelFormatter.formatProviderCards が行い、
/// View はこの値を描くだけにする。将来 WidgetKit へ移すときは timeline provider が
/// この値を組み立てて同じ View へ渡す（設計書 §4）。
public struct ProviderCard: Sendable, Equatable {
    /// リングが何を描くか。値がないケースを分離し、0% のリングを描かせない
    public enum Ring: Sendable, Equatable {
        case gauge(percent: Int, style: SegmentStyle)
        case unavailable
        case authenticationRequired
    }

    public struct Row: Sendable, Equatable {
        public let label: String
        public let percent: Int
        public let style: SegmentStyle

        public init(label: String, percent: Int, style: SegmentStyle) {
            self.label = label
            self.percent = percent
            self.style = style
        }
    }

    public let name: String
    public let ring: Ring
    public let rows: [Row]
    public let isStale: Bool

    public init(name: String, ring: Ring, rows: [Row], isStale: Bool) {
        self.name = name
        self.ring = ring
        self.rows = rows
        self.isStale = isStale
    }
}
