import Foundation
import Combine

/// Polls the daemon every 2s and publishes the latest snapshot.
/// Never throws: offline / bad payloads simply produce nil/empty values.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: StatusResponse?
    @Published private(set) var metrics: MetricsResponse?
    @Published private(set) var events: [EventEntry] = []
    @Published private(set) var nodes: [NodeEntry] = []
    @Published private(set) var models: [ModelEntry] = []
    @Published private(set) var clusterEnabled: Bool = false
    @Published private(set) var offline: Bool = true
    @Published private(set) var lastUpdated: Date?

    @Published private(set) var baseURL: String

    private var client: DaemonClient
    private var pollTask: Task<Void, Never>?
    private var optimisticPaused: Bool?

    init() {
        let base = Settings.resolvedBaseURL()
        self.baseURL = base
        self.client = DaemonClient(baseURL: base, token: Settings.authToken())
    }

    var isPaused: Bool {
        if let optimisticPaused { return optimisticPaused }
        return status?.isPaused ?? false
    }

    var isOnline: Bool { !offline }

    var degradedAuto: Bool { status?.isDegradedAuto ?? false }

    var tokensPerSec: Double? { status?.tokensPerSec ?? metrics?.tokensPerSec }
    var requestsPerMin: Double? { status?.requestsPerMin ?? metrics?.requestsPerMin }
    var requestsActive: Int? { status?.requestsActive ?? metrics?.requestsActive }
    var cacheHitRatio: Double? { metrics?.cacheHitRatio }

    // MARK: Lifecycle

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func reloadBase() {
        let resolved = Settings.resolvedBaseURL()
        baseURL = resolved
        client = DaemonClient(baseURL: resolved, token: Settings.authToken())
        optimisticPaused = nil
        Task { await refresh() }
    }

    // MARK: Polling

    func refresh() async {
        async let status = client.status()
        async let metrics = client.metrics()
        async let events = client.events(limit: 5)
        async let nodes = client.nodes()
        async let models = client.models()
        async let config = client.config()

        let (statusValue, metricsValue, eventsValue, nodesValue, modelsValue, configValue) =
            await (status, metrics, events, nodes, models, config)

        let statusFailed = statusValue == nil
        let metricsFailed = metricsValue == nil
        self.offline = statusFailed && metricsFailed

        if !statusFailed { self.status = statusValue }
        if !metricsFailed { self.metrics = metricsValue }
        self.events = eventsValue
        self.nodes = nodesValue
        self.models = modelsValue
        self.clusterEnabled = configValue?.clusterEnabled ?? self.clusterEnabled

        if statusValue != nil {
            self.optimisticPaused = nil
        }
        self.lastUpdated = Date()
    }

    // MARK: Admin actions

    func pauseRouting() {
        optimisticPaused = true
        let client = self.client
        Task {
            _ = await client.adminPause()
            await self.refresh()
        }
    }

    func resumeRouting() {
        optimisticPaused = false
        let client = self.client
        Task {
            _ = await client.adminResume()
            await self.refresh()
        }
    }

    func reloadConfig() {
        let client = self.client
        Task {
            _ = await client.adminReload()
            await self.refresh()
        }
    }

    // MARK: Formatting helpers

    var stateLabel: String {
        if offline { return "offline" }
        if isPaused { return "paused" }
        return status?.state ?? "online"
    }

    var barTitle: String {
        if offline { return "—" }
        let tok = tokensPerSec ?? 0
        return "\(Int(tok.rounded())) t/s"
    }

    var uptimeLabel: String {
        guard !offline, let seconds = status?.uptimeSec else { return "—" }
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    var cacheHitLabel: String {
        guard let ratio = cacheHitRatio else { return "—" }
        let pct = ratio <= 1.0 ? ratio * 100 : ratio
        return String(format: "%.0f%%", pct)
    }

    var loadedModels: [ModelEntry] {
        let fromStatus = status?.models ?? []
        if !fromStatus.isEmpty {
            return fromStatus.compactMap { entry -> ModelEntry? in
                guard (entry.loaded ?? true) else { return nil }
                return ModelEntry(
                    name: entry.displayName,
                    model: nil,
                    tier: entry.tier,
                    node: entry.node,
                    sizeGB: entry.sizeGB,
                    loaded: true,
                    state: "loaded",
                    ownedBy: nil
                )
            }
        }
        return Array(models.filter { $0.isLoaded && !$0.isVirtual }.prefix(8))
    }
}

extension ModelEntry {
    var isVirtual: Bool {
        ownedBy?.lowercased() == "substation-virtual"
    }
}
