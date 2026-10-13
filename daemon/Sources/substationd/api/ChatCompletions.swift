import Foundation
import Vapor
import NIOCore
import NIOHTTP1

public enum APIError: Error {
    case badRequest(String)
    case paused
    case unauthorized
    case notFound(String)
    case upstream(String)
    case triageModelMissing(String)
    case noModelLoaded(String)

    public var abortResponse: Response {
        let code: String
        let status: HTTPResponseStatus
        let message: String
        switch self {
        case .badRequest(let m): status = .badRequest; code = "bad_request"; message = m
        case .paused: status = .serviceUnavailable; code = "paused"; message = "substationd is paused"
        case .unauthorized: status = .unauthorized; code = "unauthorized"; message = "missing or invalid bearer token"
        case .notFound(let m): status = .notFound; code = "not_found"; message = m
        case .upstream(let m): status = .badGateway; code = "upstream_error"; message = m
        case .triageModelMissing(let path):
            status = .serviceUnavailable; code = "triage_model_missing"
            message = "Auto mode requires the triage (small) model — not found at '\(path)'. Download it (or set orchestrator.triage_gguf) to unlock auto routing; until then select a specific model by name."
        case .noModelLoaded(let m):
            status = .serviceUnavailable; code = "no_model_loaded"
            message = m
        }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        let body: JSONValue = .object([
            "error": .object(["message": .string(message), "code": .string(code)]),
        ])
        return Response(status: status, headers: headers, body: .init(string: JSONCoding.encodeString(body)))
    }
}

public func jsonResponse(_ value: JSONValue, status: HTTPResponseStatus = .ok, extra: [(String, String)] = []) -> Response {
    var headers = HTTPHeaders()
    headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
    for (k, v) in extra { headers.replaceOrAdd(name: k, value: v) }
    return Response(status: status, headers: headers, body: .init(string: JSONCoding.encodeString(value, pretty: true)))
}

/// Shared engine-proxy pipeline for /v1/chat/completions and chat send.
public struct ChatPipeline: Sendable {
    public let orch: Orchestrator

    public init(orch: Orchestrator) { self.orch = orch }

    private static let paramKeys = ["temperature", "max_tokens", "max_completion_tokens", "top_p", "top_k", "seed", "stop", "frequency_penalty", "presence_penalty"]

    public static func cacheKey(model: String, body: JSONValue) -> String {
        var params: [String: JSONValue] = [:]
        for k in paramKeys { if let v = body[k] { params[k] = v } }
        let canonical = canonicalJSON(.object([
            "model": .string(model),
            "messages": body["messages"] ?? .array([]),
            "params": .object(params),
        ]))
        return sha256Hex(canonical)
    }

