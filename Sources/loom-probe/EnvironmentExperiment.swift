import Darwin
import Foundation
import LoomCore

extension Probe {
    /// Treat only our LaunchServices bundle with its own launcher identity as a clean parent.
    static var launchOrigin: LaunchEnvironment.LaunchOrigin {
        LaunchEnvironment.origin(parent: ProcessInfo.processInfo.environment,
                                 bundleIdentifier: Bundle.main.bundleIdentifier, parentPID: getppid())
    }

    @MainActor private static var showedEnvironmentWarnings = false

    @MainActor static func resolveTerminalEnvironment(coordinator: ShutdownCoordinator) throws -> LaunchEnvironment.Resolution {
        let result = try coordinator.terminalEnvironment(origin: launchOrigin)
        if !showedEnvironmentWarnings {
            for warning in result.warnings { fputs("loom-probe environment warning: \(warning)\n", stderr) }
            showedEnvironmentWarnings = true
        }
        return result
    }

    /// Private, temporary environment capture for a Terminal.app comparison. Never prints values.
    @MainActor static func environmentExperiment(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let coordinator = try ShutdownCoordinator()
        defer { _ = coordinator.shutdown() }
        let resolution = try resolveTerminalEnvironment(coordinator: coordinator)
        let base = resolution.environment
        let environment = LaunchEnvironment.make(base: base, runID: UUID(), sessionID: UUID())
        let childOutput = try capture("/usr/bin/env", ["-0"], environment: environment)
        var observed: [String: String] = [:]
        for entry in childOutput.split(separator: "\0") {
            guard let equal = entry.firstIndex(of: "=") else { throw LoomError.message("Invalid child environment") }
            observed[String(entry[..<equal])] = String(entry[entry.index(after: equal)...])
        }
        let url = directory.appendingPathComponent("loom-environment.json")
        try encoder.encode(observed).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // ssh-add status 1 means a reachable agent with no identities; 2 means no agent connection.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        child.arguments = ["-l"]
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run(); child.waitUntilExit()
        let report: [String: Any] = ["sshAddStatus": Int(child.terminationStatus),
                                      "agentReachable": [0, 1].contains(child.terminationStatus),
                                      "cachedEnvironmentIdentical": try coordinator.terminalEnvironment(origin: launchOrigin) == resolution,
                                      "launchOrigin": launchOrigin == .launchServices ? "launchServices" : "development",
                                      "warningCount": resolution.warnings.count,
                                      "childHasSSHAgentSocket": observed["SSH_AUTH_SOCK"] != nil,
                                      "childLauncherKeys": observed.keys.filter { $0.hasPrefix("XPC_") || ["__CFBundleIdentifier", "__CF_USER_TEXT_ENCODING", "COMMAND_MODE", "OSLogRateLimit"].contains($0) }.sorted()]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("environment-checks.json"))
        print("Environment captured privately in \(directory.path)")
    }
}
