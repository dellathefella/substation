import Foundation

/// Hand-rolled TOML subset: `[table]`, `[[array of tables]]`, `key = value`
/// where value is string / int / float / bool / inline array of scalars.
/// Comments (`#`) and blank lines are ignored. Sufficient for substation.toml.
public enum TOML {
    public static func parse(_ text: String) -> JSONValue {
        var root: [String: JSONValue] = [:]
        var path: [String] = []
        var arrayPath: [String]?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[[") && line.hasSuffix("]]") {
                let name = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                arrayPath = name.split(separator: ".").map(String.init)
                appendTableArray(into: &root, path: arrayPath!)
                path = []
                continue
            }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                path = name.split(separator: ".").map(String.init)
                arrayPath = nil
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let valueText = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard let value = parseValue(valueText) else { continue }

            if let arrayPath {
                setTableArrayElement(into: &root, path: arrayPath, key: key, value: value)
            } else if path.isEmpty {
                root[key] = value
            } else {
                var section = table(in: .object(root), path: path)?.objectValue ?? [:]
                section[key] = value
                setTable(into: &root, path: path, value: .object(section))
            }
        }
        return .object(root)
    }

    /// Assigns `key = value` into the LAST element of the [[array]] at `path`.
    private static func setTableArrayElement(
        into root: inout [String: JSONValue], path: [String], key: String, value: JSONValue
    ) {
        if path.count == 1 {
            var elems = root[path[0]]?.arrayValue ?? []
            if elems.isEmpty { elems.append(.object([:])) }
            var last = elems[elems.count - 1].objectValue ?? [:]
            last[key] = value
            elems[elems.count - 1] = .object(last)
            root[path[0]] = .array(elems)
            return
        }
        var child = root[path[0]]?.objectValue ?? [:]
        setTableArrayElement(into: &child, path: Array(path.dropFirst()), key: key, value: value)
        root[path[0]] = .object(child)
    }

    private static func table(in root: JSONValue, path: [String]) -> JSONValue? {
        var cur = root
        for p in path {
            guard let next = cur[p] else { return nil }
            cur = next
        }
        return cur
    }

    private static func setTable(into root: inout [String: JSONValue], path: [String], value: JSONValue) {
        if path.count == 1 {
            root[path[0]] = value
            return
        }
        var child = root[path[0]]?.objectValue ?? [:]
        setTable(into: &child, path: Array(path.dropFirst()), value: value)
        root[path[0]] = .object(child)
    }

    private static func appendTableArray(into root: inout [String: JSONValue], path: [String]) {
        let head = path[0]
        if path.count == 1 {
            var elems = root[head]?.arrayValue ?? []
            elems.append(.object([:]))
            root[head] = .array(elems)
            return
        }
        var child = root[head]?.objectValue ?? [:]
        appendTableArray(into: &child, path: Array(path.dropFirst()))
        root[head] = .object(child)
    }

    /// Strip a `#` comment that is not inside quotes.
    private static func stripComment(_ line: String) -> String {
        var inQuote = false
        var quote: Character = "\""
        var out = ""
        for ch in line {
            if inQuote {
                out.append(ch)
                if ch == quote { inQuote = false }
            } else if ch == "\"" || ch == "'" {
                inQuote = true
                quote = ch
                out.append(ch)
            } else if ch == "#" {
                break
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func parseValue(_ text: String) -> JSONValue? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
            return .string(unescape(String(t.dropFirst().dropLast())))
        }
        if t.hasPrefix("'") && t.hasSuffix("'") && t.count >= 2 {
            return .string(String(t.dropFirst().dropLast()))
        }
        if t == "true" { return .bool(true) }
        if t == "false" { return .bool(false) }
        if t.hasPrefix("[") && t.hasSuffix("]") {
            let inner = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .array([]) }
            return .array(splitArray(inner).compactMap(parseValue))
        }
        if let i = Int(t) { return .jInt(i) }
        if let d = Double(t) { return .jDouble(d) }
        return nil
    }

    /// Split on commas that are not inside quotes.
    private static func splitArray(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuote = false
        var quote: Character = "\""
        for ch in text {
            if inQuote {
                cur.append(ch)
                if ch == quote { inQuote = false }
            } else if ch == "\"" || ch == "'" {
                inQuote = true
                quote = ch
                cur.append(ch)
            } else if ch == "," {
                out.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        let last = cur.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { out.append(last) }
        return out
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    // MARK: - Writer

    public static func write(_ value: JSONValue) -> String {
        guard let root = value.objectValue else { return "" }
        var out = ""
        var tables: [(String, JSONValue)] = []
        var arrays: [(String, JSONValue)] = []

        for (k, v) in root.sorted(by: { $0.key < $1.key }) {
            switch v {
            case .object: tables.append((k, v))
            case .array(let elems) where elems.first?.objectValue != nil && !elems.isEmpty:
                arrays.append((k, v))
            default:
                out += "\(escapeKey(k)) = \(inline(v))\n"
            }
        }

        func renderTable(_ prefix: String, _ obj: [String: JSONValue]) {
            out += "\n[\(prefix)]\n"
            var nested: [(String, JSONValue)] = []
            var nestedArrays: [(String, JSONValue)] = []
            for (k, v) in obj.sorted(by: { $0.key < $1.key }) {
                switch v {
                case .object: nested.append((k, v))
                case .array(let elems) where elems.first?.objectValue != nil && !elems.isEmpty:
                    nestedArrays.append((k, v))
                default:
                    out += "\(escapeKey(k)) = \(inline(v))\n"
                }
            }
            for (k, v) in nested { renderTable("\(prefix).\(k)", v.objectValue ?? [:]) }
            for (k, v) in nestedArrays { renderTableArray("\(prefix).\(k)", v.arrayValue ?? []) }
        }

        func renderTableArray(_ prefix: String, _ elems: [JSONValue]) {
            for elem in elems {
                out += "\n[[\(prefix)]]\n"
                if let obj = elem.objectValue {
                    for (k, v) in obj.sorted(by: { $0.key < $1.key }) {
                        out += "\(escapeKey(k)) = \(inline(v))\n"
                    }
                }
            }
        }

        for (k, v) in tables { renderTable(k, v.objectValue ?? [:]) }
        for (k, v) in arrays { renderTableArray(k, v.arrayValue ?? []) }
        return out
    }

    private static func escapeKey(_ k: String) -> String {
        k.contains(".") || k.contains(" ") ? "\"\(k)\"" : k
    }

    private static func inline(_ value: JSONValue) -> String {
        switch value {
        case .string(let s):
            let esc = s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(esc)\""
        case .bool(let b): return b ? "true" : "false"
        case .number(let d):
            if d == d.rounded(), abs(d) < 1e15 { return String(format: "%.1f", d) }
            return String(d)
        case .array(let elems): return "[\(elems.map(inline).joined(separator: ", "))]"
        case .object(let o):
            let parts = o.sorted { $0.key < $1.key }.map { "\(escapeKey($0.key)) = \(inline($0.value))" }
            return "{ \(parts.joined(separator: ", ")) }"
        case .null: return "\"\""
        }
    }
}
