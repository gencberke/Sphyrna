import Foundation

/// Invocation-local arguments for the foreground server and the full native TUI.
/// The server's capability is passed only in child environments.
public enum OpenCodeLaunchProfile {
    public static func server(environment: [String: String], password: String) throws -> ProviderLaunchProfile {
        guard validPassword(password) else { throw OpenCodeError.invalidCapability }
        var environment = environment
        environment.removeValue(forKey: "OPENCODE_SERVER_PASSWORD")
        environment["OPENCODE_PASSWORD"] = password
        return ProviderLaunchProfile(arguments: ["serve", "--hostname", "127.0.0.1", "--port", "0"],
                                     environment: environment)
    }

    static func terminal(serverURL: URL, sessionID: String, directory: String,
                                environment: [String: String], password: String) throws -> ProviderLaunchProfile {
        guard validPassword(password) else { throw OpenCodeError.invalidCapability }
        guard validServerURL(serverURL), validID(sessionID, prefix: "ses"), directory.hasPrefix("/"),
              !directory.contains("\0") else { throw OpenCodeError.invalidTarget }
        var environment = environment
        environment.removeValue(forKey: "OPENCODE_SERVER_PASSWORD")
        environment["OPENCODE_PASSWORD"] = password
        return ProviderLaunchProfile(arguments: ["--server", serverURL.absoluteString, "--session", sessionID, directory],
                                     environment: environment)
    }

    static func validPassword(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.contains("\n") && !value.contains("\r") && !value.contains("\0")
    }

    static func validID(_ value: String, prefix: String) -> Bool {
        value.hasPrefix(prefix) && value.utf8.count > prefix.utf8.count && value.utf8.count <= 128 &&
            value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    static func validServerURL(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "http",
              c.host == "127.0.0.1", let port = c.port, (1...65535).contains(port),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty else { return false }
        return true
    }
}

public enum OpenCodeError: Error, Equatable, Sendable {
    case invalidCapability, invalidTarget, unverifiedServer, invalidResponse, conflict, indeterminate, unavailable
    case timeout, closed, responseTooLarge, httpStatus(Int)
}
