import CryptoKit
import Darwin
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

/// D2 step 4's one real deletion (opt-in, `REAL.md` in its evidence folder): a synthetic target and control thread in the
/// isolated Codex home, the target deleted through `SessionRuntime.deleteConversation` with run scopes on, then the native
/// absence, the control's presence, the kept history and the empty owned scopes checked. Never runs without
/// `LOOM_D2X_REAL=1` and its explicit inputs; it sends no model input (the two sessions exist before it runs).
private enum RealCodexDeletionGate {
    static let required = ["LOOM_D2X_CODEX", "LOOM_D2X_CODEX_HOME", "LOOM_D2X_WORK", "LOOM_D2X_DIR",
                           "LOOM_D2X_TARGET", "LOOM_D2X_CONTROL"]
    static var enabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["LOOM_D2X_REAL"] == "1" && required.allSatisfy { !(env[$0] ?? "").isEmpty }
    }
}

private struct RealDeletionFailure: Error, CustomStringConvertible {
    let phase: String   // fixed labels; never provider output
    var description: String { phase }
}

private func requireReal(_ value: Bool, _ phase: String) throws { if !value { throw RealDeletionFailure(phase: phase) } }

@Suite(.processHeavy, .timeLimit(.minutes(10)))
struct RealCodexDeletionTests {
    @Test(.enabled(if: RealCodexDeletionGate.enabled, "Explicit isolated real-Codex deletion inputs are required"))
    func aRealCodexSessionIsDeletedThroughTheRuntimeAndOnlyItsDataGoes() async throws {
        let env = ProcessInfo.processInfo.environment
        let user = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let home = URL(fileURLWithPath: realPath(URL(fileURLWithPath: env["LOOM_D2X_CODEX_HOME"]!)), isDirectory: true)
        let work = URL(fileURLWithPath: realPath(URL(fileURLWithPath: env["LOOM_D2X_WORK"]!)), isDirectory: true)
        let evidence = URL(fileURLWithPath: env["LOOM_D2X_DIR"]!, isDirectory: true)
        let executable = env["LOOM_D2X_CODEX"]!
        try requireReal(home.path.hasPrefix(user + "/.loom-dev/") && !home.path.hasPrefix(user + "/.codex"), "home-isolation")
        try requireReal(work.path.hasPrefix("/private/tmp/loom-real/d2x/"), "work-root")
        try requireReal(evidence.path.hasPrefix(user + "/Library/Caches/loom-v2/evidence/r9/d2x"), "evidence-root")

        // A scoped supervisor, as the app has it.
        let root = URL(fileURLWithPath: realPath(FileManager.default.temporaryDirectory), isDirectory: true)
            .appendingPathComponent("loom-d2x-real-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Not under the `/tmp` link: Codex 0.164 hashes the canonical socket path for its listener's link target.
        let sockets = URL(fileURLWithPath: "/private/tmp/lr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer {
            RunScopeLauncher.removeOwnedBundle(in: root)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sockets)
        }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let bundle = try RunScopeLauncher.assembleOwnedBundle(
            executable: RuntimeFixture.binaries.appendingPathComponent("loom-run-host"), in: root)
        let supervisor = try await ProcessSupervisor.restoring(
            ledgerURL: nil, catalog: catalog,
            scopeLauncher: RunScopeLauncher(hostBundle: bundle, socketDirectory: sockets.appendingPathComponent("rs")))
        var childEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": user]
        for key in ["USER", "LANG", "TMPDIR"] { childEnvironment[key] = env[key] }
        let environment = childEnvironment
        let resolver: ProviderToolchainResolver = { provider in
            ProviderToolchain(provider: provider, executable: executable,
                capabilities: ProviderCapabilities(version: "codex-cli", help: "--remote <ADDR>", serverHelp: "--listen <URL>"),
                environment: environment, profileDirectory: home, extraArguments: [])
        }
        let runtime = SessionRuntime(supervisor: supervisor, catalog: catalog, configuration: SessionRuntimeConfiguration(
            toolchains: resolver, hookHelperPath: RuntimeFixture.binaries.appendingPathComponent("loom-hook").path,
            socketDirectory: sockets, homeDirectory: work.path, codexIdentityTimeout: 20,
            claudeProfileDirectory: root.appendingPathComponent("unused-claude", isDirectory: true)))
        try await runtime.start()

        // The two synthetic sessions were made before, each by one recorded `codex exec` input in the work folder.
        let target = env["LOOM_D2X_TARGET"]!.lowercased(), control = env["LOOM_D2X_CONTROL"]!.lowercased()
        try requireReal(UUID(uuidString: target) != nil && UUID(uuidString: control) != nil && target != control, "ids")
        // `codex exec` names no thread, so neither has an index record yet: Codex's own `thread/name/set` (no model input)
        // gives each one, for the deletion to remove the target's and keep the control's.
        try await runtime.withCodexDeletionServer(card: UUID(), home: home) { client in
            for (id, name) in [(target, "d2x synthetic target"), (control, "d2x synthetic control")] {
                try await client.joinThread(id)   // the name needs a loaded thread; a resume takes no input
                _ = try await client.request(method: "thread/name/set",
                                             params: .object(["threadId": .string(id), "name": .string(name)]))
            }
        }

        func rollouts(_ id: String) -> [String] {
            CodexRolloutLocator.locate(sessionIDs: [id], home: home, maximumSeconds: 5).files.values.map(\.path)
        }
        func hash(_ name: String) -> String {
            guard let data = try? Data(contentsOf: home.appendingPathComponent(name)) else { return "absent" }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        func indexRecords(_ id: String) -> Int {
            ((try? CodexDataInventory.scan(nativeIDs: [id], home: home))?.indexRecords) ?? -1
        }
        func marker(_ id: String) -> Bool {
            FileManager.default.fileExists(atPath: home.appendingPathComponent("tui-thread-reference-capabilities/\(id)").path)
        }
        let before: [String: Any] = [
            "targetRollouts": rollouts(target).count, "controlRollouts": rollouts(control).count,
            "targetIndex": indexRecords(target), "controlIndex": indexRecords(control),
            "historySHA256": hash("history.jsonl"), "targetMarker": marker(target),
        ]
        let controlRollout = try rollouts(control).first.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }

        let targetSession = ManagedSession(provider: .codex, providerConversationID: target, workingDirectory: work.path)
        let controlSession = ManagedSession(provider: .codex, providerConversationID: control, workingDirectory: work.path)
        try await supervisor.createSession(targetSession, projectID: nil)
        try await supervisor.createSession(controlSession, projectID: nil)
        let preview = try await runtime.deletionPreview(id: targetSession.id)
        let scopesBefore = await supervisor.scopesOpened
        let outcome = try await runtime.deleteConversation(id: targetSession.id)

        // The native view after, on one more owned server.
        let native = try await runtime.withCodexDeletionServer(card: UUID(), home: home) { client in
            (try await client.threadExists(target), try await client.threadExists(control))
        }
        let after: [String: Any] = [
            "targetRollouts": rollouts(target).count, "controlRollouts": rollouts(control).count,
            "targetIndex": indexRecords(target), "controlIndex": indexRecords(control),
            "historySHA256": hash("history.jsonl"), "targetMarker": marker(target),
            "targetThreadResolves": native.0, "controlThreadResolves": native.1,
            "controlRolloutUnchanged": controlRollout == (try rollouts(control).first.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }),
        ]
        let servers = await runtime.codexServerState().servers
        let liveScopes = await supervisor.liveScopes.count
        let running = await supervisor.runningSessionIDs().count
        let deletionScopes = await supervisor.scopesOpened - scopesBefore
        let shutdown = await runtime.shutdown()
        let result: [String: Any] = [
            "target": target, "control": control,
            "preview": ["fileCount": preview.fileCount, "byteCount": preview.byteCount, "notRemoved": preview.notRemoved],
            "outcome": outcome == .deleted ? "deleted" : "\(outcome)",
            "targetRowGone": try await catalog.session(id: targetSession.id) == nil,
            "controlRowKept": try await catalog.session(id: controlSession.id) != nil,
            "before": before, "after": after,
            "deletionScopesOpened": deletionScopes, "codexServersLeft": servers, "liveScopesLeft": liveScopes,
            "runningLeft": running, "shutdownSucceeded": shutdown.succeeded,
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidence.appendingPathComponent("real-result.json"))

        #expect(outcome == .deleted)
        #expect(after["targetRollouts"] as? Int == 0 && after["targetIndex"] as? Int == 0 && native.0 == false)
        #expect(native.1 && after["controlRollouts"] as? Int == before["controlRollouts"] as? Int)
        #expect(after["controlIndex"] as? Int == before["controlIndex"] as? Int)
        #expect(after["historySHA256"] as? String == before["historySHA256"] as? String)
        #expect(servers == 0 && liveScopes == 0 && running == 0 && shutdown.succeeded)
    }
}
