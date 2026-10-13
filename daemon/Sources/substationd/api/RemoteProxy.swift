import Foundation
import Vapor

/// Proxying for remote/external profiles (cloud providers or already-running
/// servers). Requests are translated to the upstream wire protocol, the
/// response is translated back to OpenAI shape, and the model field is
/// re-labelled to the virtual name so switching stays transparent.
extension ChatPipeline {
    static func remoteHeaders(_ t: RemoteTarget) -> [(String, String)] {
        if t.proto == "anthropic" {
            var h = [("anthropic-version", "2023-06-01")]
            if let k = t.key, !k.isEmpty { h.append(("x-api-key", k)) }
            return h
        }
        if let k = t.key, !k.isEmpty { return [("Authorization", "Bearer \(k)")] }
        return []
    }

    static func remoteURL(_ t: RemoteTarget) -> String {
        t.url + (t.proto == "anthropic" ? "/v1/messages" : "/v1/chat/completions")
    }

    /// OpenAI request → Anthropic request.
    static func toAnthropicRequest(_ body: JSONValue, model: String) -> JSONValue {
        var msgs: [JSONValue] = []
        var system = ""
        for m in body["messages"]?.arrayValue ?? [] {
            let role = m["role"]?.stringValue ?? "user"
            let text = Routes.flattenContent(m["content"])
            if role == "system" { system = system.isEmpty ? text : system + "\n" + text }
            else { msgs.append(.object(["role": .string(role), "content": .string(text)])) }
        }
        var obj: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(msgs),
            "max_tokens": body["max_tokens"] ?? body["max_completion_tokens"] ?? .jInt(4096),
        ]
        if !system.isEmpty { obj["system"] = .string(system) }
        if let t = body["temperature"] { obj["temperature"] = t }
        if let p = body["top_p"] { obj["top_p"] = p }
        if let s = body["stop"] { obj["stop_sequences"] = s }
        if body["stream"]?.boolValue == true { obj["stream"] = .bool(true) }
        return .object(obj)
    }

    /// Anthropic response → OpenAI chat.completion.
    static func fromAnthropicResponse(_ a: JSONValue, virtual: String) -> JSONValue {
        let text = Routes.flattenContent(a["content"])
        let finish: String
        switch a["stop_reason"]?.stringValue {
        case "max_tokens": finish = "length"
        default: finish = "stop"
        }
        return .object([
            "id": a["id"] ?? .string("chatcmpl-remote"),
            "object": .string("chat.completion"),
            "model": .string(virtual),
            "choices": .array([.object([
                "index": .jInt(0),
                "message": .object(["role": .string("assistant"), "content": .string(text)]),
                "finish_reason": .string(finish),
            ])]),
            "usage": .object([
                "prompt_tokens": a["usage"]?["input_tokens"] ?? .jInt(0),
                "completion_tokens": a["usage"]?["output_tokens"] ?? .jInt(0),
            ]),
        ])
    }

    /// Anthropic streaming event → OpenAI chunk (nil = drop frame).
    static func fromAnthropicChunk(_ payload: String, virtual: String) -> String? {
        guard var obj = JSONCoding.decode(Data(payload.utf8))?.objectValue,
              let type = obj["type"]?.stringValue else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        switch type {
        case "content_block_delta":
            guard let text = obj["delta"]?["text"]?.stringValue, !text.isEmpty else { return nil }
            return JSONCoding.encodeString(.object([
                "id": .string("chatcmpl-remote"),
                "object": .string("chat.completion.chunk"),
                "model": .string(virtual), "created": .jInt(now),
                "choices": .array([.object(["index": .jInt(0), "delta": .object(["content": .string(text)])])]),
            ]))
        case "message_delta":
            return JSONCoding.encodeString(.object([
                "choices": .array([.object([
                    "index": .jInt(0), "delta": .object([:]),
                    "finish_reason": .string("stop"),
                ])]),
                "model": .string(virtual), "created": .jInt(now),
                "usage": .object([
                    "prompt_tokens": .jInt(0),
                    "completion_tokens": obj["usage"]?["output_tokens"] ?? .jInt(0),
                ]),
            ]))
        default:
            return nil
        }
    }

    private func finishRemote(route: RouteInfo, status: Int, reply: JSONValue?) async throws -> Response {
        let orch = self.orch
        let totalMs = Date().timeIntervalSince(route.engine.loadedAt) * 1000
        guard status < 400, var out = reply?.objectValue else {
            let msg = reply?["error"]?["message"]?.stringValue ?? "status \(status)"
            try? await orch.events.publish("stream.error", [
                ("id", .string(route.requestId)), ("node", .string("remote")), ("detail", .string(msg)),
            ])
            throw APIError.upstream("remote \(route.reason): \(msg)")
        }
        let completionTokens = out["usage"]?["completion_tokens"]?.doubleValue ?? 0
        let promptTokens = out["usage"]?["prompt_tokens"]?.doubleValue ?? 0
        let tokS = totalMs > 0 ? completionTokens / max(0.001, totalMs / 1000) : 0
        await orch.usage.record(prompt: Int(promptTokens), completion: Int(completionTokens),
                                tier: route.tier, model: route.model)
        await orch.metrics.increment("requests_total")
        await orch.metrics.record("total_ms", totalMs)
        await orch.metrics.record("ttft_ms", totalMs)
        await orch.metrics.record("tok_s", tokS)
        await orch.metrics.record("tok_s.\(route.model)", tokS)
        await orch.metrics.record("total_ms.\(route.model)", totalMs)
        await orch.metrics.recordTokens(completionTokens, ms: totalMs)
        try? await orch.events.publish("usage.recorded", [
            ("id", .string(route.requestId)),
            ("prompt", .jInt(Int(promptTokens))), ("completion", .jInt(Int(completionTokens))),
            ("tier", .string(route.tier)), ("model", .string(route.model)), ("cached", .bool(false)),
        ])
        try? await orch.events.publish("stream.done", [
            ("id", .string(route.requestId)), ("total_tokens", .jInt(Int(completionTokens))),
            ("ms", .jInt(Int(totalMs))), ("cached", .bool(false)),
        ])
        out["model"] = .string(route.virtualModel)
        out["substation"] = .object([
            "request_id": .string(route.requestId), "tier": .string(route.tier), "remote": .bool(true),
        ])
        return jsonResponse(.object(out), extra: [
            ("X-Substation-Request-Id", route.requestId), ("X-Substation-Tier", route.tier),
        ])
    }

    func remoteComplete(_ t: RemoteTarget, route: RouteInfo, body: JSONValue) async throws -> Response {
        let orch = self.orch
        let openaiBody: JSONValue
        if t.proto == "anthropic" {
            var b = body.objectValue ?? [:]
            b["stream"] = .bool(false)
            openaiBody = Self.toAnthropicRequest(.object(b), model: t.model)
        } else {
            var b = body.objectValue ?? [:]
            b["model"] = .string(t.model)
            b["stream"] = .bool(false)
            b.removeValue(forKey: "stream_options")
            openaiBody = .object(b)
        }
        let status: Int
        let reply: JSONValue?
        do {
            (status, reply) = try await orch.client.json(method: "POST", url: Self.remoteURL(t),
                                                         body: openaiBody, timeout: 600,
                                                         headers: Self.remoteHeaders(t))
        } catch {
            throw APIError.upstream("remote unreachable: \(error)")
        }
        var raw = reply
        if t.proto == "anthropic", status < 400, let r = reply { raw = Self.fromAnthropicResponse(r, virtual: route.virtualModel) }
        return try await finishRemote(route: route, status: status, reply: raw)
    }

    func remoteStream(_ t: RemoteTarget, route: RouteInfo, body: JSONValue) async throws -> Response {
        let orch = self.orch
        var b = body.objectValue ?? [:]
        b["stream"] = .bool(true)
        let upstream: JSONValue
        if t.proto == "anthropic" {
            b.removeValue(forKey: "stream_options")
            upstream = Self.toAnthropicRequest(.object(b), model: t.model)
        } else {
            b["model"] = .string(t.model)
            b["stream_options"] = .object(["include_usage": .bool(true)])
            upstream = .object(b)
        }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/event-stream")
        headers.replaceOrAdd(name: "X-Substation-Request-Id", value: route.requestId)
        headers.replaceOrAdd(name: "X-Substation-Tier", value: route.tier)
        headers.replaceOrAdd(name: .cacheControl, value: "no-cache")

        let client = orch.client
        let url = Self.remoteURL(t)
        let hdrs = Self.remoteHeaders(t)
        let proto = t.proto
        let virtual = route.virtualModel
        let recorder = Recorder()
        let routeCopy = route

        return Response(status: .ok, headers: headers, body: .init(asyncStream: { writer in
            let t0 = Date()
            var tokens = 0
            var usageCompletion = 0
            var usagePrompt = 0
            let stream = client.streamSSE(url: url, body: upstream, headers: hdrs)
            do {
                for try await payload in stream {
                    if payload == "[DONE]" {
                        try await writer.write(.buffer(ByteBuffer(string: "data: [DONE]\n\n")))
                        continue
                    }
                    var out: String?
                    if proto == "anthropic" {
                        out = Self.fromAnthropicChunk(payload, virtual: virtual)
                        if let o = out, let obj = JSONCoding.decode(Data(o.utf8))?.objectValue {
                            if let piece = obj["choices"]?[0]?["delta"]?["content"]?.stringValue, !piece.isEmpty {
                                recorder.append(piece)
                                tokens += 1
                            }
                            if let u = obj["usage"]?.objectValue {
                                usageCompletion = Int(u["completion_tokens"]?.doubleValue ?? 0)
                                usagePrompt = Int(u["prompt_tokens"]?.doubleValue ?? 0)
                            }
                        }
                    } else {
                        if payload.contains("\"usage\""),
                           let uObj = JSONCoding.decode(Data(payload.utf8))?.objectValue,
                           uObj["choices"]?.arrayValue?.isEmpty ?? false
                        {
                            usagePrompt = Int(uObj["usage"]?["prompt_tokens"]?.doubleValue ?? 0)
                            usageCompletion = Int(uObj["usage"]?["completion_tokens"]?.doubleValue ?? 0)
                            continue
                        }
                        var obj = JSONCoding.decode(Data(payload.utf8))?.objectValue
                        var deltaText = ""
                        if obj != nil, let piece = obj!["choices"]?[0]?["delta"]?["content"]?.stringValue {
                            deltaText = piece
                        }
                        obj?["model"] = .string(virtual)
                        obj?["substation"] = .object([
                            "request_id": .string(routeCopy.requestId), "tier": .string(routeCopy.tier),
                        ])
                        if obj != nil { out = JSONCoding.encodeString(.object(obj!)) }
                        if !deltaText.isEmpty {
                            recorder.append(deltaText)
                            tokens += 1
                        }
                    }
                    if let o = out {
                        try await writer.write(.buffer(ByteBuffer(string: "data: \(o)\n\n")))
                    }
                }
                let finish = JSONCoding.encodeString(.object([
                    "id": .string("chatcmpl-\(routeCopy.requestId)"),
                    "object": .string("chat.completion.chunk"),
                    "model": .string(virtual),
                    "choices": .array([.object(["index": .jInt(0), "delta": .object([:]), "finish_reason": .string("stop")])]),
                    "created": .jInt(Int(Date().timeIntervalSince1970)),
                    "usage": .object(["prompt_tokens": .jInt(usagePrompt), "completion_tokens": .jInt(usageCompletion)]),
                ]))
                try await writer.write(.buffer(ByteBuffer(string: "data: \(finish)\n\n")))
                try await writer.write(.buffer(ByteBuffer(string: "data: [DONE]\n\n")))
                try await writer.write(.end)
            } catch {
                try? await writer.write(.end)
            }

            let totalMs = Date().timeIntervalSince(t0) * 1000
            let completionTokens = usageCompletion > 0 ? Double(usageCompletion) : Double(tokens)
            let tokS = totalMs > 0 ? completionTokens / (totalMs / 1000) : 0
            await orch.usage.record(prompt: usagePrompt, completion: Int(completionTokens),
                                    tier: routeCopy.tier, model: routeCopy.model)
            await orch.metrics.increment("requests_total")
            await orch.metrics.record("total_ms", totalMs)
            await orch.metrics.record("ttft_ms", totalMs)
            await orch.metrics.record("tok_s", tokS)
            await orch.metrics.record("tok_s.\(routeCopy.model)", tokS)
            await orch.metrics.record("total_ms.\(routeCopy.model)", totalMs)
            await orch.metrics.recordTokens(completionTokens, ms: totalMs)
            try? await orch.events.publish("usage.recorded", [
                ("id", .string(routeCopy.requestId)),
                ("prompt", .jInt(usagePrompt)), ("completion", .jInt(Int(completionTokens))),
                ("tier", .string(routeCopy.tier)), ("model", .string(routeCopy.model)), ("cached", .bool(false)),
            ])
            try? await orch.events.publish("stream.done", [
                ("id", .string(routeCopy.requestId)), ("total_tokens", .jInt(Int(completionTokens))),
                ("ms", .jInt(Int(totalMs))), ("cached", .bool(false)),
            ])
        }))
    }
}
