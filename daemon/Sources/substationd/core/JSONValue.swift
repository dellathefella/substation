import Foundation
import CryptoKit

public enum JSONValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null
}

extension JSONValue {
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .number(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        if case .number(let d) = self { return d }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        if let o = objectValue { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if let a = arrayValue, a.indices.contains(index) { return a[index] }
        return nil
    }

    public static func jInt(_ i: Int) -> JSONValue { .number(Double(i)) }
    public static func jDouble(_ d: Double) -> JSONValue { .number(d) }
}

/// Natural JSON encoding (not the synthesized externally-tagged enum form).
extension JSONValue {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self) {
            self = .number(Double(i))
        } else if let d = try? container.decode(Double.self) {
            self = .number(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let d):
            if d == d.rounded(), abs(d) < 1e15 { try container.encode(Int64(d)) } else { try container.encode(d) }
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null: try container.encodeNil()
        }
    }
}

public enum JSONCoding {
    public static func encode(_ value: JSONValue, pretty: Bool = false) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    public static func encodeString(_ value: JSONValue, pretty: Bool = false) -> String {
        String(decoding: encode(value, pretty: pretty), as: UTF8.self)
    }

    public static func decode(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func fromAny(_ any: Any) -> JSONValue? {
        switch any {
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let i as Int: return .jInt(i)
        case let d as Double: return .jDouble(d)
        case is NSNull: return .null
        case let arr as [Any]:
            return .array(arr.compactMap { fromAny($0) })
        case let dict as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, v) in dict { out[k] = fromAny(v) }
            return .object(out)
        default:
            return nil
        }
    }
}

/// Recursive merge of `patch` into `base` (object keys merged, leaves replaced).
public func deepMerge(_ base: JSONValue, _ patch: JSONValue) -> JSONValue {
    guard case .object(var b) = base, case .object(let p) = patch else { return patch }
    for (k, v) in p {
        if let existing = b[k] {
            b[k] = deepMerge(existing, v)
        } else {
            b[k] = v
        }
    }
    return .object(b)
}

public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public func sha256Hex(_ string: String) -> String {
    sha256Hex(Data(string.utf8))
}

/// Deterministic key material for the response cache: object keys sorted.
public func canonicalJSON(_ value: JSONValue) -> String {
    JSONCoding.encodeString(value)
}
