import Observation
import TakometaCore
import UserNotifications

@Observable
@MainActor
final class NotificationDispatcher: NSObject, UNUserNotificationCenterDelegate {
    private(set) var authorizationStatus: UNAuthorizationStatus?
    private(set) var lastErrorDescription: String?

    @ObservationIgnored private let center: UNUserNotificationCenter?

    override init() {
        guard Bundle.main.bundleIdentifier != nil else {
            center = nil
            super.init()
            return
        }

        let center = UNUserNotificationCenter.current()
        self.center = center
        super.init()
        center.delegate = self

        Task { await refreshAuthorizationStatus() }
    }

    func refreshAuthorizationStatus() async {
        guard let center else {
            authorizationStatus = nil
            return
        }
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        guard let center else {
            authorizationStatus = nil
            return false
        }

        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            await refreshAuthorizationStatus()
            lastErrorDescription = nil
            return authorizationStatus == .authorized
        } catch {
            lastErrorDescription = "通知許可の取得に失敗しました。"
            await refreshAuthorizationStatus()
            return false
        }
    }

    func send(_ events: [NotificationEvent]) {
        guard let center, !events.isEmpty else { return }

        Task {
            let settings = await center.notificationSettings()
            authorizationStatus = settings.authorizationStatus
            guard settings.authorizationStatus == .authorized else { return }

            for event in events {
                do {
                    let request = request(for: event)
                    center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
                    try await center.add(request)
                    lastErrorDescription = nil
                } catch {
                    lastErrorDescription = "通知の送信に失敗しました。"
                }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    private func request(for event: NotificationEvent) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Takometa"
        content.body = body(for: event)
        content.sound = .default
        return UNNotificationRequest(
            identifier: NotificationIdentifier.identifier(for: event),
            content: content,
            trigger: nil)
    }

    private func body(for event: NotificationEvent) -> String {
        switch event {
        case .thresholdExceeded(let provider, _, let label, let used, let threshold, _):
            return "\(providerName(provider)) \(label) が \(percent(used)) に達しました（閾値 \(percent(threshold))）"
        case .paceDanger(let provider, _, let label, let projectedLimitAt, _):
            let time = RelativeDateText.text(for: projectedLimitAt, now: Date())
            return "\(providerName(provider)) \(label) は、このペースだと \(time) に上限へ到達します"
        case .limitReached(let provider, _, let label, let resetsAt):
            if let resetsAt {
                let reset = RelativeDateText.text(for: resetsAt, now: Date())
                return "\(providerName(provider)) \(label) が上限に達しました（リセット: \(reset)）"
            }
            return "\(providerName(provider)) \(label) が上限に達しました"
        case .recovered(let provider, _, let label, _):
            return "\(providerName(provider)) \(label) の使用量が上限未満に回復しました"
        case .dailyExceeded(let provider, _, let label, let consumed, let threshold, _):
            return "\(providerName(provider)) \(label) の本日の消費が \(percent(consumed)) に達しました（閾値 \(percent(threshold))）"
        }
    }

    private func providerName(_ provider: ProviderID) -> String {
        provider == .codex ? "Codex" : "Claude"
    }

    private func percent(_ value: Double) -> String {
        "\(Int(value.rounded(.down)))%"
    }
}