    /// OpenAI-compatible non-streaming completion, transparently re-labeled.
    public func complete(body: JSONValue, sessionKey: String?) async throws -> Response {
        let state = orch.state
        if await state.paused { throw APIError.paused }

        let virtual = body["model"]?.stringValue ?? "auto"
        let bytes = JSONCoding.encode(body).count
        let route = try await orch.route(
            requestedModel: body["model"]?.stringValue,
            messages: body["messages"],
            sessionKey: sessionKey
        )
        await orch.events.publish("request.received", [
            ("id", .string(route.requestId)),
            ("virtual_model", .string(virtual)),
            ("bytes", .jInt(bytes)),
            ("session", sessionKey.map { JSONValue.string($0) } ?? .null),
        ])

        let cfg = await orch.cfg.snapshot
        let key = Self.cacheKey(model: route.model, body: body)
        if cfg.cacheEnabled, let cached = await orch.cache.get(key, enabled: cfg.cacheEnabled) {
            await orch.admission.release()
            await orch.events.publish("cache.hit", [
                ("id", .string(route.requestId)), ("model", .string(route.model)),
            ])
            await orch.events.publish("engine.wait", [
                ("id", .string(route.requestId)), ("ms", .jInt(0)), ("reason", .string("cache")),
            ])
            await orch.metrics.increment("cache_hits")
            await orch.metrics.record("total_ms", 0)
            if var v = JSONCoding.decode(Data(cached.utf8))?.objectValue {
                v["model"] = .string(route.virtualModel)
                v["substation"] = .object([
                    "request_id": .string(route.requestId),
                    "tier": .string(route.tier),
                    "cached": .bool(true),
                ])
                return jsonResponse(.object(v), extra: [
                    ("X-Substation-Request-Id", route.requestId),
                    ("X-Substation-Tier", route.tier),
                ])
            }
        }
        await orch.metrics.increment("cache_misses")
        if let remote = route.remote {
            return try await remoteComplete(remote, route: route, body: body)
        }
        await orch.cache.noteCanonical(canonicalJSON(.object([
            "messages": body["messages"] ?? .array([]),
        ])))

        var engineBody = body.objectValue ?? [:]
        engineBody["model"] = .string(route.model)
        engineBody["stream"] = .bool(false)

        let t0 = Date()
        let status: Int
        let reply: JSONValue?
        do {
            (status, reply) = try await orch.client.json(
                method: "POST",
                url: route.engine.baseURL + "/v1/chat/completions",
                body: .object(engineBody),
                timeout: 600
            )
        } catch {
            await orch.admission.release()
            throw APIError.upstream("engine unreachable: \(error)")
        }
        await orch.admission.release()
        let totalMs = Date().timeIntervalSince(t0) * 1000

        guard status < 400, var out = reply?.objectValue else {
            throw APIError.upstream("engine status \(status)")
        }

        let completionTokens = (out["usage"]?["completion_tokens"]?.doubleValue)
            ?? Double((out["choices"]?[0]?["message"]?["content"]?.stringValue ?? "").split(separator: " ").count)
        let promptTokens = out["usage"]?["prompt_tokens"]?.doubleValue ?? 0
        await orch.usage.record(prompt: Int(promptTokens), completion: Int(completionTokens),
                                tier: route.tier, model: route.model)
        try? await orch.events.publish("usage.recorded", [
            ("id", .string(route.requestId)),
            ("prompt", .jInt(Int(promptTokens))),
            ("completion", .jInt(Int(completionTokens))),
            ("tier", .string(route.tier)),
            ("model", .string(route.model)),
            ("cached", .bool(false)),
        ])
        let tokS = totalMs > 0 ? completionTokens / (totalMs / 1000) : 0
        await orch.metrics.increment("requests_total")
        await orch.metrics.record("total_ms", totalMs)
        await orch.metrics.record("ttft_ms", totalMs)
        await orch.metrics.record("tok_s", tokS)
        await orch.metrics.record("tok_s.\(route.model)", tokS)
        await orch.metrics.record("total_ms.\(route.model)", totalMs)
        await orch.metrics.recordTokens(completionTokens, ms: totalMs)
        await orch.engines.touch(route.engine.key)
        await orch.events.publish("stream.done", [
            ("id", .string(route.requestId)),
            ("total_tokens", .jInt(Int(completionTokens))),
            ("ms", .jInt(Int(totalMs))),
            ("cached", .bool(false)),
        ])

        out["model"] = .string(route.virtualModel)
        if cfg.cacheEnabled {
            await orch.cache.set(key, JSONCoding.encodeString(.object(out)), maxEntries: cfg.cacheMaxEntries)
        }
        return jsonResponse(.object(out), extra: [
            ("X-Substation-Request-Id", route.requestId),
            ("X-Substation-Tier", route.tier),
        ])
    }

