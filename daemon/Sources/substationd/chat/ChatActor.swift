import Foundation

public struct ChatMessage: Codable, Sendable {
    public var role: String
    public var content: String
    public var ts: Double
    public var tier: String?
    public var model: String?
    public var node: String?
    public var tok_s: Double?

    public init(role: String, content: String, ts: Double = Date().timeIntervalSince1970 * 1000,
                tier: String? = nil, model: String? = nil, node: String? = nil, tok_s: Double? = nil)
    {
        self.role = role; self.content = content; self.ts = ts
        self.tier = tier; self.model = model; self.node = node; self.tok_s = tok_s
    }
}

public struct ChatSession: Codable, Sendable {
    public var id: String
    public var title: String
    public var updated_at: Double
    public var model_hint: String
    public var messages: [ChatMessage]
}

/// Conversations as JSON files under <data>/conversations/ (atomic writes).
public actor ChatActor {
    private let dir: String
    private let fallbackDir = NSTemporaryDirectory() + "substation-conversations"

    public init(dataDir: String) {
        dir = dataDir + "/conversations"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    private func url(_ id: String) -> String {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return dir + "/" + safe + ".json"
    }

    private func load(_ id: String) -> ChatSession? {
        guard let data = FileManager.default.contents(atPath: url(id)) else { return nil }
        return try? JSONDecoder().decode(ChatSession.self, from: data)
    }

    private func store(_ s: ChatSession) throws {
        var s = s
        s.updated_at = Date().timeIntervalSince1970 * 1000
        let data = try JSONEncoder.substation.encode(s)
        let target = url(s.id)
        let tmp = target + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmp))
        _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: target), withItemAt: URL(fileURLWithPath: tmp))
        if FileManager.default.fileExists(atPath: tmp) {
            try? FileManager.default.removeItem(atPath: target)
            try FileManager.default.moveItem(at: URL(fileURLWithPath: tmp), to: URL(fileURLWithPath: target))
        }
    }

    public func list() -> JSONValue {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var out: [JSONValue] = []
        for f in files where f.hasSuffix(".json") {
            guard let s = load(String(f.dropLast(5))) else { continue }
            out.append(.object([
                "id": .string(s.id),
                "title": .string(s.title),
                "updated_at": .jDouble(s.updated_at),
                "model_hint": .string(s.model_hint),
                "messages": .jInt(s.messages.count),
            ]))
        }
        return .array(out.sorted { $0["updated_at"]?.doubleValue ?? 0 > $1["updated_at"]?.doubleValue ?? 0 })
    }

    public func create(title: String?) -> JSONValue {
        let id = "chat-" + String(UUID().uuidString.prefix(8)).lowercased()
        let s = ChatSession(id: id, title: title ?? "New chat", updated_at: Date().timeIntervalSince1970 * 1000, model_hint: "auto", messages: [])
        try? store(s)
        return .object(["id": .string(id)])
    }

    public func messages(_ id: String) -> JSONValue? {
        guard let s = load(id) else { return nil }
        let arr = s.messages.map { m in
            JSONValue.object([
                "role": .string(m.role),
                "content": .string(m.content),
                "ts": .jDouble(m.ts),
                "tier": m.tier.map { JSONValue.string($0) } ?? .null,
                "model": m.model.map { JSONValue.string($0) } ?? .null,
                "node": m.node.map { JSONValue.string($0) } ?? .null,
                "tok_s": m.tok_s.map { JSONValue.jDouble($0) } ?? .null,
            ])
        }
        return .array(arr)
    }

    public func append(_ id: String, _ msg: ChatMessage) -> Bool {
        guard var s = load(id) else { return false }
        s.messages.append(msg)
        if s.title == "New chat", msg.role == "user" {
            s.title = String(msg.content.prefix(48))
        }
        try? store(s)
        return true
    }

    public func pinModel(_ id: String, _ hint: String) {
        guard var s = load(id) else { return }
        s.model_hint = hint
        try? store(s)
    }

    public func delete(_ id: String) -> Bool {
        let ok = FileManager.default.fileExists(atPath: url(id))
        try? FileManager.default.removeItem(atPath: url(id))
        return ok
    }

    public func deleteMessage(_ id: String, _ index: Int) -> Bool {
        guard var s = load(id), s.messages.indices.contains(index) else { return false }
        s.messages.remove(at: index)
        try? store(s)
        return true
    }
}

extension JSONEncoder {
    static var substation: JSONEncoder { JSONEncoder() }
}
