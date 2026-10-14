import XCTest
@testable import substationd

/// Unit tests for the pure logic that broke silently before: the GPU-aware KV
/// sizing, the co-residency footprint, placement parsing, the resource
/// estimator, and the TOML round-trip used by `config export`/`diff`.
final class CoreLogicTests: XCTestCase {

    // MARK: - Placement parsing

    func testPlacementParse() {
        XCTAssertEqual(Placement.parse("local"), .local)
        XCTAssertEqual(Placement.parse(""), .local)
        XCTAssertEqual(Placement.parse("node:studio1"), .node("studio1"))
        XCTAssertEqual(Placement.parse("split:studio0+studio1"), .split(["studio0", "studio1"]))
        XCTAssertEqual(Placement.parse("split:local+studio0"), .split(["local", "studio0"]))
    }

    // MARK: - RunningEngine GPU footprint

    func testGPUFootprint() {
        let e = RunningEngine(
            model: "m", node: "local", host: "127.0.0.1", port: 1, pid: 1,
            split: false, rpcPeers: [], placement: "local",
            loadedAt: Date(), lastUsed: Date(), sizeGB: 20, ctx: 1_048_576, kvMBPer1k: 24,
            headWeightFraction: 1.0
        )
        // KV GB = (1048576/1024) * 24 / 1024 = 1024 * 24 / 1024 = 24 GB
        // footprint = weights(20) + kv(24) + overhead(1) = 45
        XCTAssertEqual(e.gpuFootprintGB, 45.0, accuracy: 0.001)
    }

    func testGPUFootprintSmallCtx() {
        let e = RunningEngine(
            model: "m", node: "local", host: "127.0.0.1", port: 1, pid: 1,
            split: false, rpcPeers: [], placement: "local",
            loadedAt: Date(), lastUsed: Date(), sizeGB: 4, ctx: 8192, kvMBPer1k: 100,
            headWeightFraction: 1.0
        )
        // KV GB = (8192/1024)*100/1024 = 8*100/1024 = 0.78125
        XCTAssertEqual(e.gpuFootprintGB, 4 + 0.78125 + 1, accuracy: 0.001)
    }

    // MARK: - GPU-aware cache sizing (the co-residency guard)

    private func sized(free: Double, limit: Double, resident: Double, size: Double,
                      slots: Int, kv: Double, ctx: Int) -> Int {
        EngineActor.sizedCacheTokens(freeGB: free, gpuLimitGB: limit, residentGPU: resident,
                                   sizeGB: size, slots: slots, kvMBPer1k: kv, ctx: ctx)
    }

    func testCachePlentyOfHeadroomHitsCtxCeiling() {
        // Lots of RAM + GPU → capped at the model's native ctx × slots.
        let total = sized(free: 200, limit: 192, resident: 0, size: 20, slots: 4, kv: 24, ctx: 262_144)
        XCTAssertEqual(total, 262_144 * 4)
    }

    func testCacheGPUPressureShrinksKV() {
        // A big model already resident squeezes the new model's KV well below ctx.
        let plenty = sized(free: 200, limit: 192, resident: 0, size: 20, slots: 4, kv: 24, ctx: 262_144)
        let squeezed = sized(free: 200, limit: 192, resident: 150, size: 20, slots: 4, kv: 24, ctx: 262_144)
        XCTAssertLessThan(squeezed, plenty, "resident GPU must reduce the KV allocation")
        XCTAssertGreaterThan(squeezed, 2048 * 4, "still leaves a usable minimum")
        // ~290k for these inputs; assert a band to stay robust to float rounding.
        XCTAssertGreaterThan(squeezed, 250_000)
        XCTAssertLessThan(squeezed, 320_000)
    }

    func testCacheWeightsBlowBudgetFallsToMinimum() {
        // Weights + resident already exceed the wired limit → minimal KV.
        let total = sized(free: 200, limit: 192, resident: 180, size: 20, slots: 4, kv: 24, ctx: 262_144)
        XCTAssertEqual(total, 2048 * 4)
    }

    func testCacheRAMConstrainedBelowGPU() {
        // Low free RAM limits KV even when GPU has room.
        let total = sized(free: 5, limit: 192, resident: 0, size: 20, slots: 4, kv: 24, ctx: 262_144)
        XCTAssertLessThan(total, 262_144 * 4)
        XCTAssertGreaterThanOrEqual(total, 2048 * 4)
    }

    func testCacheInvariants() {
        // Across a spread of scenarios: always a multiple of slots, within [2048·slots, ctx·slots].
        let scenarios: [(Double, Double, Double)] = [(200, 192, 0), (200, 192, 150), (5, 192, 0), (100, 192, 90), (2, 192, 180)]
        let slots = 4, ctx = 262_144
        for (free, limit, resident) in scenarios {
            let total = sized(free: free, limit: limit, resident: resident, size: 20, slots: slots, kv: 24, ctx: ctx)
            XCTAssertEqual(total % slots, 0, "total must be slots × per-slot")
            XCTAssertGreaterThanOrEqual(total, 2048 * slots)
            XCTAssertLessThanOrEqual(total, ctx * slots)
        }
    }

    // MARK: - Resource estimator

    func testEstimatorFitsSmallModel() {
        let m = makeModel(name: "small", sizeGB: 4, ctx: 8192, slots: 4, kv: 100)
        let est = ResourceEstimator.estimate(model: m, freeGB: 100, totalGB: 256, residentGB: 0, minFreeGB: 8)
        XCTAssertTrue(est.fits, "small model should fit: \(est.warnings)")
    }

