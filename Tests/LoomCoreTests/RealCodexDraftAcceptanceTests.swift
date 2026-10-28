import CryptoKit
import Darwin
import Foundation
import Testing
@testable import LoomCore

// The only provider input in this suite is the first positional message of a
// new draft. Discovery and a normal test run never start a provider.
private enum RealCodexAcceptanceGate {
    static let required = [
        "LOOM_ACC_REAL_CODEX_HOME", "LOOM_ACC_REAL_CODEX_EXECUTABLE", "LOOM_ACC_REAL_CODEX_WORK_ROOT",
        "LOOM_ACC_REAL_CODEX_EVIDENCE", "LOOM_ACC_REAL_CODEX_RESERVATION",
    ]
    static var enabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["LOOM_ACC_REAL_CODEX"] == "1" && required.allSatisfy { !(env[$0] ?? "").isEmpty }
    }
}

private struct RealAcceptanceFailure: Error {
    let phase: String // Fixed test-defined labels; never a provider's output.
    init(_ phase: String) { self.phase = phase }
}

private func requireAcceptance(_ value: Bool, _ phase: String) throws {
    if !value { throw RealAcceptanceFailure(phase) }
}

private struct RealAcceptanceInputs {
    let profile: URL
    let executable: String
    let work: URL
    let evidence: URL
    let reservation: URL

    static func read() throws -> Self {
        let env = ProcessInfo.processInfo.environment
        func path(_ key: String) throws -> URL {
            guard let raw = env[key], raw.hasPrefix("/") else { throw RealAcceptanceFailure("input-path") }
            return URL(fileURLWithPath: raw).standardizedFileURL
        }
        func existingDirectory(_ url: URL) throws -> URL {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
                throw RealAcceptanceFailure("input-directory")
            }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(url.path, &buffer) != nil else { throw RealAcceptanceFailure("input-directory") }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
        }
        let work = try existingDirectory(path("LOOM_ACC_REAL_CODEX_WORK_ROOT"))
        try requireAcceptance(work.path.hasPrefix("/private/tmp/loom-real/") &&
            work.path.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value) || (65...90).contains(scalar.value) ||
                (97...122).contains(scalar.value) || "/-_.".unicodeScalars.contains(scalar)
            }, "work-root")
        let evidence = try existingDirectory(path("LOOM_ACC_REAL_CODEX_EVIDENCE"))
        let allowedEvidence = "/Users/gencberke/Library/Caches/loom-v2/evidence/r9/d1/real-acceptance"
        try requireAcceptance(evidence.path == allowedEvidence, "evidence-root")
        let profilePath = try path("LOOM_ACC_REAL_CODEX_HOME")
        let profile = try existingDirectory(profilePath)
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
        let forbidden = home + "/.codex"
        for candidate in [profilePath.path, profile.path] {
            try requireAcceptance(candidate != home && candidate != forbidden && !candidate.hasPrefix(forbidden + "/"),
                                  "real-profile-refused")
        }
        // Only the explicitly isolated development area or another synthetic test
        // root can be selected; do not interpret an arbitrary home folder as isolated.
        try requireAcceptance(profile.path.hasPrefix(home + "/.loom-dev/") ||
                              profile.path.hasPrefix("/private/tmp/loom-real/"), "profile-isolation")
        let executable = try path("LOOM_ACC_REAL_CODEX_EXECUTABLE").path
        try requireAcceptance(FileManager.default.isExecutableFile(atPath: executable), "executable")
        let reservation = try path("LOOM_ACC_REAL_CODEX_RESERVATION")
        try requireAcceptance(reservation.deletingLastPathComponent().resolvingSymlinksInPath().path == evidence.path,
                              "reservation-location")
        var info = stat()
        try requireAcceptance(lstat(reservation.path, &info) == 0 &&
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && info.st_uid == geteuid() &&
            info.st_mode & 0o077 == 0, "reservation-file")
        try requireAcceptance(lstat(reservation.path + ".result.json", &info) != 0 && errno == ENOENT,
                              "result-preexists")
        return Self(profile: profile, executable: executable, work: work, evidence: evidence, reservation: reservation)
    }

    /// Create and durably record the one-use claim before a TUI can be spawned.
    /// The conservative state remains unknown if the process or test crashes.
    func consumeReservation() throws {
        let sidecar = reservation.path + ".consumed"
        let fd = open(sidecar, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw RealAcceptanceFailure("reservation-consumed") }
        defer { close(fd) }
        let text = Data("submission=unknown; claimed before provider spawn\n".utf8)
        let written = text.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        try requireAcceptance(written == text.count && fsync(fd) == 0, "reservation-write")
    }
}

