import Foundation

/// 公開の status エンドポイントから障害状況を取得する。
///
/// **リクエスト間で状態を持たない**（最小間隔の判定と打刻は `UsageStore` 側・N-8）。
/// `static let` のセッション共有は行う（リクエストごとに生成すると delegate 保持でリークする）。
public struct ServiceStatusFetcher: ServiceStatusProviding {
    /// 通信先は公式ドメインの2つだけ（N-1）。
    /// status.anthropic.com は status.claude.com へ 302 するため、最終 URL を直接指定する
    private static let endpoints: [ProviderID: URL] = [
        .codex: URL(string: "https://status.openai.com/api/v2/components.json")!,
        .claude: URL(string: "https://status.claude.com/api/v2/components.json")!,
    ]

    /// 監視対象のコンポーネント名。実測で存在を確認済み
    private static let componentNames: [ProviderID: String] = [
        .codex: "Codex API",
        .claude: "Claude Code",
    ]

    private static let delegate = StatusRedirectDelegate()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // 認証情報を送らない（N-2）。URLSessionConfiguration 側は httpShouldSetCookies
        // （httpShouldHandleCookies は URLRequest のプロパティで、ここには存在しない）
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        // 障害状況は付随情報。status 行の反映を長く待たせない
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()

    public init() {}

    public func fetch(for provider: ProviderID) async -> ServiceStatus {
        guard let url = Self.endpoints[provider],
              let componentName = Self.componentNames[provider]
        else { return .unknown }

        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await Self.session.data(for: request)
            // 3xx も含めて 200 以外は判定不能として扱う（N-3）
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .unknown
            }
            return ServiceStatusDecoder.decode(data, componentName: componentName)
        } catch {
            // 例外を呼び出し側へ伝播させない（N-6）
            return .unknown
        }
    }
}

/// エンドポイントは最終 URL を直接指定しているため、すべてのリダイレクトを拒否する（N-1）。
///
/// `completionHandler(nil)` を返すと URLSession は 3xx レスポンス自体を返すため、
/// 呼び出し側の `statusCode == 200` 判定で fail-closed になる。
private final class StatusRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // 最終 URL からのリダイレクトは、行き先にかかわらず異常として扱う
        completionHandler(nil)
    }
}
