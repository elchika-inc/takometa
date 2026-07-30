import Foundation

public enum NotificationIdentifier {
    public static func identifier(for event: NotificationEvent) -> String {
        let kind: String
        let windowID: String
        let basis: String

        switch event {
        case .thresholdExceeded(_, let id, _, _, _, let resetsAt):
            kind = "thresholdExceeded"
            windowID = id
            basis = quantized(resetsAt)
        case .paceDanger(_, let id, _, _, let resetsAt):
            kind = "paceDanger"
            windowID = id
            basis = quantized(resetsAt)
        case .limitReached(_, let id, _, let resetsAt):
            kind = "limitReached"
            windowID = id
            basis = quantized(resetsAt)
        case .recovered(_, let id, _, let basisResetsAt):
            kind = "recovered"
            windowID = id
            basis = quantized(basisResetsAt)
        case .dailyExceeded(_, let id, _, _, _, let day):
            kind = "dailyExceeded"
            windowID = id
            basis = day
        }

        return "\(kind):\(windowID):\(basis)"
    }

    private static func quantized(_ date: Date?) -> String {
        guard let date else { return "none" }
        let wholeSeconds = date.timeIntervalSince1970.rounded(.down)
        let bucket = (wholeSeconds / 300).rounded() * 300
        return String(Int64(bucket))
    }
}
