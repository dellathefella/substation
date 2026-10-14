import Foundation

public struct EngineClient: Sendable {
    public init() {}

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 1800
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    public static func request(method: String, url: String, body: Data? = nil, bearer: String? = nil, timeout: TimeInterval? = nil,
                               headers: [(String, String)] = []) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer, !bearer.isEmpty { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let (data, resp) = try await Self.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }

    public func json(method: String, url: String, body: JSONValue? = nil, bearer: String? = nil, timeout: TimeInterval? = nil,
                     headers: [(String, String)] = []) async throws -> (Int, JSONValue?) {
        let bodyData = body.map { JSONCoding.encode($0) }
        var extra = headers
        if let bearer { extra.append(("Authorization", "Bearer \(bearer)")) }
        let (status, data) = try await Self.request(method: method, url: url, body: bodyData, bearer: nil, timeout: timeout, headers: extra)
        return (status, JSONCoding.decode(data))
    }

    public func getText(_ url: String, timeout: TimeInterval = 10) async throws -> (Int, String) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        let (data, resp) = try await Self.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (status, String(data: data, encoding: .utf8) ?? "")
    }

    /// Stream an SSE endpoint line-by-line (each `data:` payload yielded).
    public func streamSSE(url: String, body: JSONValue, timeout: TimeInterval = 600, headers: [(String, String)] = [])
        -> AsyncThrowingStream<String, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                var req = URLRequest(url: URL(string: url)!)
                req.httpMethod = "POST"
                req.timeoutInterval = timeout
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                req.httpBody = JSONCoding.encode(body)
                do {
                    let (bytes, resp) = try await Self.session.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                        continuation.finish(throwing: EngineError.status(http.statusCode))
                        return
                    }
                    for try await line in bytes.lines {
                        if line.hasPrefix("data:") {
                            continuation.yield(String(line.dropFirst(5).drop(while: { $0 == " " })))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streaming download (bandwidth probes). Returns bytes received.
    public func downloadBytes(url: String, maxBytes: Int, timeout: TimeInterval = 30) async throws -> Int {
        var req = URLRequest(url: URL(string: url)!)
        req.timeoutInterval = timeout
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode < 400 else {
            throw EngineError.status((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return min(maxBytes, data.count)
    }
}

public enum EngineError: Error, CustomStringConvertible {
    case status(Int)
    case timeout
    case notReady
    case notFound(String)
    case tooLarge(String)

    public var description: String {
        switch self {
        case .status(let s): return "HTTP \(s)"
        case .timeout: return "timeout"
        case .notReady: return "engine not ready"
        case .notFound(let n): return "not found: \(n)"
        case .tooLarge(let n): return "too large: \(n)"
        }
    }
}
