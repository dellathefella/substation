import Foundation

// MARK: - Settings / base URL resolution

enum Settings {
    static let baseURLKey = "substation.baseURL"
    static let tokenKey = "substation.token"
    static let defaultBaseURL = "http://127.0.0.1:8800"

    /// UserDefaults override wins over SUBSTATION_URL, which wins over the default.
    static func resolvedBaseURL() -> String {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: baseURLKey), !stored.isEmpty {
            return normalized(stored)
        }
        if let env = ProcessInfo.processInfo.environment["SUBSTATION_URL"], !env.isEmpty {
            return normalized(env)
        }
        return defaultBaseURL
    }

    static func storedBaseURLOverride() -> String {
        UserDefaults.standard.string(forKey: baseURLKey) ?? ""
    }

    static func setBaseURLOverride(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: baseURLKey)
        } else {
            UserDefaults.standard.set(normalized(trimmed), forKey: baseURLKey)
        }
    }

    static func authToken() -> String? {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: tokenKey), !stored.isEmpty {
            return stored
        }
        return ProcessInfo.processInfo.environment["SUBSTATION_TOKEN"]
    }

    private static func normalized(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }
}
