import Darwin
import Foundation

public struct OpenCodeServerConfiguration: Sendable {
    public let executable: String
    public let workingDirectory: String
    /// The resolved launch environment, including any task capability meant
    /// for native LOCAL tools. No value is logged or written to an app catalog.
    public let environment: [String: String]
    public let expectedVersion: String
    /// The server reports only tmp; this independently binds all roots to the
    /// resolved executable, environment and working directory.
    public let profileProof: OpenCodeProfileProof
    public let startupTimeout: TimeInterval
    public let scope: RunScope

    public init(executable: String, workingDirectory: String, environment: [String: String],
                expectedVersion: String, profileProof: OpenCodeProfileProof,
                startupTimeout: TimeInterval = 5, scope: RunScope) {
        self.executable = executable; self.workingDirectory = workingDirectory; self.environment = environment
        self.expectedVersion = expectedVersion; self.profileProof = profileProof
        self.startupTimeout = startupTimeout; self.scope = scope
    }
}

/// Owns one foreground server inside the TUI's run scope. The caller must stop
/// the TUI as well and use the last run's scope-empty proof for the whole run.
public actor OpenCodeServerManager {
    /// Content-free startup evidence; no native output or capability is kept
    /// here. The bounded output buffer remains private to its run.
    struct StartupDiagnostic: Sendable {
        enum Phase: String, Sendable { case idle, profile, catalog, launch, listener, info, ready }
        var phase = Phase.idle
        var exitStatus: Int32?
        var outputBytes = 0
        var indicators: [String] = []
        var loaderLines: [String] = []
        /// Transport finish drains for a bounded period; it does not expose EOF proof.
        var outputCompleteness = "not-finalized"
        var outputOverflow = false
    }
    private(set) var startupDiagnostic = StartupDiagnostic()
    private struct Running: Sendable { let sessionID: UUID; let client: OpenCodeClient }
    private let supervisor: ProcessSupervisor
    private let configuration: OpenCodeServerConfiguration
    private var running: Running?
    private var startTask: Task<Running, any Error>?
    private var startGeneration: UUID?
    private var stopTask: Task<(report: SessionStopReport?, errors: [String]), Never>?
    private var failedSessionID: UUID?

    public init(supervisor: ProcessSupervisor, configuration: OpenCodeServerConfiguration) {
        self.supervisor = supervisor; self.configuration = configuration
    }

    /// Startup has one owner. A second caller during startup is refused;
    /// after readiness callers may reuse the same live client. Canceling the
    /// owner stops and verifies its server before returning cancellation.
    public func start() async throws -> OpenCodeClient {
        try Task.checkCancellation()
        if let stopTask { _ = await stopTask.value; try Task.checkCancellation() }
        guard failedSessionID == nil else { throw OpenCodeError.unavailable }
        if let running { return running.client }
        guard startTask == nil else { throw OpenCodeError.conflict }
        let generation = UUID()
        let task = Task { try await self.startServer() }
        startGeneration = generation
        startTask = task
        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                try Task.checkCancellation()
                guard startGeneration == generation, stopTask == nil else { throw CancellationError() }
                running = result
                startTask = nil
                startGeneration = nil
                return result.client
            } catch {
                // Stop is coalesced and awaits any in-flight start. A failed
                // ownership proof remains registered for a later retry.
                let cleanup = await stop()
                guard cleanup.errors.isEmpty else { throw OpenCodeError.unavailable }
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: { task.cancel() }
    }

    public func stop() async -> (report: SessionStopReport?, errors: [String]) {
        if let stopTask { return await stopTask.value }
        let task = Task { await self.performStop() }
        stopTask = task
        let result = await task.value
        stopTask = nil
        return result
    }

    private func performStop() async -> (report: SessionStopReport?, errors: [String]) {
        if let startTask {
            startGeneration = nil
            startTask.cancel()
            running = try? await startTask.value
            self.startTask = nil
        }
        let active = running
        running = nil
        if let active { await active.client.close() }
        guard let id = active?.sessionID ?? failedSessionID else { return (nil, []) }
        return await cleanUp(id)
    }

    private func cleanUp(_ id: UUID) async -> (report: SessionStopReport?, errors: [String]) {
        var errors: [String] = []
        var report: SessionStopReport?
        if await supervisor.session(id: id)?.currentRun != nil {
            do { report = try await supervisor.stop(sessionID: id, graceSeconds: 0.05) }
            catch { errors.append("OpenCode server stop failed") }
            if let report, !report.succeeded { errors.append("OpenCode server stop could not be verified") }
        }
        if errors.isEmpty {
            do {
                try await supervisor.discardInternalSession(id)
                await supervisor.events.forget(sessionID: id)
                failedSessionID = nil
            } catch {
                failedSessionID = id
                errors.append("OpenCode server session could not be discarded")
            }
        } else { failedSessionID = id }
        return (report, errors)
    }

    private func startServer() async throws -> Running {
        guard configuration.startupTimeout.isFinite, configuration.startupTimeout > 0,
              configuration.startupTimeout <= 30, configuration.workingDirectory.hasPrefix("/"),
              !configuration.expectedVersion.isEmpty else { throw OpenCodeError.invalidTarget }
        startupDiagnostic = StartupDiagnostic(phase: .profile)
        try await configuration.profileProof.validate(executable: configuration.executable,
                                                      environment: configuration.environment,
                                                      workingDirectory: configuration.workingDirectory)
        try Task.checkCancellation()
        let session = ManagedSession(provider: .synthetic, workingDirectory: configuration.workingDirectory)
        startupDiagnostic.phase = .catalog
        try await supervisor.createInternalSession(session)
        let output = OpenCodeStartupOutput()
        var startupPassword: String?
        do {
            try Task.checkCancellation()
            var random = [UInt8](repeating: 0, count: 32)
            random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            let password = random.map { String(format: "%02x", $0) }.joined()
            startupPassword = password
            let environment = LaunchEnvironment.make(base: configuration.environment,
                                                     runID: supervisor.ownershipRunID, sessionID: session.id)
            let profile = try OpenCodeLaunchProfile.server(environment: environment, password: password)
            try Task.checkCancellation()
            startupDiagnostic.phase = .launch
            let launch = try await supervisor.launch(sessionID: session.id, executable: configuration.executable,
                                                     arguments: profile.arguments, environment: profile.environment,
                                                     outputSink: output, scope: configuration.scope)
            guard let leader = launch.session.currentRun?.leader else { throw OpenCodeError.unavailable }
            startupDiagnostic.phase = .listener
            let deadline = ProcessInfo.processInfo.systemUptime + configuration.startupTimeout
            repeat {
                try Task.checkCancellation()
                if let status = await launch.terminal.exitStatus() {
                    startupDiagnostic.exitStatus = status
                    throw OpenCodeError.unavailable
                }
                if output.overflow { throw OpenCodeError.responseTooLarge }
                if let url = output.serverURL {
                    startupDiagnostic.phase = .info
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { break }
                    let client = try OpenCodeClient(serverURL: url, password: password, leader: leader,
                                                    profileProof: configuration.profileProof,
                                                    executable: configuration.executable,
                                                    environment: configuration.environment,
                                                    workingDirectory: configuration.workingDirectory,
                                                    timeout: min(2, max(0.05, remaining)))
                    do {
                        try await client.verify(pid: leader.pid, version: configuration.expectedVersion,
                                                temporaryDirectory: configuration.profileProof.roots.tmp)
                        try await configuration.profileProof.validate(executable: configuration.executable,
                                                                      environment: configuration.environment,
                                                                      workingDirectory: configuration.workingDirectory)
                        output.stopCapturing()
                        startupDiagnostic.phase = .ready
                        return Running(sessionID: session.id, client: client)
                    } catch OpenCodeError.httpStatus(503) {
                        await client.close()
                    } catch OpenCodeError.unavailable {
                        await client.close()
                    } catch {
                        await client.close()
                        throw error
                    }
                }
                try await Task.sleep(for: .milliseconds(20))
            } while ProcessInfo.processInfo.systemUptime < deadline
            throw OpenCodeError.timeout
        } catch {
            // The caller's canceled task must not cancel the cleanup that proves
            // destruction. The supervisor retains the id if cleanup cannot pass.
            let cleanup = await Task.detached { await self.cleanUp(session.id) }.value
            // Exit observation can precede the final PTY read. Finalize only
            // after the supervisor's bounded output drain and cleanup attempt.
            if let startupPassword {
                let diagnostic = output.diagnostic(redacting: startupPassword)
                startupDiagnostic.outputBytes = diagnostic.bytes
                startupDiagnostic.indicators = diagnostic.indicators
                startupDiagnostic.loaderLines = diagnostic.loaderLines
                startupDiagnostic.outputOverflow = output.overflow
                startupDiagnostic.outputCompleteness = cleanup.errors.isEmpty
                    ? "bounded-drain-eof-unverified" : "cleanup-unverified"
            }
            output.stopCapturing()
            throw error
        }
    }
}

