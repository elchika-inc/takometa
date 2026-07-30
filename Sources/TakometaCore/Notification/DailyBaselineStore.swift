import Foundation

public struct DailyBaselineStore: Sendable {
    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Takometa", isDirectory: true)
    }

    public func load() -> [String: DailyBaseline] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: DailyBaseline].self, from: data)) ?? [:]
    }

    public func save(_ baselines: [String: DailyBaseline]) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(baselines).write(to: fileURL, options: .atomic)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("daily-baselines.json", isDirectory: false)
    }
}
