#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI
import LoomCore
import LoomLaunchOptions
import LoomTerminal

/// Acceptance tooling, active only when the app is opened with
/// `--evidence <dir>`. It drives the same actions as the user (close button
/// and Quit menu) and writes state snapshots; it adds no behavior of its own.
/// Commands arrive as distributed notifications named
/// `local.loom.desktop.dev.command.<16 hex of SHA-256(realpath(dir))>` (one
/// channel per evidence instance; scripts: `loom_send_command`) whose object is `snapshot:<label>`,
/// `close-window`, `new-terminal`, `latency:<samples>`,
/// `quit-alert-try-again` or `quit`. Catalog commands drive the same model
/// calls as the sidebar controls (the folder panel excepted): `select:<id|none>`,
/// `search:<text>`, `view-mode:<activity|projects>`, `add-project:<path>`,
/// `remove-project:<id>`, `move-project:<id>:<delta>`, `toggle-project:<id>`,
/// `rename:<id>:<title>`, `begin-rename:<id>` / `rename-text:<text>` /
/// `rename-commit` (the dialog's own path), `open-add-project-panel`, `panel-choose:<path>`, `close-panel`, `terminal-title:<id>:<title>`, `toggle-sidebar`,
/// `sidebar-width:<pt>`, `resize:<w>x<h>`, `screenshot:<label>`. Conversation commands (CP5 C) drive the model intents the buttons use: `start:<claude|codex>:<project id|none>`, `resume:<id>`, `stop:<id>`, `answer:<id>:<accept|deny>`, and `type:<id>:<text>` (through the terminal delegate, not a native key event).
@MainActor
final class DevelopmentEvidence {
    let directory: URL
    weak var app: AppDelegate?
    private var observer: NSObjectProtocol?
    private var resourcePool: EvidenceResourcePool?
    private var resourceOperation: String?
    private var resourceOperationIDs: Set<String> = []
    private var pendingResourceQuit: String?

