import Foundation

public struct ClaudeCredentials: Sendable, Equatable {
    public let accessToken: String
    public let expiresAt: Date?

    public init(accessToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }
}

public enum CredentialsError: Error, Sendable, Equatable {
    case notFound
    case readFailure
}

public protocol CredentialsProviding: Sendable {
    func readKeychainCredentials() -> Result<ClaudeCredentials, CredentialsError>
    func readFileCredentials() -> Result<ClaudeCredentials, CredentialsError>
}

/// Claude Code の資格情報を読み取り専用で取得する（設計書 §5）。
public struct ClaudeCredentialsReader: CredentialsProviding, Sendable {
    static let keychainService = "Claude Code-credentials"

    enum KeychainReadResult: Equatable {
        case success(Data)
        case notFound
        case failure
    }

    private enum FileReadResult {
        case success(ClaudeCredentials)
        case notFound
        case failure
    }

    public init() {}

    public func readKeychainCredentials() -> Result<ClaudeCredentials, CredentialsError> {
        switch Self.readKeychainResult() {
        case .success(let data):
            guard let credentials = Self.credentials(fromData: data) else {
                return .failure(.notFound)
            }
            return .success(credentials)
        case .notFound:
            return .failure(.notFound)
        case .failure:
            return .failure(.readFailure)
        }
    }

    public func readFileCredentials() -> Result<ClaudeCredentials, CredentialsError> {
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        switch Self.readFile(at: fallback) {
        case .success(let credentials):
            return .success(credentials)
        case .failure:
            return .failure(.readFailure)
        case .notFound:
            return .failure(.notFound)
        }
    }

    public static func readAccessToken() -> String? {
        let reader = ClaudeCredentialsReader()
        if case .success(let credentials) = reader.readKeychainCredentials() {
            return credentials.accessToken
        }
        guard case .success(let credentials) = reader.readFileCredentials() else { return nil }
        return credentials.accessToken
    }

    /// 未署名バイナリの直読は Keychain 認可 UI を誘発するため security コマンド経由。
    /// SecItemCopyMatching 直読は Phase 2 の署名済みアプリで再評価（設計書 §5）。
    static func readKeychain() -> Data? {
        guard case .success(let data) = readKeychainResult() else { return nil }
        return data
    }

    private static func readKeychainResult() -> KeychainReadResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password", "-s", keychainService, "-w",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return classifyKeychainOutput(
            terminationStatus: process.terminationStatus,
            terminationReason: process.terminationReason,
            output: output)
    }

    static func classifyKeychainOutput(
        terminationStatus: Int32,
        terminationReason: Process.TerminationReason,
        output: Data
    ) -> KeychainReadResult {
        guard terminationReason == .exit else { return .failure }
        if terminationStatus == 44 { return .notFound }
        guard terminationStatus == 0 else { return .failure }
        guard let text = String(data: output, encoding: .utf8) else {
            return .success(output)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(Data(trimmed.utf8))
    }

    public static func accessToken(fromFileAt url: URL) -> String? {
        guard case .success(let credentials) = readFile(at: url) else { return nil }
        return credentials.accessToken
    }

    static func accessToken(fromData data: Data) -> String? {
        credentials(fromData: data)?.accessToken
    }

    static func credentials(fromData data: Data) -> ClaudeCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty else { return nil }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1_000)
        }
        return ClaudeCredentials(accessToken: accessToken, expiresAt: expiresAt)
    }

    private static func readFile(at url: URL) -> FileReadResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .notFound
        }
        guard !isDirectory.boolValue else { return .failure }
        do {
            let data = try Data(contentsOf: url)
            guard let credentials = credentials(fromData: data) else { return .notFound }
            return .success(credentials)
        } catch {
            return .failure
        }
    }
}
