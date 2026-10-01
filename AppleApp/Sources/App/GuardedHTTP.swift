import Foundation

/// Native artwork requests use the same credential boundary as the shared HTTP
/// seam. Account cookies never enter this session's cookie storage.
final class GuardedHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = GuardedHTTP()
    private var session: URLSession!
    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func data(for request: URLRequest) async throws -> Data {
        guard let endpoint = request.url, ["http", "https"].contains(endpoint.scheme ?? ""),
              endpoint.user == nil, endpoint.password == nil else { throw URLError(.unsupportedURL) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        let port: (URL) -> Int? = { $0.port ?? ($0.scheme == "https" ? 443 : $0.scheme == "http" ? 80 : nil) }
        return first.scheme?.lowercased() == second.scheme?.lowercased() &&
            first.host?.lowercased() == second.host?.lowercased() && port(first) == port(second)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest, let from = original.url, let to = request.url,
              ["http", "https"].contains(to.scheme ?? ""), to.user == nil, to.password == nil,
              !(from.scheme == "https" && to.scheme != "https") else { completionHandler(nil); return }
        let carriesCredentials = (original.allHTTPHeaderFields ?? [:]).keys.contains {
            $0.caseInsensitiveCompare("Authorization") == .orderedSame || $0.caseInsensitiveCompare("Cookie") == .orderedSame || $0.lowercased().hasPrefix("x-goog-")
        }
        guard !carriesCredentials || Self.sameOrigin(from, to) else { completionHandler(nil); return }
        var next = request
        if carriesCredentials {
            for (key, value) in original.allHTTPHeaderFields ?? [:] { next.setValue(value, forHTTPHeaderField: key) }
        }
        completionHandler(next)
    }
}