private final class OpenCodeStartupOutput: TerminalOutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var capturing = true
    private var tooLarge = false
    private static let limit = 64 * 1024

    func receive(_ data: Data) {
        lock.withLock {
            guard capturing else { return }
            guard bytes.count + data.count <= Self.limit else { tooLarge = true; return }
            bytes.append(data)
        }
    }
    var overflow: Bool { lock.withLock { tooLarge } }
    func diagnostic(redacting password: String) -> (bytes: Int, indicators: [String], loaderLines: [String]) {
        lock.withLock {
            let text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: password, with: "<capability>")
            let normalized = text.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#,
                with: "", options: .regularExpression).replacingOccurrences(of: "\r", with: "\n")
            let lower = normalized.lowercased()
            let indicators = ["operation not permitted", "permission denied", "eperm", "eacces",
                              "invalid config", "cannot find", "module", "error", "dyld", "library not loaded",
                              "symbol not found", "panic", "sandbox", "signature", "mapping", "bootstrap"]
            // Exact runtime literals distinguish a real error from Bun's
            // generic "Machine" metadata. Only finite labels leave the buffer.
            let panicPhrases = [
                ("panic(main thread):", "bun-main-panic"),
                ("Trap instruction at address 0x", "trap-instruction"),
                ("Illegal instruction at address 0x", "illegal-instruction"),
                ("abort() called", "explicit-abort"),
                ("reached unreachable code", "unreachable"),
                ("Unaligned memory access", "unaligned-memory"),
                ("Stack overflow", "stack-overflow"),
                ("unsupported uv function:", "unsupported-uv"),
                ("Bun encountered a crash when running a NAPI module", "napi-crash"),
                ("panicked during a panic. Aborting.", "panic-during-panic"),
                ("MachportCreationFailed", "machport-creation-failed"),
                ("IoRequestLoop::ensure_init() succeeded before schedule()", "io-init-invariant"),
                ("WTF::initMachExceptionHandlerThread", "mach-exception-handler")]
            var tags = indicators.filter(lower.contains)
            tags += panicPhrases.filter { normalized.contains($0.0) }.map(\.1)
            for line in normalized.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
                where line.hasPrefix("Crashed while ") {
                if line.contains("resolving a module") { tags.append("resolving-module") }
                if line.contains("loading native module:") {
                    tags.append("loading-native-module")
                    let modules = [("/$bunfs/root/watcher-tzt47keb.node", "watcher"),
                                   ("/$bunfs/root/libfff_c-yhjnkhce.dylib", "fff"),
                                   ("/$bunfs/root/librust_pty_arm64-cc26t8z1.dylib", "rust-pty"),
                                   ("/$bunfs/root/libopentui-fpx6fz9r.dylib", "opentui")]
                    let found = modules.filter { module in
                        line.components(separatedBy: .whitespaces).contains { token in
                            token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'(),")).elementsEqual(module.0)
                        }
                    }.map(\.1)
                    tags += found.isEmpty ? ["other-or-unreported"] : found
                }
            }
            // Only public native loader diagnostics are admitted here. Never
            // copy arbitrary provider output, configuration or terminal text.
            let prefixes = ["dyld[", "Library not loaded:", "Reason:", "Symbol not found:"]
            let lines = normalized.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { line in prefixes.contains { line.hasPrefix($0) } }.prefix(4)
                .map { String($0.prefix(320)).replacingOccurrences(of: #"[A-Fa-f0-9]{24,}"#,
                    with: "<digest>", options: .regularExpression) }
            return (bytes.count, Array(Set(tags)).sorted(), lines)
        }
    }
    func stopCapturing() { lock.withLock { capturing = false; bytes.removeAll(keepingCapacity: false) } }

    var serverURL: URL? {
        lock.withLock {
            let text = String(decoding: bytes, as: UTF8.self)
            guard let expression = try? NSRegularExpression(pattern: #"server listening on (http://127\.0\.0\.1:[0-9]{1,5})\r?\n"#),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text), let url = URL(string: String(text[range])),
                  OpenCodeLaunchProfile.validServerURL(url) else { return nil }
            return url
        }
    }
}