    func testEstimatorFlagsOversizedModel() {
        // 300 GB weights exceeds any realistic wired limit.
        let m = makeModel(name: "huge", sizeGB: 300, ctx: 8192, slots: 4, kv: 100)
        let est = ResourceEstimator.estimate(model: m, freeGB: 100, totalGB: 256, residentGB: 0, minFreeGB: 8)
        XCTAssertFalse(est.fitsGPU, "300 GB should not fit the GPU wired limit")
        XCTAssertFalse(est.warnings.isEmpty)
    }

    // MARK: - TOML round-trip (config export/diff)

    func testTOMLRoundTrip() {
        let src = """
        [daemon]
        auth_token = ""
        [engines]
        startup_timeout_s = 180.0
        base_port = 8940
        [orchestrator]
        enabled = true
        reasoning_reserve_tokens = 2048
        [[models]]
        name = "qwen3.5-35b-a3b"
        tier = "fast"
        ctx = 262144
        reasoning = true
        [[models]]
        name = "ornith-1t"
        tier = "balanced"
        ctx = 262144
        """
        let parsed = TOML.parse(src)
        let written = TOML.write(parsed)
        let reparsed = TOML.parse(written)
        XCTAssertEqual(parsed, reparsed, "TOML parse→write→parse must be lossless")
        // Spot-check a few values survived.
        XCTAssertEqual(parsed["engines"]?["startup_timeout_s"]?.doubleValue, 180.0)
        XCTAssertEqual(parsed["orchestrator"]?["reasoning_reserve_tokens"]?.intValue, 2048)
        let models = parsed["models"]?.arrayValue ?? []
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models.first?["name"]?.stringValue, "qwen3.5-35b-a3b")
        XCTAssertEqual(models.first?["reasoning"]?.boolValue, true)
    }

    // MARK: - Config diff

    func testConfigDiffDetectsDrift() {
        let live = TOML.parse("""
        [engines]
        startup_timeout_s = 180.0
        base_port = 8940
        """)
        let file = TOML.parse("""
        [engines]
        startup_timeout_s = 900.0
        base_port = 8940
        extra = true
        """)
        var diffs: [String] = []
        CLI.diffValues(live, file, into: &diffs)
        XCTAssertFalse(diffs.isEmpty, "should detect the timeout drift + extra key")
        XCTAssertTrue(diffs.contains { $0.contains("startup_timeout_s") })
        XCTAssertTrue(diffs.contains { $0.contains("extra") })
    }

    func testConfigDiffIdentical() {
        let a = TOML.parse("[engines]\nstartup_timeout_s = 180.0\n")
        let b = TOML.parse("[engines]\nstartup_timeout_s = 180.0\n")
        var diffs: [String] = []
        CLI.diffValues(a, b, into: &diffs)
        XCTAssertTrue(diffs.isEmpty, "identical configs should produce no diffs: \(diffs)")
    }

    // MARK: - RPC/split head-weight fraction

    func testHeadWeightFraction() {
        XCTAssertEqual(EngineActor.headWeightFraction(splitWeights: ["1"]), 1.0, accuracy: 0.0001)
        XCTAssertEqual(EngineActor.headWeightFraction(splitWeights: ["1", "1"]), 0.5, accuracy: 0.0001)
        XCTAssertEqual(EngineActor.headWeightFraction(splitWeights: ["1", "2"]), 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(EngineActor.headWeightFraction(splitWeights: ["2", "1", "1"]), 0.5, accuracy: 0.0001)
        XCTAssertEqual(EngineActor.headWeightFraction(splitWeights: []), 1.0, accuracy: 0.0001)
        XCTAssertEqual(EngineActor.headWeightFraction(splitWeights: ["0", "1"]), 1.0, accuracy: 0.0001, "degenerate head weight → full")
    }

    func testSplitHeadFootprintUsesShard() {
        // 150 GB model, even 2-way split → head holds 75 GB weights + KV.
        let e = RunningEngine(
            model: "big", node: "studio0", host: "h", port: 1, pid: 1,
            split: true, rpcPeers: ["studio1"], placement: "split:studio0+studio1",
            loadedAt: Date(), lastUsed: Date(), sizeGB: 150, ctx: 1_048_576,
            kvMBPer1k: 24, headWeightFraction: 0.5
        )
        // weights 75 + kv 24 + overhead 1 = 100 (not 175 as full-size would give)
        XCTAssertEqual(e.gpuFootprintGB, 75 + 24 + 1, accuracy: 0.001)
    }

    // MARK: - nodes / replication parsing

    func testNodesAndReplicatedParsing() {
        let tree = TOML.parse("""
        [[models]]
        name = "single"
        node = "studio0"
        [[models]]
        name = "replicated"
        nodes = ["studio0", "studio1"]
        """)
        let cfg = ConfigSnapshot(raw: tree)
        let single = cfg.model("single")!
        XCTAssertEqual(single.nodes, ["studio0"])
        XCTAssertFalse(single.isReplicated)
        let rep = cfg.model("replicated")!
        XCTAssertEqual(rep.nodes, ["studio0", "studio1"])
        XCTAssertTrue(rep.isReplicated)
    }

    // MARK: - Helpers

    private func makeModel(name: String, sizeGB: Double, ctx: Int, slots: Int, kv: Double) -> CatalogModel {
        CatalogModel(
            name: name, gguf: "/tmp/\(name).gguf", dir: nil, file: nil, tier: "balanced",
            sizeGB: sizeGB, ctx: ctx, placement: "local", node: nil, nodes: [], kind: "local",
            baseUrl: nil, apiKey: nil, remoteModel: nil, proto: "openai", flags: [],
            kvMBPer1k: kv, slots: slots, mmproj: nil, vision: false, enabled: true,
            tensorSplit: "", cacheReuse: 256, cacheRamMiB: 8192, cacheIdleSlots: true,
            reasoning: false
        )
    }
}
