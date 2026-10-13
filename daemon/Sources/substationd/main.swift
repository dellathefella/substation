import Vapor
import Logging

let argList = Array(CommandLine.arguments.dropFirst())

// CLI modes first (thin REST clients, §7 + §6).
if argList.first == "admin" || argList.first == "join" {
    exit(await CLI.run(argList))
}
if argList.first == "mcp" {
    let env = ProcessInfo.processInfo.environment
    await MCP.stdio(
        base: env["SUBSTATION_URL"] ?? "http://127.0.0.1:8800",
        bearer: env["SUBSTATION_TOKEN"] ?? ""
    )
    exit(0)
}

var role = "controller"
var configPath = "./config/substation.toml"
var dataDir = "./state"
var authTokenFlag = ""
var idx = 0
while idx < argList.count {
    switch argList[idx] {
    case "--role":
        if idx + 1 < argList.count { role = argList[idx + 1]; idx += 1 }
    case "--config":
        if idx + 1 < argList.count { configPath = argList[idx + 1]; idx += 1 }
    case "--data":
        if idx + 1 < argList.count { dataDir = argList[idx + 1]; idx += 1 }
    case "--auth-token":
        if idx + 1 < argList.count { authTokenFlag = argList[idx + 1]; idx += 1 }
    default:
        break
    }
    idx += 1
}

LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardError(label: label)
    handler.logLevel = Environment.get("SUBSTATION_LOG_LEVEL").flatMap(Logger.Level.init(rawValue:)) ?? .info
    return handler
}

let cfg = try ConfigStore(path: configPath)
// API key via flag or env (SUBSTATION_TOKEN); persisted so rotation owns it thereafter.
let keyOverride = !authTokenFlag.isEmpty ? authTokenFlag : (Environment.get("SUBSTATION_TOKEN") ?? "")
if !keyOverride.isEmpty { _ = try? await cfg.setDotted("daemon.auth_token", .string(keyOverride)) }
let events = EventActor()
let metrics = MetricsActor()
let mem = Memory()
let admission = Admission()
let sessions = SessionActor()
let cache = ResponseCache()
let state = DaemonState()
let chat = ChatActor(dataDir: dataDir)
let nodes = NodesActor(dataDir: dataDir + "/cluster")
let engines = EngineActor(events: events, metrics: metrics, mem: mem, nodes: nodes)

let snapshot = await cfg.snapshot
await events.configure(ringSize: snapshot.eventRingSize)
await admission.configure(snapshot.maxConcurrentRequests)

func absolute(_ p: String) -> String {
    (p as NSString).isAbsolutePath ? p : FileManager.default.currentDirectoryPath + "/" + p
}

var env = Environment(name: "production", arguments: ["substationd", "serve"])
let app = try await Application.make(env)
let port = role == "node" ? snapshot.agentPort : snapshot.port
let bindOverride = Environment.get("SUBSTATION_BIND")
app.http.server.configuration.hostname = bindOverride ?? snapshot.bind
app.http.server.configuration.port = port

if FileManager.default.fileExists(atPath: absolute(snapshot.webuiDist)) {
    app.middleware.use(FileMiddleware(publicDirectory: absolute(snapshot.webuiDist)))
}

if role == "node" {
    let nodeKit = NodeKit(cfg: cfg, events: events, engines: engines, mem: mem, dataDir: dataDir)
    try NodeRoutes.register(app, nodeKit)
    await engines.startLoops(cfg: snapshot, cfgStore: cfg)
    if snapshot.clusterEnabled {
        _ = await engines.startRPCSelf(snapshot)
    }
    startBeaconSender(nodeKit)
    NSLog("substationd node agent listening on http://\(snapshot.bind):\(port) (node_id \(nodeKit.nodeId.prefix(8)))")
} else {
    let kit = Kit(
        cfg: cfg, events: events, metrics: metrics, engines: engines, admission: admission,
        sessions: sessions, cache: cache, state: state, chat: chat, nodes: nodes, mem: mem
    )
    try Routes.registerController(app, kit)

    // Static config nodes join the registry when clustering is enabled.
    if snapshot.clusterEnabled {
        for n in snapshot.nodes {
            await nodes.register(id: n.id, name: n.id, ip: n.host, agentPort: n.agentPort, rpcPort: n.rpcPort)
        }
        _ = await engines.startRPCSelf(snapshot)
    }

    await engines.startTriageIfNeeded(snapshot)
    await engines.startLoops(cfg: snapshot, cfgStore: cfg)
    startHeartbeat(kit)
    startLinkProbeLoop(kit)
    startBeaconListener(kit)
    NSLog("substationd controller listening on http://\(snapshot.bind):\(port)")
}

try await app.execute()
try await app.asyncShutdown()

// MARK: - Background loops

func startHeartbeat(_ kit: Kit) {
    Task.detached(priority: .utility) {
        while !Task.isCancelled {
            let cfg = await kit.cfg.snapshot
            try? await Task.sleep(for: .milliseconds(max(500, cfg.heartbeatMs)))
            guard cfg.clusterEnabled else { continue }
            for n in await kit.nodes.allNodes() {
                let url = "http://\(n.ip):\(n.agentPort)/api/node/health"
                if let (status, val) = try? await kit.client.json(method: "GET", url: url, bearer: cfg.authToken, timeout: 3),
                   status == 200
                {
                    await kit.nodes.setHealth(id: n.id, healthy: true, health: val)
                    var data = val?.objectValue ?? [:]
                    data["node"] = .string(n.id)
                    await kit.events.publish("node.health", .object(data))
                } else {
                    await kit.nodes.setHealth(id: n.id, healthy: false, health: nil)
                }
            }
        }
    }
}

func startLinkProbeLoop(_ kit: Kit) {
    Task.detached(priority: .background) {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            let cfg = await kit.cfg.snapshot
            guard cfg.clusterEnabled else { continue }
            for n in await kit.nodes.allNodes() {
                let link = await LinkProbe.probe(
                    host: n.ip, agentPort: n.agentPort,
                    probeMB: cfg.probeBytesMB, cfg: cfg, events: kit.events, client: kit.client
                )
                await kit.nodes.setLink(id: n.id, link: link)
            }
        }
    }
}

func startBeaconListener(_ kit: Kit) {
    let nodes = kit.nodes
    let thread = Thread {
        BeaconTransport.listenForever { data in
            guard var beacon = try? JSONDecoder().decode(Beacon.self, from: data), beacon.magic == "SUBJ" else { return }
            if beacon.ip.isEmpty { beacon.ip = "127.0.0.1" }
            Task { await nodes.ingestBeacon(beacon) }
        }
    }
    thread.name = "substation-beacon-listener"
    thread.start()
}

/// Node agents announce themselves every 5 s (§6).
func startBeaconSender(_ kit: NodeKit) {
    Task.detached(priority: .background) {
        while !Task.isCancelled {
            let cfg = await kit.cfg.snapshot
            let code = kit.currentJoinCode()
            let beacon = Beacon(
                node_id: kit.nodeId,
                name: kit.nodeName,
                ip: HostInfo.primaryIP(),
                agent_port: cfg.agentPort,
                version: Routes.version,
                join_hash: BeaconTransport.joinHash(code: code, nodeId: kit.nodeId)
            )
            BeaconTransport.send(beacon, port: BeaconTransport.port)
            try? await Task.sleep(for: .seconds(5))
        }
    }
}
