import Foundation
import Vapor

extension Routes {
    /// Chat API (§5): daemon-persisted conversations; engine layer stays stateless.
    static func registerChat(_ app: Application, _ kit: Kit) {
        app.get("api", "chat", "sessions") { req async throws -> Response in
            try await auth(req, kit)
            return jsonResponse(await kit.chat.list())
        }

        app.on(.POST, "api", "chat", "sessions", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            let body = try? await Routes.jsonBody(req)
            let title = body?["title"]?.stringValue
            return jsonResponse(await kit.chat.create(title: title))
        }

        app.get("api", "chat", "sessions", ":id", "messages") { req async throws -> Response in
            try await auth(req, kit)
            let id = req.parameters.get("id") ?? ""
            guard let msgs = await kit.chat.messages(id) else { throw APIError.notFound("session \(id)") }
            return jsonResponse(msgs)
        }

        app.on(.POST, "api", "chat", "sessions", ":id", "send", body: .collect(maxSize: "64mb")) { req async throws -> Response in
            try await auth(req, kit)
            let id = req.parameters.get("id") ?? ""
            let body = try await Routes.jsonBody(req)
            let content = body["content"]?.stringValue ?? ""
            let pin = body["pin"]?.stringValue ?? "auto"
            guard !content.isEmpty else { throw APIError.badRequest("content required") }

            // Replay history + new user turn to the engine (stateless at engine layer).
            var history: [JSONValue] = []
            if let existing = await kit.chat.messages(id), let arr = existing.arrayValue {
                for m in arr {
                    if let role = m["role"]?.stringValue, let c = m["content"]?.stringValue {
                        history.append(.object(["role": .string(role), "content": .string(c)]))
                    }
                }
            }
            history.append(.object(["role": .string("user"), "content": .string(content)]))
            await kit.chat.pinModel(id, pin)
            _ = await kit.chat.append(id, ChatMessage(role: "user", content: content))

            let outBody: JSONValue = .object([
                "model": .string(pin),
                "messages": .array(history),
                "stream": .bool(true),
            ])
            return try await kit.pipeline.stream(body: outBody, sessionKey: id, chat: kit.chat, chatID: id)
        }

        app.delete("api", "chat", "sessions", ":id") { req async throws -> Response in
            try await auth(req, kit)
            let id = req.parameters.get("id") ?? ""
            let ok = await kit.chat.delete(id)
            return jsonResponse(.object(["deleted": .bool(ok)]), status: ok ? .ok : .notFound)
        }

        app.delete("api", "chat", "sessions", ":id", "messages", ":index") { req async throws -> Response in
            try await auth(req, kit)
            let id = req.parameters.get("id") ?? ""
            let idx = Int(req.parameters.get("index") ?? "") ?? -1
            let ok = await kit.chat.deleteMessage(id, idx)
            return jsonResponse(.object(["deleted": .bool(ok)]), status: ok ? .ok : .notFound)
        }
    }
}
