import Darwin
import Foundation
import LoomCore

@main
struct Probe {
    @MainActor static func main() {
        do { try run() } catch { fputs("loom-probe: \(error)\n", stderr); exit(1) }
    }

    @MainActor static func run() throws {
        let root = ProcessInfo.processInfo.environment["LOOM_PROBE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Loom-Dev/probe")
        // Probe exclusivity before recovery or shell resolution launches any children.
        _ = CoalitionCapability.current
        let args = Array(CommandLine.arguments.dropFirst())
        if ["prepare", "capabilities", "synthetic", "crash-fixture", "recover-stale", "experiment"].contains(args.first ?? "") {
            try recoverStaleRuns(root: root)
        }
        if args.first == "recover-stale" { return }
        if args.first == "environment", args.count == 2 {
            try environmentExperiment(directory: URL(fileURLWithPath: args[1]))
            return
        }
        if args.first == "experiment", args.count == 2 {
            let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
            guard let script = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LoomError.message("Invalid experiment script") }
            let experiment = try ProviderExperiment(root: root, label: script["label"] as? String ?? "provider")
            try experiment.run(script: script)
            return
        }
        if args.first == "prepare" {
            for name in ["claude-config", "workspace", "runs"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            let codexHome = root.appendingPathComponent("codex-home")
            if !FileManager.default.fileExists(atPath: codexHome.path) {
                let shortHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".loom-dev/codex-home")
                try FileManager.default.createDirectory(at: shortHome, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.createSymbolicLink(at: codexHome, withDestinationURL: shortHome)
            }
            let workspace = root.appendingPathComponent("workspace")
            if !FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".git").path) {
                let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                git.arguments = ["init", "--quiet", workspace.path]; try git.run(); git.waitUntilExit()
                guard git.terminationStatus == 0 else { throw LoomError.message("Could not initialize probe workspace") }
            }
            print("Prepared isolated probe directories at \(root.path)")
            return
        }
        if args.first == "capabilities" {
            let directory = root.appendingPathComponent("runs/capabilities-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let coordinator = try ShutdownCoordinator()
            defer { _ = coordinator.shutdown() }
            let terminalEnvironment = try resolveTerminalEnvironment(coordinator: coordinator).environment
            var environment = LaunchEnvironment.make(base: terminalEnvironment, runID: UUID(), sessionID: UUID())
            environment["CODEX_HOME"] = root.appendingPathComponent("codex-home").path
            environment["CLAUDE_CONFIG_DIR"] = root.appendingPathComponent("claude-config").path
            for provider in ["codex", "claude"] {
                let version = try capture(provider, ["--version"], environment: environment)
                let help = try capture(provider, ["--help"], environment: environment)
                let server = provider == "codex" ? try capture(provider, ["app-server", "--help"], environment: environment) : ""
                let features = provider == "codex" ? try capture(provider, ["features", "list"], environment: environment) : ""
                let capabilities = ProviderCapabilities(version: version, help: help, serverHelp: server, features: features)
                try encoder.encode(capabilities).write(to: directory.appendingPathComponent("\(provider).json"))
                try (version + help + server + features).write(to: directory.appendingPathComponent("\(provider)-evidence.txt"), atomically: true, encoding: .utf8)
                print(String(decoding: try encoder.encode(capabilities), as: UTF8.self))
            }
            print(directory.path)
            return
        }
        if args.first == "recover", args.count == 2 {
            let url = URL(fileURLWithPath: args[1])
            let coordinator = try ShutdownCoordinator(ledger: OwnershipLedger.load(from: url), ledgerURL: url)
            let report = coordinator.shutdown()
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            if !report.succeeded { exit(1) }
            return
        }
        guard args.first == "synthetic" || args.first == "crash-fixture" else {
            print("Usage: loom-probe prepare | capabilities | experiment <script.json> | recover-stale | synthetic [inspect|stubborn|group|escape|apple-escape] | recover <ledger.json>")
            return
        }
        let mode = args.count > 1 ? args[1] : "inspect"
        guard ["inspect", "stubborn", "group", "escape", "apple-escape"].contains(mode) else {
            throw LoomError.message("Unknown synthetic mode")
        }
        let ledger = OwnershipLedger()
        let directory = root.appendingPathComponent("runs/\(ledger.runID.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let ledgerURL = directory.appendingPathComponent("ledger.json")
        let coordinator = try ShutdownCoordinator(ledger: ledger, ledgerURL: ledgerURL)
        guard let owner = try ProcessTable.snapshot().first(where: { $0.identity.pid == getpid() }) else {
            throw LoomError.message("Cannot record probe owner identity")
        }
        try encoder.encode(owner.identity).write(to: directory.appendingPathComponent("owner.json"), options: .atomic)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent("loom-test-child").path
        defer { if !coordinator.isStopping { _ = coordinator.shutdown() } }
        let environment = LaunchEnvironment.make(base: try resolveTerminalEnvironment(coordinator: coordinator).environment, runID: ledger.runID, sessionID: UUID())
        do {
            let child = try coordinator.launch(executable: executable, arguments: [mode], environment: environment,
                                               directory: directory.path)
            var output = Data()
            let deadline = Date().addingTimeInterval(0.5)
            repeat {
                output.append(try child.readAvailable())
                if args.first != "crash-fixture" && mode != "apple-escape" { try coordinator.sample() }
                usleep(10_000)
            } while Date() < deadline
            // The final ownership scan can consume the sampling window after the child writes.
            output.append(try child.readAvailable())
            try output.write(to: directory.appendingPathComponent("terminal.txt"))
            if args.first == "crash-fixture" {
                // This internal mode deliberately dies; the next invocation must recover its marked descendants.
                print(ledgerURL.path); fflush(stdout)
                kill(getpid(), SIGKILL)
            }
            // Fixture PID is an independent oracle, never input to the ownership ledger.
            guard let line = String(decoding: output, as: UTF8.self).split(separator: "\n").first,
                  let fixture = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                throw LoomError.message("Fixture did not report readiness; scenario is unverified")
            }
            let oraclePID = fixture["descendantPID"] as? Int32
            let oracle = try ProcessTable.snapshot().first { $0.identity.pid == oraclePID }
            if ["group", "escape", "apple-escape"].contains(mode), oracle == nil {
                throw LoomError.message("Fixture descendant was not observed; scenario is unverified")
            }
            let found = try coordinator.sample()
            try encoder.encode(found).write(to: directory.appendingPathComponent("before-shutdown.json"))
            let report = coordinator.shutdown()
            let oracleRemaining = try ProcessTable.snapshot().filter { $0.identity == oracle?.identity && !$0.zombie }
            let passed = report.succeeded && oracleRemaining.isEmpty
            try encoder.encode(report).write(to: directory.appendingPathComponent("shutdown.json"), options: .atomic)
            try encoder.encode(oracleRemaining).write(to: directory.appendingPathComponent("oracle-remaining.json"), options: .atomic)
            let summary = "\(passed ? "PASS" : "FAIL") \(mode): \(report.remaining.count) owned-set remaining, \(oracleRemaining.count) oracle remaining, \(report.elapsedSeconds)s; \(directory.path)"
            try summary.write(to: directory.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
            // Only the synthetic oracle authorizes cleanup of the fixture the ledger failed to see.
            for record in oracleRemaining { try ProcessTable.signal(record.identity, SIGKILL) }
            print(String(decoding: output, as: UTF8.self)); print(summary)
            if !passed { exit(1) }
            try Data().write(to: directory.appendingPathComponent("completed"))
        } catch {
            let report = coordinator.shutdown()
            try? encoder.encode(report).write(to: directory.appendingPathComponent("shutdown.json"))
            throw error
        }
    }

    @MainActor static func recoverStaleRuns(root: URL) throws {
        let runs = root.appendingPathComponent("runs")
        guard FileManager.default.fileExists(atPath: runs.path) else { return }
        let snapshot = try ProcessTable.snapshot()
        let identities = Set(snapshot.map(\.identity))
        for directory in try FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil) {
            let ownerURL = directory.appendingPathComponent("owner.json")
            guard FileManager.default.fileExists(atPath: ownerURL.path),
                  !FileManager.default.fileExists(atPath: directory.appendingPathComponent("completed").path),
                  !FileManager.default.fileExists(atPath: directory.appendingPathComponent("recovered").path) else { continue }
            do {
            let owner = try JSONDecoder().decode(ProcessIdentity.self, from: Data(contentsOf: ownerURL))
            if identities.contains(owner) { continue } // A concurrent, live probe owns this run.
            let ledgerURL = directory.appendingPathComponent("ledger.json")
            let coordinator = try ShutdownCoordinator(ledger: OwnershipLedger.load(from: ledgerURL), ledgerURL: ledgerURL)
            let before = try coordinator.sample()
            try encoder.encode(before).write(to: directory.appendingPathComponent("recovery-before.json"), options: .atomic)
            let report = coordinator.shutdown()
            try encoder.encode(report).write(to: directory.appendingPathComponent("recovery.json"), options: .atomic)
            guard report.succeeded else { throw LoomError.message("Recovery incomplete: \(directory.path)") }
            try Data().write(to: directory.appendingPathComponent("recovered"))
            } catch {
                let message = "Recovery incomplete: \(directory.path): \(error)"
                try? message.write(to: directory.appendingPathComponent("recovery-error.txt"), atomically: true, encoding: .utf8)
                fputs(message + "\n", stderr)
            }
        }
    }

    static func capture(_ program: String, _ arguments: [String], environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [program] + arguments
        process.environment = environment
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LoomError.message("Capability check failed: \(program) \(arguments)") }
        return String(decoding: data, as: UTF8.self)
    }

    static var encoder: JSONEncoder { let value = JSONEncoder(); value.outputFormatting = [.prettyPrinted, .sortedKeys]; return value }
}
