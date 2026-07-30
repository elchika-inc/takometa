import Foundation

public struct CodexFetchResult: Sendable {
    public let decoded: CodexUsageDecodeResult
    public let raw: Data
    public let observedNotifications: [String]
}

/// codex app-server を子プロセス起動し、initialize → initialized →
/// account/rateLimits/read を実行する（設計書 §4。手順は 2026-07-19 実測済み）。
public final class CodexAppServerClient {
    public enum ClientError: Error {
        case timeout(String)
        case protocolError(String)
    }

    public init() {}

    public func fetchRateLimits(notificationWait: TimeInterval = 30) throws -> CodexFetchResult {
        guard let binaryPath = CodexBinaryLocator().locate() else {
            throw ClientError.protocolError("Codex 未導入")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["app-server"]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()

        let state = LineCollector()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            state.append(handle.availableData)
        }
        try process.run()
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            process.terminate()
        }

        func send(_ object: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: object)
            stdin.fileHandleForWriting.write(data)
            stdin.fileHandleForWriting.write(Data("\n".utf8))
        }

        try send([
            "method": "initialize", "id": 0,
            "params": ["clientInfo": [
                "name": "takometa-spike", "title": "Takometa Spike", "version": "0.0.1",
            ]],
        ])
        guard state.waitForResponse(id: 0, timeout: 15) != nil else {
            throw ClientError.timeout("initialize 応答なし（codex ログイン状態を確認）")
        }
        try send(["method": "initialized", "params": [String: Any]()])
        try send(["method": "account/rateLimits/read", "id": 1, "params": [String: Any]()])
        guard let response = state.waitForResponse(id: 1, timeout: 30) else {
            throw ClientError.timeout("account/rateLimits/read 応答なし")
        }
        if let error = response["error"] as? [String: Any] {
            throw ClientError.protocolError("rateLimits/read error: \(error["message"] ?? "?")")
        }
        guard let result = response["result"] else {
            throw ClientError.protocolError("result が無い応答")
        }
        let raw = try JSONSerialization.data(withJSONObject: result)
        let decoded = try CodexRateLimitsDecoder.decode(raw)

        // 通知の観測（届かなくても失敗にしない。設計書 §4-5）
        Thread.sleep(forTimeInterval: notificationWait)
        return CodexFetchResult(
            decoded: decoded, raw: raw,
            observedNotifications: state.notificationMethods())
    }
}

enum CodexTransportError: Error, Sendable, Equatable {
    case disconnected
    case timeout
    case protocolError
}

protocol CodexAppServerTransport: AnyObject, Sendable {
    func connect(
        binaryPath: String,
        notificationHandler: @Sendable @escaping (String) -> Void,
        disconnectionHandler: @Sendable @escaping () -> Void
    ) async throws
    func accountIsAuthenticated() async throws -> Bool
    func readRateLimits() async throws -> CodexUsageDecodeResult
    func disconnect() async
}

/// app-server のプロセス寿命と JSON-RPC stdio を管理する transport。
final class CodexProcessTransport: CodexAppServerTransport, @unchecked Sendable {
    private let stateLock = NSLock()
    private let requestLock = NSLock()
    private var process: Process?
    private var stdin: Pipe?
    private var stdout: Pipe?
    private var collector: LineCollector?
    private var nextRequestID = 1
    private var intentionalStop = false

    func connect(
        binaryPath: String,
        notificationHandler: @Sendable @escaping (String) -> Void,
        disconnectionHandler: @Sendable @escaping () -> Void
    ) async throws {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let collector = LineCollector(notificationHandler: notificationHandler)

        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["app-server"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }

        stateLock.withLock {
            intentionalStop = false
            self.process = process
            self.stdin = stdin
            self.stdout = stdout
            self.collector = collector
        }

        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            let shouldNotify = self.stateLock.withLock { !self.intentionalStop }
            if shouldNotify { disconnectionHandler() }
        }

        do {
            try process.run()
            let initialize = try request(
                method: "initialize",
                params: ["clientInfo": [
                    "name": "takometa", "title": "Takometa", "version": "0.1.0",
                ]],
                timeout: 15)
            guard initialize["result"] != nil else { throw CodexTransportError.protocolError }
            try send(["method": "initialized", "params": [String: Any]()])
        } catch let error as CodexTransportError {
            await disconnect()
            throw error
        } catch {
            await disconnect()
            throw CodexTransportError.disconnected
        }
    }

    func accountIsAuthenticated() async throws -> Bool {
        let response = try request(
            method: "account/read",
            params: ["refreshToken": false],
            timeout: 15)
        guard response["error"] == nil,
              let result = response["result"] as? [String: Any]
        else { throw CodexTransportError.protocolError }
        let account = result["account"] as? [String: Any]
        return account?["type"] as? String == "chatgpt"
    }

    func readRateLimits() async throws -> CodexUsageDecodeResult {
        let response = try request(
            method: "account/rateLimits/read",
            params: NSNull(),
            timeout: 30)
        guard response["error"] == nil, let result = response["result"] else {
            throw CodexTransportError.protocolError
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: result)
            return try CodexRateLimitsDecoder.decode(data)
        } catch {
            throw CodexTransportError.protocolError
        }
    }

    func disconnect() async {
        let (process, stdout) = stateLock.withLock {
            intentionalStop = true
            let pair = (self.process, self.stdout)
            self.process = nil
            self.stdin = nil
            self.stdout = nil
            self.collector = nil
            return pair
        }

        stdout?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
    }

    private func request(
        method: String,
        params: Any,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        try requestLock.withLock {
            let (requestID, collector) = stateLock.withLock {
                let requestID = nextRequestID
                nextRequestID += 1
                return (requestID, self.collector)
            }

            try send(["method": method, "id": requestID, "params": params])
            guard let response = collector?.waitForResponse(id: requestID, timeout: timeout) else {
                throw CodexTransportError.timeout
            }
            return response
        }
    }

    private func send(_ object: [String: Any]) throws {
        let (process, handle) = stateLock.withLock {
            (self.process, stdin?.fileHandleForWriting)
        }
        guard process?.isRunning == true, let handle else {
            throw CodexTransportError.disconnected
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
        } catch {
            throw CodexTransportError.disconnected
        }
    }
}

/// stdout の行バッファ。readabilityHandler スレッドから追記されるため lock で守る。
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var notifications: [String] = []
    private let notificationHandler: (@Sendable (String) -> Void)?

    init(notificationHandler: (@Sendable (String) -> Void)? = nil) {
        self.notificationHandler = notificationHandler
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let range = buffer.firstRange(of: Data("\n".utf8)) {
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard !line.isEmpty,
                  let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            if let id = msg["id"] as? Int, msg["result"] != nil || msg["error"] != nil {
                responses[id] = msg
            } else if let method = msg["method"] as? String {
                notifications.append(method)
                notificationHandler?(method)
            }
        }
    }

    func waitForResponse(id: Int, timeout: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let found = responses[id]
            lock.unlock()
            if let found { return found }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    func notificationMethods() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return notifications
    }
}
