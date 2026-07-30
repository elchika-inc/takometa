import Foundation

public struct NotificationStateStore: Sendable {
    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Takometa", isDirectory: true)
    }

    public func load() -> NotificationState {
        guard let data = try? Data(contentsOf: fileURL) else { return NotificationState() }
        return (try? JSONDecoder().decode(NotificationState.self, from: data))
            ?? NotificationState()
    }

    public func save(_ state: NotificationState) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("notification-state.json", isDirectory: false)
    }
}
