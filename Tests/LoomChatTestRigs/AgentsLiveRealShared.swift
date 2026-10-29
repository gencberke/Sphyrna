import Darwin
import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

/// What both halves of `AgentsLiveRealTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum AgentsLiveRealShared {
    static func log(_ line: String) {
        let text = "[v23-real] \(line)"
        print(text)
        guard let folder = ProcessInfo.processInfo.environment["LOOM_V23_DIR"] else { return }
        let url = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("real-agents.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((text + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((text + "\n").utf8).write(to: url)
        }
    }

    static func capture(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// The runtime of one real test: the isolated profile, a run host, the hook helper, a catalog in a temporary folder.
    struct AgentsRig {
        let runtime: SessionRuntime
        let supervisor: ProcessSupervisor
        let root: URL
        let socketDirectory: URL

        static func make(config: URL, work: URL) async throws -> AgentsRig {
            let env = ProcessInfo.processInfo.environment
            let claude = env["LOOM_V23_CLAUDE"] ?? "/opt/homebrew/bin/claude"
            let child = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
                         "CLAUDE_CONFIG_DIR": config.path]
            var launchEnvironment = ["PATH": child["PATH"]!, "HOME": NSHomeDirectory(), "USER": NSUserName(),
                                     "LOGNAME": NSUserName(), "LANG": "en_US.UTF-8"]
            launchEnvironment["TMPDIR"] = env["TMPDIR"]
            let toolEnvironment = launchEnvironment
            let capabilities = ProviderCapabilities(
                version: try AgentsLiveRealShared.capture(claude, ["--version"], environment: child).trimmingCharacters(in: .whitespacesAndNewlines),
                help: try AgentsLiveRealShared.capture(claude, ["--help"], environment: child))

            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-v23-real-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let socketDirectory = URL(fileURLWithPath: "/tmp/lv-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let binaries = Bundle(for: AgentsRealAnchor.self).bundleURL.deletingLastPathComponent()
            let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
            let bundle = try RunScopeLauncher.assembleOwnedBundle(executable: binaries.appendingPathComponent("loom-run-host"), in: root)
            let supervisor = try await ProcessSupervisor.restoring(
                catalog: catalog,
                scopeLauncher: RunScopeLauncher(hostBundle: bundle, socketDirectory: socketDirectory.appendingPathComponent("rs")))
            let runtime = SessionRuntime(
                supervisor: supervisor, catalog: catalog,
                configuration: SessionRuntimeConfiguration(
                    toolchains: { provider in
                        ProviderToolchain(provider: provider, executable: claude, capabilities: capabilities,
                                          environment: toolEnvironment, profileDirectory: config, extraArguments: [])
                    },
                    hookHelperPath: binaries.appendingPathComponent("loom-hook").path,
                    socketDirectory: socketDirectory, homeDirectory: work.path, idlePolicy: SessionIdlePolicy(),
                    codexIdentityTimeout: 3, claudeProfileDirectory: config,
                    claudePluginDirectory: root.appendingPathComponent("claude-plugin", isDirectory: true),
                    hookSilenceGrace: 10, catalogBackupDelay: nil))
            try await runtime.start()
            return AgentsRig(runtime: runtime, supervisor: supervisor, root: root, socketDirectory: socketDirectory)
        }

        func cleanup() {
            RunScopeLauncher.removeOwnedBundle(in: root)
            try? FileManager.default.removeItem(at: socketDirectory)
            try? FileManager.default.removeItem(at: root)
        }
    }

    final class AgentsRealAnchor: NSObject {}
}
