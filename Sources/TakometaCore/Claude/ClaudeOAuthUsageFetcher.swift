import Foundation

public enum ClaudeFetchOutcome: Sendable {
    case success(ClaudeUsageDecodeResult, raw: Data)
    case authenticationRequired
    case failure(String)
}

/// GET /api/oauth/usage（設計書 §5）。401 時は資格情報を再読して1回だけ再試行する。
public enum ClaudeOAuthUsageFetcher {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let session: URLSession = {
        let delegate = CrossHostRedirectDelegate(allowedHost: endpoint.host!)
        return URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil)
    }()

    public static func fetch() async -> ClaudeFetchOutcome {
        guard let token = ClaudeCredentialsReader.readAccessToken() else {
            return .authenticationRequired
        }
        let first = await request(token: token)
        if case .authenticationRequired = first {
            // Claude Code 本体が直後にリフレッシュした場合を拾う
            guard let retryToken = ClaudeCredentialsReader.readAccessToken(),
                  retryToken != token else { return .authenticationRequired }
            return await request(token: retryToken)
        }
        return first
    }

    static func request(token: String) async -> ClaudeFetchOutcome {
        var req = URLRequest(url: endpoint, timeoutInterval: 30)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure("非 HTTP 応答")
            }
            switch http.statusCode {
            case 200:
                let decoded = try ClaudeOAuthUsageDecoder.decode(data, now: Date())
                return .success(decoded, raw: data)
            case 401:
                return .authenticationRequired
            default:
                return .failure("HTTP \(http.statusCode)")
            }
        } catch {
            return .failure("通信/デコード失敗: \(String(describing: type(of: error)))")
        }
    }
}
