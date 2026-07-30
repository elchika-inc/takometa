import Foundation

public enum BackoffSchedule {
    public static func interval(
        consecutiveFailures: Int,
        normalInterval: TimeInterval
    ) -> TimeInterval {
        switch consecutiveFailures {
        case ...0: return normalInterval
        case 1: return 60
        case 2: return 120
        case 3: return 300
        default: return 900
        }
    }
}

public enum RestartBackoff {
    public static func delay(attempt: Int) -> TimeInterval {
        switch attempt {
        case ...1: return 1
        case 2: return 2
        case 3: return 4
        case 4: return 8
        case 5: return 16
        case 6: return 32
        default: return 60
        }
    }
}
