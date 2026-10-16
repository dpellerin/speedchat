import Foundation
import Darwin

public enum RuntimeDiscovery {
    public enum DiscoveryError: Error, LocalizedError {
        case missing(String)
        public var errorDescription: String? {
            if case .missing(let name) = self {
                return "\(name) executable was not found. Make sure the Codex CLI is installed."
            }
            return nil
        }
    }

    public static func environment(_ source: [String: String] = ProcessInfo.processInfo.environment, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String: String] {
        var result = [String: String]()
        for name in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME", "SPEEDCHAT_STATE_DIR", "SPEEDCHAT_CODEX"] {
            if let val = source[name], !val.isEmpty {
                result[name] = val
            }
        }
        result["HOME"] = home
        let extraPaths = [
            source["PATH"] ?? "",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home + "/.local/bin",
            home + "/.volta/bin",
            home + "/.asdf/shims",
            home + "/.local/share/mise/shims",
            home + "/.fnm/current/bin",
            home + "/Library/pnpm",
            "/usr/bin",
            "/bin",
        ].filter { !$0.isEmpty }
        result["PATH"] = extraPaths.joined(separator: ":")
        return result
    }

    public static func isExecutableFile(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    public static func find(
        name: String,
        override: String = "",
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        hermesEntries: [String] = [],
        exists: (String) -> Bool = isExecutableFile
    ) throws -> String {
        let specified = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !specified.isEmpty {
            guard specified.hasPrefix("/"), exists(specified) else {
                throw DiscoveryError.missing(name)
            }
            return specified
        }
        var candidates = (environment(["PATH": path], home: home)["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/" + name }
        if name == "node" {
            candidates += hermesEntries
                .filter { $0.hasPrefix("node-") && $0.contains("-darwin-") }
                .sorted()
                .reversed()
                .map { home + "/.hermes/tools/" + $0 + "/bin/node" }
        }
        if let found = candidates.first(where: exists) {
            return found
        }
        throw DiscoveryError.missing(name)
    }

    public static func createRuntimeDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("speedchat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }
}
