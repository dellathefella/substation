import Foundation

/// Box to keep URLSession in a Sendable struct under Swift 6 strict concurrency.
private final class SessionBox: @unchecked Sendable {
    let value: URLSession
    init(_ value: URLSession) { self.value = value }
}

/// Small tolerant async HTTP client for the substationd REST API.
/// Every call returns nil / [] on any failure (timeout, offline, bad JSON).
struct DaemonClient: Sendable {
    let baseURL: String
    let token: String?
    private let session: SessionBox

    init(baseURL: String, token: String?) {
        self.baseURL = baseURL
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        self.session = SessionBox(URLSession(configuration: config))
    }

    private func makeRequest(_ path: String, method: String = "GET") -> URLRequest? {
        guard let url = URL(string: baseURL + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func fetchData(_ path: String, method: String = "GET") async -> Data? {
        guard let request = makeRequest(path, method: method) else { return nil }
        do {
            let (data, response) = try await session.value.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private func fetch<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET") async -> T? {
        guard let data = await fetchData(path, method: method) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: Endpoints

    func status() async -> StatusResponse? {
        await fetch(StatusResponse.self, "/api/status")
    }

    func metrics() async -> MetricsResponse? {
        await fetch(MetricsResponse.self, "/api/metrics")
    }

    func events(limit: Int = 5) async -> [EventEntry] {
        if let list = await fetch([EventEntry].self, "/api/events?limit=\(limit)") {
            return list
        }
        struct Wrapper: Codable, Sendable { let events: [EventEntry]? }
        return (await fetch(Wrapper.self, "/api/events?limit=\(limit)"))?.events ?? []
    }

    func nodes() async -> [NodeEntry] {
        if let list = await fetch([NodeEntry].self, "/api/nodes") {
            return list
        }
        struct Wrapper: Codable, Sendable { let nodes: [NodeEntry]? }
        return (await fetch(Wrapper.self, "/api/nodes"))?.nodes ?? []
    }

    func models() async -> [ModelEntry] {
        if let list = await fetch([ModelEntry].self, "/api/models") {
            return list
        }
        struct Wrapper: Codable, Sendable { let models: [ModelEntry]? }
        return (await fetch(Wrapper.self, "/api/models"))?.models ?? []
    }

    func config() async -> ConfigResponse? {
        await fetch(ConfigResponse.self, "/api/config")
    }

    @discardableResult
    func adminPause() async -> Bool { await post("/api/admin/pause") }
    @discardableResult
    func adminResume() async -> Bool { await post("/api/admin/resume") }
    @discardableResult
    func adminReload() async -> Bool { await post("/api/admin/reload") }

    @discardableResult
    func restartEngine(_ name: String) async -> Bool {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return await post("/api/models/\(enc)/restart")
    }

    @discardableResult
    func restartAllEngines() async -> Bool { await post("/api/engines/restart-all") }

    @discardableResult
    func restartDaemons() async -> Bool { await post("/api/cluster/restart-daemons") }

    private func post(_ path: String) async -> Bool {
        await fetchData(path, method: "POST") != nil
    }
}