/// Provider output is used only in memory to detect an eventual final state;
/// it is bounded and never printed or written to evidence.
private final class RealAcceptanceScreen: TerminalOutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func receive(_ data: Data) {
        lock.withLock {
            bytes.append(data)
            if bytes.count > 64 * 1024 { bytes = Data(bytes.suffix(64 * 1024)) }
        }
    }
}

private actor RealAcceptanceToolchain {
    private var newRun = true
    func useResume() { newRun = false }
    func extras(root: String) -> [String] {
        guard newRun else { return [] }
        return ["-c", "approvals_reviewer=\"auto_review\"",
                "-c", "sandbox_workspace_write.network_access=true",
                "-c", "sandbox_workspace_write.writable_roots=[\"\(root)/extra-root\"]"]
    }
}

private struct RealAcceptanceEvidence: Encodable {
    var phase = "preflight"
    var submission = "not-started"
    var submittedUserInputs: Int? = nil
    var taskResult = "unverified"
    var settingsResult = "unverified"
    var approvalResult = "unverified"
    var stopResult = "unverified"
    var resumeResult = "unverified"
    var quitResult = "unverified"
    var cleanup = "unverified"
    var threadID: String? = nil
    var turnID: String? = nil
    var sourceOutcome = "unverified"
    var reservationTime: Date? = nil
    var identityTime: Date? = nil
    var approvalTime: Date? = nil
    var approvalParameterKeys: [String] = []
    var approvalNonNullExtraKeys: [String] = []
    var inputObservedTime: Date? = nil
    var sessionID: String? = nil
    var serverPID: Int32? = nil
    var tuiPID: Int32? = nil
    var observedProcessCount = 0
    var observedProcesses: [ProcessIdentity] = []
    var firstSocket: String? = nil
    var firstHashedSocket: String? = nil
    var resumedServerPID: Int32? = nil
    var resumedTuiPID: Int32? = nil
    var resumedSocket: String? = nil
    var resumedHashedSocket: String? = nil
    var resumedObservedProcessCount = 0
    var resumedObservedProcesses: [ProcessIdentity] = []
    var errorPhase: String? = nil
    var note = "No raw provider output, account data, credentials, or environment values recorded. Auxiliary model activity is unknown."
}

private struct RealAcceptanceWitness {
    let requested: String
    let hashed: String
    var identities: Set<ProcessIdentity>
    let server: ProcessIdentity
    let tui: ProcessIdentity

    func absent() throws -> Bool {
        func pathAbsent(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) != 0 && errno == ENOENT
        }
        let living = Set(try ProcessTable.snapshot().map(\.identity))
        return identities.isDisjoint(with: living) && pathAbsent(requested) && pathAbsent(hashed)
    }
}

private extension SessionRuntime {
    func acceptanceConnection(for sessionID: UUID) async -> (CodexAppServerClient, String, RunScope, UUID)? {
        guard let server = codexServers.first(where: { $0.ownerCard == sessionID }),
              let client = server.client, let scope = server.scope,
              let internalID = await server.manager.internalSessionID() else { return nil }
        return (client, server.socket, scope, internalID)
    }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(6)),
       .enabled(if: RealCodexAcceptanceGate.enabled, "Explicit isolated real-Codex acceptance inputs are required"))
