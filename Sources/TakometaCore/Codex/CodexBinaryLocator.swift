import Foundation

public struct CodexBinaryLocator: Sendable {
    public static let defaultCandidates = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/codex").path,
    ]

    private let candidates: [String]
    private let fileExists: @Sendable (String) -> Bool

    public init(
        candidates: [String] = defaultCandidates,
        fileExists: @Sendable @escaping (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.candidates = candidates
        self.fileExists = fileExists
    }

    public func locate() -> String? {
        candidates.first(where: fileExists)
    }
}