    init(directory: URL, app: AppDelegate) {
        self.directory = directory
        self.app = app
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(LaunchOptions.commandChannel(evidenceDirectory: directory.path, identity: app.identity)), object: nil, queue: .main
        ) { [weak self] notification in
            let command = notification.object as? String ?? ""
            // Not inside this OperationQueue block: a `quit` that waits for the
            // runtime start-up would run a nested loop here and starve the main
            // actor jobs it waits for. A run-loop source returns this block at once.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { self?.handle(command) }
            }
        }
        TerminalPresentationLog.install()
        write("launched", app.evidenceState)
    }

    private func handle(_ command: String) {
        guard let app else { return }
        if command.hasPrefix("resource:") {
            handleResourceCommand(String(command.dropFirst("resource:".count)))
        } else if command.hasPrefix("snapshot:") {
            let label = String(command.dropFirst("snapshot:".count))
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            Task {
                var state = app.evidenceState
                state["runtime"] = await app.runtimeEvidence()
                write("state-\(label)", state)
            }
        } else if command == "close-window" {
            app.closeWindowForEvidence()
        } else if command == "quit-alert-try-again" {
            app.pressQuitAlertButton(0)
        } else if command == "new-terminal" {
            app.newTerminalForEvidence()
        } else if command.hasPrefix("latency:"), let samples = Int(command.dropFirst("latency:".count)) {
            Task { await measureInputToDisplay(samples: min(500, max(1, samples)), surface: app.surfaceForEvidence) }
        } else if command == "quit" {
            NSApp.terminate(nil)
        } else {
            let separator = command.firstIndex(of: ":")
            let name = separator.map { String(command[..<$0]) } ?? command
            let argument = separator.map { String(command[command.index(after: $0)...]) } ?? ""
            Task { await handleCatalogCommand(name, argument) }
        }
    }

    /// New asynchronous measurement operations always have a unique ID. A
    /// concurrent mutation or duplicate ID is an explicit failed ack, never an
    /// overwritten snapshot that could look like a completed command.
    private func handleResourceCommand(_ text: String) {
        let addressed = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard addressed.count >= 3, let targetPID = Int32(addressed[0]), targetPID == getpid() else { return }
        let fields = Array(addressed.dropFirst())
        guard let uuid = UUID(uuidString: fields[0]) else { return }
        let operationID = uuid.uuidString.lowercased()
        guard !resourceOperationIDs.contains(operationID),
              resourceOperationIDs.count < 4_096 || (fields[1] == "quit" && pendingResourceQuit == nil) else {
            write("rejected-\(operationID)", ["operationID": operationID, "succeeded": false,
                "error": "Resource operation ID was reused or operation capacity was exceeded"])
            return
        }
        resourceOperationIDs.insert(operationID)
        if fields[1] == "quit", pendingResourceQuit == nil {
            // Quit can stop a timed-out operation. The shared supervisor closes
            // launch admission; it still verifies every owned run before exit.
            pendingResourceQuit = operationID
            NSApp.terminate(nil)
            return
        }
        guard resourceOperation == nil, pendingResourceQuit == nil else {
            write("ack-\(operationID)", ["operationID": operationID, "succeeded": false,
                "error": "Another resource operation is still running"])
            return
        }
        resourceOperation = operationID
        Task {
            let started = ProcessInfo.processInfo.systemUptime
            defer { resourceOperation = nil }
            do {
                guard let app, let supervisor = app.resourceSupervisorForEvidence,
                      let executable = app.resourceFixtureForEvidence else {
                    throw LoomError.message("Resource supervisor is not ready")
                }
                if resourcePool == nil {
                    resourcePool = EvidenceResourcePool(app: app, supervisor: supervisor,
                        executable: executable, directory: app.resourceDirectoryForEvidence)
                }
                guard let pool = resourcePool else { throw LoomError.message("Resource pool unavailable") }
                let result: [String: Any]
                switch fields[1] {
                case "open":
                    guard fields.count == 5, let count = Int(fields[2]), let rate = Int(fields[3]), let total = Int(fields[4]) else {
                        throw LoomError.message("open requires count:rate:total")
                    }
                    result = try await pool.open(count: count, rate: rate, total: total)
                case "openspinner":
                    // openspinner:count:fps:frames:payloadBytes (payload from the driver's independent oracle)
                    guard fields.count == 6, let count = Int(fields[2]), let fps = Int(fields[3]),
                          let frames = Int(fields[4]), let total = Int(fields[5]) else {
                        throw LoomError.message("openspinner requires count:fps:frames:payloadBytes")
                    }
                    result = try await pool.open(count: count, rate: fps, total: total, spinnerFrames: frames)
                case "select":
                    guard fields.count == 3, fields[2] == "none" || Int(fields[2]) != nil else { throw LoomError.message("select requires index|none") }
                    try pool.select(index: fields[2] == "none" ? nil : Int(fields[2]))
                    result = try await pool.snapshot()
                case "snapshot": result = try await pool.snapshot()
                case "hide":
                    app.closeWindowForEvidence()
                    try await Task.sleep(for: .milliseconds(300))
                    result = try await pool.snapshot()
                case "latency":
                    guard fields.count == 3, let count = Int(fields[2]), (1...500).contains(count) else {
                        throw LoomError.message("latency requires samples 1...500")
                    }
                    let path = directory.appendingPathComponent("latency.json")
                    try? FileManager.default.removeItem(at: path)
                    let surface = try pool.selectedSurfaceForLatency()
                    await measureInputToDisplay(samples: count, surface: surface)
                    let value = try JSONSerialization.jsonObject(with: Data(contentsOf: path))
                    result = ["latency": value]
                case "stop": result = try await pool.stop()
                case "cycles":
                    guard fields.count == 3, let count = Int(fields[2]) else { throw LoomError.message("cycles requires count") }
                    result = try await pool.cycles(count: count)
                default: throw LoomError.message("Unknown resource operation")
                }
                write("ack-\(operationID)", ["operationID": operationID, "succeeded": true,
                    "startedUptime": started, "finishedUptime": ProcessInfo.processInfo.systemUptime,
                    "app": app.evidenceState, "result": result])
            } catch {
                let partial = try? await resourcePool?.snapshot()
                write("ack-\(operationID)", ["operationID": operationID, "succeeded": false,
                    "startedUptime": started, "finishedUptime": ProcessInfo.processInfo.systemUptime,
                    "result": partial ?? [:], "error": String(describing: error)])
            }
        }
    }

    private actor QuitAttempts {
        private var count = 0
        func next() -> Int { count += 1; return count }
    }
    private let quitAttempts = QuitAttempts()

    /// Capture the recorder on the main actor, then collect and persist diagnostics
    /// on the shutdown task. The final AppKit reply must never await this actor.
    func quitRecorder(runtime: SessionRuntime?, started: Double) -> @Sendable (ShutdownReport) async -> Void {
        let attempts = quitAttempts
        let directory = directory
        let resourceQuit = pendingResourceQuit
        return { report in
            let attempt = await attempts.next()
            let seconds = ProcessInfo.processInfo.systemUptime - started
            var state: [String: Any] = [:]
            if let runtime { state = await ConversationController.runtimeEvidence(of: runtime) }
            let summary: [String: Any] = [
                "runtime": state,
                "succeeded": report.succeeded, "seconds": seconds,
                "remaining": report.remainingCountVerified == false ? NSNull() : report.remaining.count as Any,
                "remainingCountVerified": report.remainingCountVerified ?? true, "errors": report.errors,
                "signals": report.signals.count, "guarantee": report.ownershipGuarantee,
            ]
            Self.write("quit-attempt-\(attempt)", summary, directory: directory)
            Self.write("quit", summary, directory: directory)
            if let resourceQuit {
                Self.write("ack-\(resourceQuit)", ["operationID": resourceQuit,
                    "succeeded": report.succeeded && report.remaining.isEmpty,
                    "result": summary], directory: directory)
            }
        }
    }

    func write(_ name: String, _ object: [String: Any]) {
        Self.write(name, object, directory: directory)
    }

    nonisolated private static func write(_ name: String, _ object: [String: Any], directory: URL) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
    }
}
#endif