struct RealCodexDraftAcceptanceTests {
    private static let fileMarker = "LOOM_D1_REAL_FILE_OK\n"
    private static let completionMarker = "LOOM_D1_REAL_DONE"

    @Test func oneDraftApprovalStopResumeAndQuit() async {
        var result = RealAcceptanceEvidence()
        var runtime: SessionRuntime?
        var supervisor: ProcessSupervisor?
        var bundleRoot: URL?
        var reservationConsumed = false
        var witnesses: [RealAcceptanceWitness] = []
        var inputs: RealAcceptanceInputs?
        do {
            let value = try RealAcceptanceInputs.read()
            inputs = value
            let marker = value.work.appendingPathComponent("p0-d1-real-acceptance.txt")
            var markerInfo = stat()
            try requireAcceptance(lstat(marker.path, &markerInfo) != 0 && errno == ENOENT, "marker-preexists")
            let token = UUID().uuidString.lowercased()
            let runtimeDir = value.evidence.appendingPathComponent("runtime-\(token)", isDirectory: true)
            let hostDir = value.evidence.appendingPathComponent("host-\(token)", isDirectory: true)
            let localDir = value.work.appendingPathComponent("runtime-\(token.prefix(8))", isDirectory: true)
            let hostSocket = localDir.appendingPathComponent("s/r/h-000000000000.sock").path
            try requireAcceptance(hostSocket.utf8.count < 104, "work-root-too-long-for-socket")
            try Self.makePrivateDirectory(runtimeDir)
            try Self.makePrivateDirectory(hostDir)
            bundleRoot = hostDir
            try Self.makePrivateDirectory(localDir)
            let localHome = localDir.appendingPathComponent("home", isDirectory: true)
            let localTemp = localDir.appendingPathComponent("tmp", isDirectory: true)
            let extraRoot = runtimeDir.appendingPathComponent("extra-root", isDirectory: true)
            for directory in [localHome, localTemp, extraRoot] {
                try Self.makePrivateDirectory(directory)
            }
            // A deliberately broader root outside the work folder: the model
            // is not authorized to use it, and it remains as test evidence.
            let bundle = try RunScopeLauncher.assembleOwnedBundle(
                executable: RuntimeFixture.binaries.appendingPathComponent("loom-run-host"), in: hostDir)
            let socketDir = localDir.appendingPathComponent("s", isDirectory: true)
            let catalog = try SessionCatalog(url: runtimeDir.appendingPathComponent("catalog.sqlite3"))
            let processSupervisor = try await ProcessSupervisor.restoring(catalog: catalog,
                scopeLauncher: RunScopeLauncher(hostBundle: bundle, socketDirectory: socketDir.appendingPathComponent("r")))
            supervisor = processSupervisor
            let phase = RealAcceptanceToolchain()
            let resolver: ProviderToolchainResolver = { provider in
                guard provider == .codex else { throw RealAcceptanceFailure("unexpected-provider") }
                return ProviderToolchain(provider: .codex, executable: value.executable,
                    capabilities: ProviderCapabilities(version: "0.164.0", help: "--remote <ADDR>",
                                                       serverHelp: "--listen <URL>"),
                    environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": localHome.path,
                                  "TMPDIR": localTemp.path, "TERM": "xterm-256color"],
                    profileDirectory: value.profile, extraArguments: await phase.extras(root: runtimeDir.path))
            }
            let models = [ModelCatalogEntry(harness: .codex, id: "gpt-6-luna", title: "GPT-6 Luna", efforts: ["low"])]
            let instance = SessionRuntime(supervisor: processSupervisor, catalog: catalog,
                configuration: SessionRuntimeConfiguration(toolchains: resolver,
                    hookHelperPath: RuntimeFixture.binaries.appendingPathComponent("loom-hook").path,
                    socketDirectory: socketDir, homeDirectory: value.work.path,
                    codexIdentityTimeout: 45, codexServerStartupTimeout: 15, resumeDiagnosticsWindow: 2,
                    claudeTemporaryRoot: nil, claudeEnvironment: [:], catalogBackupDelay: nil,
                    openedModels: { _ in models }))
            runtime = instance
            try await instance.start()
            let project = try await catalog.addProject(path: value.work.path).project
            let script = "printf 'LOOM_D1_REAL_FILE_OK\\n' > \(marker.path)"
            let prompt = "Run exactly this one shell command: /bin/zsh -lc \"\(script)\". " +
                "Use no other commands, tools, files or network. Ask for approval if needed. " +
                "Then reply exactly \(Self.completionMarker)."
            let choices = HarnessLaunchChoices(harness: .codex, model: "gpt-6-luna", effort: "low", mode: .askBeforeEdits)
            let screen = RealAcceptanceScreen()
            try value.consumeReservation()
            reservationConsumed = true
            result.reservationTime = Date()
            result.submission = "unknown-after-reservation"
            result.phase = "new-draft"
            let launch = try await instance.startConversation(provider: .codex, projectID: project.id, outputSink: screen,
                draft: NewSessionLaunch(firstMessage: prompt, choices: choices))
            result.sessionID = launch.sessionID.uuidString
            guard let threadID = try await catalog.session(id: launch.sessionID)?.session.providerConversationID,
                  UUID(uuidString: threadID) != nil else { throw RealAcceptanceFailure("identity") }
            result.threadID = threadID
            result.identityTime = Date()
            guard let (client, socket, scope, serverID) = await instance.acceptanceConnection(for: launch.sessionID),
                  let coordinator = await instance.codexCoordinator(forSession: launch.sessionID) else {
                throw RealAcceptanceFailure("owned-connection")
            }
            var firstWitness = try await Self.witness(socket: socket, scope: scope, supervisor: processSupervisor,
                                                       sessionID: launch.sessionID, serverID: serverID)
            witnesses.append(firstWitness)
            result.serverPID = firstWitness.server.pid
            result.tuiPID = firstWitness.tui.pid
            result.observedProcessCount = firstWitness.identities.count
            result.observedProcesses = firstWitness.identities.sorted { $0.pid < $1.pid }
            result.firstSocket = firstWitness.requested
            result.firstHashedSocket = firstWitness.hashed
            try requireAcceptance(lstat(marker.path, &markerInfo) != 0 && errno == ENOENT, "write-before-approval")
            result.phase = "approval"
            let deadline = ProcessInfo.processInfo.systemUptime + 60
            var pending: CodexPendingRequest?
            repeat {
                try requireAcceptance(lstat(marker.path, &markerInfo) != 0 && errno == ENOENT, "write-before-approval")
                let snapshot = await coordinator.pendingRequestSnapshot()
                try requireAcceptance(snapshot.pending.count <= 1, "multiple-requests")
                if let request = snapshot.pending.first { pending = request; break }
                try await Task.sleep(for: .milliseconds(100))
            } while ProcessInfo.processInfo.systemUptime < deadline
            guard let pending else { throw RealAcceptanceFailure("approval-not-observed") }
            let allowed: Set<String> = ["threadId", "turnId", "itemId", "command", "cwd", "availableDecisions", "reason"]
            let parameters = pending.request.params.object ?? [:]
            result.approvalParameterKeys = parameters.keys.sorted()
            result.approvalNonNullExtraKeys = parameters.filter { !allowed.contains($0.key) && $0.value != .null }.keys.sorted()
            try Self.requireExactApproval(pending, launch: launch, threadID: threadID, cwd: value.work.path, script: script)
            result.turnID = pending.request.params.object?["turnId"]?.string
            let published = await Self.waitUntil(5) {
                await processSupervisor.events.snapshot().sessions[launch.sessionID]?.userRequests
                    .contains { $0.id == pending.id.uuidString && $0.kind == .command } == true
            }
            try requireAcceptance(published, "approval-not-published")
            try await instance.respond(sessionID: launch.sessionID, requestID: pending.id.uuidString, decision: .accept)
            result.approvalResult = "accepted-exact-occurrence-once"
            result.approvalTime = Date()
            result.phase = "turn-completion"
            let completed = await Self.waitUntil(120) {
                let activity = await processSupervisor.providerWorkState(sessionID: launch.sessionID)?.activity
                return activity == .turnComplete
            }
            let latest = try await client.readThread(threadID)
            switch latest.lastTurnOutcome {
            case .completed: result.sourceOutcome = "completed"
            case .interrupted: result.sourceOutcome = "interrupted"
            case .failed: result.sourceOutcome = "failed"
            case .unknown: result.sourceOutcome = "unknown"
            case nil: result.sourceOutcome = "missing"
            }
            try requireAcceptance(completed && Self.markerEquals(marker, expected: Self.fileMarker),
                                  "turn-or-marker-incomplete")
            try requireAcceptance(latest.threadID == threadID && latest.lastTurnID == result.turnID &&
                                  latest.lastTurnOutcome == .completed &&
                                  latest.lastAssistantMessage == Self.completionMarker, "completion-message")
            // A new TUI thread may have no rollout until this turn persists.
            // The exact owned approval is safe independently of a pre-turn
            // metadata read; verify the actual settings once persistence exists.
            result.phase = "effective-settings"
            let settings = try await client.request(method: "thread/resume",
                params: .object(["threadId": .string(threadID), "excludeTurns": .bool(true)]), timeout: 12)
            try Self.requireSafeSettings(settings, threadID: threadID, cwd: value.work.path)
            result.settingsResult = "verified-after-first-prompt"
            let history = try await client.request(method: "thread/read", params: .object([
                "threadId": .string(threadID), "includeTurns": .bool(true),
            ]), timeout: 12)
            try Self.requireFirstMessage(history, threadID: threadID, turnID: result.turnID, prompt: prompt)
            result.submission = "observed-in-owned-thread"
            result.submittedUserInputs = 1
            result.inputObservedTime = Date()
            result.taskResult = "verified"
            result.phase = "stop"
            firstWitness.identities.formUnion(try scope.members().filter { !$0.launchdSpawned }.map(\.identity))
            witnesses[0] = firstWitness
            result.observedProcessCount = firstWitness.identities.count
            result.observedProcesses = firstWitness.identities.sorted { $0.pid < $1.pid }
            let stopped = try await instance.stopConversation(sessionID: launch.sessionID)
            try requireAcceptance(stopped.succeeded && stopped.remainingCountVerified == true, "stop-report")
            try requireAcceptance(try firstWitness.absent(), "stop-owned-cleanup")
            result.stopResult = "verified"
            await phase.useResume()
            await instance.invalidateToolchain(.codex)
            result.phase = "resume"
            let resumed = try await instance.resumeConversation(sessionID: launch.sessionID, outputSink: RealAcceptanceScreen())
            try requireAcceptance(resumed.sessionID == launch.sessionID && resumed.runID != launch.runID, "resume-session")
            let identityAfter = try await catalog.session(id: launch.sessionID)?.session.providerConversationID
            try requireAcceptance(identityAfter == threadID, "resume-identity")
            guard let effective = await instance.codexResumeSettings(forSession: launch.sessionID) else {
                throw RealAcceptanceFailure("resume-settings")
            }
            try requireAcceptance(effective.model == "gpt-6-luna" && effective.effort == "low" &&
                                  effective.mode == .askBeforeEdits, "resume-settings")
            guard let (_, resumedSocket, resumedScope, resumedServerID) = await instance.acceptanceConnection(for: launch.sessionID)
            else { throw RealAcceptanceFailure("resume-connection") }
            let resumedWitness = try await Self.witness(socket: resumedSocket, scope: resumedScope,
                supervisor: processSupervisor, sessionID: launch.sessionID, serverID: resumedServerID)
            witnesses.append(resumedWitness)
            result.resumedServerPID = resumedWitness.server.pid
            result.resumedTuiPID = resumedWitness.tui.pid
            result.resumedSocket = resumedWitness.requested
            result.resumedHashedSocket = resumedWitness.hashed
            result.resumedObservedProcessCount = resumedWitness.identities.count
            result.resumedObservedProcesses = resumedWitness.identities.sorted { $0.pid < $1.pid }
            result.resumeResult = "verified-same-thread-no-input"
            result.phase = "quit"
        } catch let failure as RealAcceptanceFailure {
            result.errorPhase = failure.phase
        } catch {
            // Provider errors and process output may contain user data: classify
            // by the current fixed stage and do not log the error itself.
            result.errorPhase = result.phase + "-error"
        }