    /// Transparent SSE passthrough: rewrites model, counts tokens, emits events.
    /// When `chat`/`chatID` are given, the assistant message is persisted with
    /// the REAL model/node/tier (the public API never exposes these).
    public func stream(
        body: JSONValue, sessionKey: String?,
        chat: ChatActor? = nil, chatID: String? = nil,
        anthropic: String? = nil
    ) async throws -> Response {
        let state = orch.state
        if await state.paused { throw APIError.paused }

        let virtual = body["model"]?.stringValue ?? "auto"
        let bytes = JSONCoding.encode(body).count
        let route = try await orch.route(
            requestedModel: body["model"]?.stringValue,
            messages: body["messages"],
            sessionKey: sessionKey
        )
        await orch.events.publish("request.received", [
            ("id", .string(route.requestId)),
            ("virtual_model", .string(virtual)),
            ("bytes", .jInt(bytes)),
            ("session", sessionKey.map { JSONValue.string($0) } ?? .null),
        ])

        if let remote = route.remote {
            return try await remoteStream(remote, route: route, body: body)
        }

        var engineBody = body.objectValue ?? [:]
        engineBody["model"] = .string(route.model)
        engineBody["stream"] = .bool(true)
        // Ask the engine for an authoritative usage chunk (prompt token counts);
        // strip it from the forwarded stream unless the client asked for it.
        let clientWantsUsage = body["stream_options"]?["include_usage"]?.boolValue ?? false
        if engineBody["stream_options"] == nil {
            engineBody["stream_options"] = .object(["include_usage": .bool(true)])
        }
        let engineBodyJSON = JSONValue.object(engineBody)

        let orch = self.orch
        let id = route.requestId
        let tier = route.tier
        let model = route.model
        let engine = route.engine
        let virtualModel = route.virtualModel

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/event-stream")
        headers.replaceOrAdd(name: "X-Substation-Request-Id", value: id)
        headers.replaceOrAdd(name: "X-Substation-Tier", value: tier)
        headers.replaceOrAdd(name: .cacheControl, value: "no-cache")

        return Response(status: .ok, headers: headers, body: .init(asyncStream: { writer in
            let t0 = Date()
            let recorder = Recorder()
            var firstTokenMs: Double?
            var tokens = 0
            var usagePrompt = 0
            var usageCompletion = 0
            var lastTick = Date()
            var tickTokens = 0
            let batchMs = await orch.cfg.snapshot.wsTickBatchMs
            let anth = anthropic
            if let msgID = anth {
                let start: JSONValue = .object([
                    "type": .string("message_start"),
                    "message": .object([
                        "id": .string(msgID), "type": .string("message"), "role": .string("assistant"),
                        "model": .string(virtualModel), "content": .array([]),
                        "stop_reason": .null, "stop_sequence": .null,
                        "usage": .object(["input_tokens": .jInt(0), "output_tokens": .jInt(0)]),
                    ]),
                ])
                let block: JSONValue = .object([
                    "type": .string("content_block_start"), "index": .jInt(0),
                    "content_block": .object(["type": .string("text"), "text": .string("")]),
                ])
                try await writer.write(.buffer(ByteBuffer(string: "event: message_start\ndata: \(JSONCoding.encodeString(start))\n\n")))
                try await writer.write(.buffer(ByteBuffer(string: "event: content_block_start\ndata: \(JSONCoding.encodeString(block))\n\n")))
            }
            do {
                let stream = orch.client.streamSSE(url: engine.baseURL + "/v1/chat/completions", body: engineBodyJSON)
                for try await payload in stream {
                    let now = Date()
                    if firstTokenMs == nil {
                        firstTokenMs = now.timeIntervalSince(t0) * 1000
                        await orch.metrics.record("ttft_ms", firstTokenMs!)
                        await orch.metrics.record("ttft_ms.\(tier)", firstTokenMs!)
                        await orch.events.publish("stream.first_token", [
                            ("id", .string(id)), ("ttft_ms", .jInt(Int(firstTokenMs!))),
                        ])
                    }
                    if payload == "[DONE]" {
                        try await writer.write(.buffer(ByteBuffer(string: "data: [DONE]\n\n")))
                        continue
                    }
                    // Authoritative usage chunk (choices empty + usage object): capture, don't count as token.
                    if payload.contains("\"usage\""),
                       let uObj = JSONCoding.decode(Data(payload.utf8))?.objectValue,
                       uObj["choices"]?.arrayValue?.isEmpty ?? false
                    {
                        usagePrompt = Int(uObj["usage"]?["prompt_tokens"]?.doubleValue ?? 0)
                        usageCompletion = Int(uObj["usage"]?["completion_tokens"]?.doubleValue ?? 0)
                        if clientWantsUsage {
                            try await writer.write(.buffer(ByteBuffer(string: "data: \(payload)\n\n")))
                        }
                        continue
                    }
                    tokens += 1
                    tickTokens += 1
                    // Transparency: rewrite the engine's real model to the virtual name.
                    var outStr = "data: \(payload)\n\n"
                    var deltaText = ""
                    if var obj = JSONCoding.decode(Data(payload.utf8))?.objectValue {
                        if let choice = obj["choices"]?[0],
                           let piece = choice["delta"]?["content"]?.stringValue
                        {
                            deltaText = piece
                        }
                        obj["model"] = .string(virtualModel)
                        outStr = "data: \(JSONCoding.encodeString(.object(obj)))\n\n"
                    }
                    if !deltaText.isEmpty { recorder.append(deltaText) }
                    if anth != nil {
                        if !deltaText.isEmpty {
                            let d: JSONValue = .object([
                                "type": .string("content_block_delta"), "index": .jInt(0),
                                "delta": .object(["type": .string("text_delta"), "text": .string(deltaText)]),
                            ])
                            try await writer.write(.buffer(ByteBuffer(string: "event: content_block_delta\ndata: \(JSONCoding.encodeString(d))\n\n")))
                        }
                    } else {
                        try await writer.write(.buffer(ByteBuffer(string: outStr)))
                    }

                    if Date().timeIntervalSince(lastTick) * 1000 >= Double(batchMs) {
                        let sec = max(0.25, Date().timeIntervalSince(lastTick))
                        await orch.events.publish("stream.tick", [
                            ("id", .string(id)),
                            ("tokens", .jInt(tokens)),
                            ("tok_per_s", .jDouble((Double(tickTokens) / sec * 10).rounded() / 10)),
                        ])
                        lastTick = Date()
                        tickTokens = 0
                    }
                }
                if let msgID = anth {
                    let outTok = Int(usageCompletion > 0 ? usageCompletion : tokens)
                    let stop: JSONValue = .object(["type": .string("content_block_stop"), "index": .jInt(0)])
                    let md: JSONValue = .object([
                        "type": .string("message_delta"),
                        "delta": .object(["stop_reason": .string("end_turn"), "stop_sequence": .null]),
                        "usage": .object(["output_tokens": .jInt(outTok)]),
                    ])
                    let ms: JSONValue = .object(["type": .string("message_stop"), "message_id": .string(msgID)])
                    try await writer.write(.buffer(ByteBuffer(string: "event: content_block_stop\ndata: \(JSONCoding.encodeString(stop))\n\n")))
                    try await writer.write(.buffer(ByteBuffer(string: "event: message_delta\ndata: \(JSONCoding.encodeString(md))\n\n")))
                    try await writer.write(.buffer(ByteBuffer(string: "event: message_stop\ndata: \(JSONCoding.encodeString(ms))\n\n")))
                }
                try await writer.write(.end)
            } catch {
                try? await writer.write(.end)
            }

            let totalMs = Date().timeIntervalSince(t0) * 1000
            let completionTokens = usageCompletion > 0 ? Double(usageCompletion) : Double(tokens)
            let tokS = totalMs > 0 ? completionTokens / (totalMs / 1000) : 0
            await orch.admission.release()
            await orch.metrics.increment("requests_total")
            await orch.metrics.record("total_ms", totalMs)
            await orch.metrics.record("tok_s", tokS)
            await orch.metrics.record("tok_s.\(model)", tokS)
            await orch.metrics.record("total_ms.\(model)", totalMs)
            await orch.metrics.recordTokens(completionTokens, ms: totalMs)
            await orch.usage.record(prompt: usagePrompt, completion: Int(completionTokens),
                                    tier: tier, model: model)
            try? await orch.events.publish("usage.recorded", [
                ("id", .string(id)),
                ("prompt", .jInt(usagePrompt)),
                ("completion", .jInt(Int(completionTokens))),
                ("tier", .string(tier)),
                ("model", .string(model)),
                ("cached", .bool(false)),
            ])
            await orch.engines.touch(engine.key)
            await orch.events.publish("stream.done", [
                ("id", .string(id)),
                ("total_tokens", .jInt(Int(completionTokens))),
                ("ms", .jInt(Int(totalMs))),
                ("cached", .bool(false)),
            ])
            if let chat, let chatID {
                _ = await chat.append(chatID, ChatMessage(
                    role: "assistant", content: recorder.value,
                    tier: tier, model: model, node: engine.node,
                    tok_s: (tokS * 100).rounded() / 100
                ))
                await orch.events.publish("chat.stream_persisted", [
                    ("id", .string(id)), ("model", .string(model)), ("node", .string(engine.node)),
                ])
            }
        }))
    }
}

/// Lock-protected delta accumulator used inside the SSE writer closure.
public final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    public init() {}

    public func append(_ s: String) {
        lock.lock(); text += s; lock.unlock()
    }

    public var value: String {
        lock.lock(); defer { lock.unlock() }
        return text
    }
}

extension JSONValue {
    func boolOrTrue(_ d: Bool) -> Bool { boolValue ?? d }
}