        // This runs after every failure or success once the runtime exists.
        // No direct unlink/signal fallback is used when ownership is uncertain.
        if let runtime {
            let quit = await runtime.shutdown()
            result.quitResult = quit.succeeded && quit.remainingCountVerified == true ? "verified" : "failed-or-unknown"
            if !witnesses.isEmpty {
                let absent = (try? witnesses.allSatisfy { try $0.absent() }) == true
                result.cleanup = absent && result.quitResult == "verified" ? "verified-owned-observations" : "failed-or-unknown"
            } else {
                result.cleanup = result.quitResult == "verified" ? "runtime-reported-only" : "failed-or-unknown"
            }
            if let supervisor, (try? await supervisor.ownedProcesses().isEmpty) != true { result.cleanup = "failed-or-unknown" }
        }
        if let bundleRoot, result.quitResult == "verified", result.cleanup != "failed-or-unknown" {
            RunScopeLauncher.removeOwnedBundle(in: bundleRoot)
        }
        if reservationConsumed, let inputs {
            do { try Self.writeEvidence(result, to: inputs.reservation.path + ".result.json") }
            catch { Issue.record("Real acceptance evidence could not be written") }
        }
        if let phase = result.errorPhase { Issue.record("Real acceptance stopped at \(phase); submission: \(result.submission)") }
        if result.cleanup == "failed-or-unknown" { Issue.record("Owned process or socket cleanup could not be verified") }
        if result.errorPhase == nil {
            #expect(result.taskResult == "verified")
            #expect(result.stopResult == "verified")
            #expect(result.resumeResult == "verified-same-thread-no-input")
            #expect(result.quitResult == "verified")
            #expect(result.cleanup == "verified-owned-observations")
        }
    }

    private static func waitUntil(_ seconds: TimeInterval, _ predicate: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if await predicate() { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(200))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private static func makePrivateDirectory(_ url: URL) throws {
        try requireAcceptance(mkdir(url.path, mode_t(0o700)) == 0, "private-directory-create")
    }

    private static func witness(socket: String, scope: RunScope, supervisor: ProcessSupervisor,
                                sessionID: UUID, serverID: UUID) async throws -> RealAcceptanceWitness {
        guard let server = await supervisor.session(id: serverID)?.currentRun?.leader,
              let tui = await supervisor.session(id: sessionID)?.currentRun?.leader else {
            throw RealAcceptanceFailure("process-identities")
        }
        let members = try scope.members().filter { !$0.zombie }
        var identities = Set(members.filter { !$0.launchdSpawned }.map(\.identity))
        identities.insert(scope.host.identity)
        try requireAcceptance(identities.contains(server) && identities.contains(tui) && identities.contains(scope.host.identity),
                              "process-scope")
        let digest = SHA256.hash(data: Data(socket.utf8)).map { String(format: "%02x", $0) }.joined()
        let hashed = "/private/tmp/codex-daemon-\(geteuid())/\(digest)"
        return RealAcceptanceWitness(requested: socket, hashed: hashed, identities: identities, server: server, tui: tui)
    }

    private static func requireSafeSettings(_ value: JSONValue, threadID: String, cwd: String) throws {
        let response = value.object ?? [:]
        let thread = response["thread"]?.object ?? [:]
        let sandbox = response["sandbox"]?.object ?? [:]
        try requireAcceptance(thread["id"]?.string == threadID && response["cwd"]?.string == cwd &&
            response["model"]?.string == "gpt-6-luna" && response["reasoningEffort"]?.string == "low" &&
            response["approvalPolicy"]?.string == "on-request" && response["approvalsReviewer"]?.string == "user" &&
            sandbox["type"]?.string == "readOnly" && sandbox["networkAccess"]?.bool == false &&
            (sandbox["writableRoots"] == nil || sandbox["writableRoots"]?.array == []) &&
            (response["runtimeWorkspaceRoots"] == nil || response["runtimeWorkspaceRoots"]?.array == []) &&
            (response["activePermissionProfile"] == nil || response["activePermissionProfile"] == .null),
            "effective-settings-mismatch")
    }

    private static func requireExactApproval(_ pending: CodexPendingRequest, launch: RuntimeLaunch,
                                             threadID: String, cwd: String, script: String) throws {
        let request = pending.request
        let params = request.params.object ?? [:]
        let decisions = params["availableDecisions"]?.array ?? []
        let amendment = decisions.compactMap { $0.object?["acceptWithExecpolicyAmendment"]?.object?["execpolicy_amendment"]?.array }
        let scriptArguments: [JSONValue] = [.string("/bin/zsh"), .string("-lc"), .string(script)]
        let direct = params["command"]?.string == script
        let knownDisplay = params["command"]?.string == "/bin/zsh -lc \"\(script)\"" && amendment.contains(scriptArguments)
        let allowed: Set<String> = ["threadId", "turnId", "itemId", "command", "cwd", "availableDecisions", "reason"]
        let noExtraAuthority = params.allSatisfy { allowed.contains($0.key) || $0.value == .null }
        try requireAcceptance(request.kind == .commandExecution && request.method == "item/commandExecution/requestApproval" &&
            request.threadID == threadID && pending.binding.threadID == threadID &&
            pending.binding.sessionID == launch.sessionID && pending.binding.managedRunID == launch.runID &&
            pending.binding.workingDirectory == cwd && params["cwd"]?.string == cwd &&
            params["turnId"]?.string != nil && decisions.contains(.string("accept")) && noExtraAuthority &&
            (direct || knownDisplay),
            "approval-action-mismatch")
    }

    private static func markerEquals(_ url: URL, expected: String) -> Bool {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_size == Int64(expected.utf8.count) else { return false }
        var buffer = [UInt8](repeating: 0, count: expected.utf8.count)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        return count == buffer.count && Data(buffer) == Data(expected.utf8)
    }

    private static func requireFirstMessage(_ value: JSONValue, threadID: String, turnID: String?, prompt: String) throws {
        let thread = value.object?["thread"]?.object ?? [:]
        let turns = thread["turns"]?.array ?? []
        let items = turns.first?.object?["items"]?.array ?? []
        let messages = items.compactMap { item -> [JSONValue]? in
            guard item.object?["type"]?.string == "userMessage" else { return nil }
            return item.object?["content"]?.array
        }
        let content = messages.first ?? []
        try requireAcceptance(thread["id"]?.string == threadID && turns.count == 1 &&
            turnID != nil && turns.first?.object?["id"]?.string == turnID && messages.count == 1 &&
            content.count == 1 && content.first?.object?["type"]?.string == "text" &&
            content.first?.object?["text"]?.string == prompt, "first-message-evidence")
    }

    private static func writeEvidence(_ evidence: RealAcceptanceEvidence, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(evidence)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw RealAcceptanceFailure("evidence-create") }
        defer { close(fd) }
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        try requireAcceptance(count == data.count && fsync(fd) == 0, "evidence-write")
    }
}
