import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

/// A Codex session in a mode that sandboxes it cannot reach Sphyrna's session channel. The helper says so when the
/// sandbox denies its connect, and a peer send to such a session is refused with the reason before anything is stored.
// serialized: each test runs the real helper or fake Claude and Codex CLIs against one runtime's task socket
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct SessionChannelSandboxIntegrationTests {
    private static func helper(_ arguments: [String], claim: SessionTaskClaim, socket: String, sandboxed: Bool,
                               codexMarker: Bool) async throws -> (status: Int32, error: String) {
        let process = Process(), errors = Pipe()
        let helper = RuntimeFixture.binaries.appendingPathComponent("loom-hook").path
        if sandboxed {
            // The seatbelt rule that matters in Codex's policy: no outbound network, Unix sockets included.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", "(version 1)(allow default)(deny network-outbound)", helper] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = arguments
        }
        var environment = ["SPHYRNA_TASK_SOCKET": socket, "SPHYRNA_TASK_TOKEN": claim.credential,
            "SPHYRNA_TASK_SESSION_ID": claim.sessionID.uuidString, "SPHYRNA_TASK_RUN_ID": claim.managedRunID.uuidString,
            "SPHYRNA_TASK_GENERATION": claim.generation.uuidString]
        if codexMarker { environment["CODEX_SANDBOX_NETWORK_DISABLED"] = "1" }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        guard await childEnded(process, within: .seconds(8)) else {
            process.terminate(); _ = await childEnded(process, within: .seconds(1)); throw CancellationError()
        }
        return (process.terminationStatus, String(decoding: await readToEnd(errors.fileHandleForReading), as: UTF8.self))
    }

    @Test func aDeniedConnectNamesCodexsSandboxInsteadOfABareConnectionError() async throws {
        let context = try await SessionRuntimeRig.makeContext(claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let (launch, _) = try await SessionRuntimeRig.launchClaude(context)
            let claim = try #require(await context.runtime.taskRunPlans[launch.sessionID]?.claim)
            #expect(await SessionRuntimeRig.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let socket = try #require(await context.runtime.taskSocketPath)
            let open = try await Self.helper(["inbox", "--peek"], claim: claim, socket: socket, sandboxed: false, codexMarker: true)
            #expect(open.status == 0, "outside the sandbox the same helper reaches Sphyrna: \(open.error)")
            let message = context.root.appendingPathComponent("message.txt")
            try "a message".write(to: message, atomically: true, encoding: .utf8)
            for command in [["inbox"], ["send", UUID().uuidString, "--message-file", message.path],
                            ["task", "read", "--task", UUID().uuidString]] {
                let denied = try await Self.helper(command, claim: claim, socket: socket, sandboxed: true, codexMarker: true)
                #expect(denied.status == 3)
                #expect(denied.error.contains("error: \(SessionChannelSandbox.codexReason);"), "\(command): \(denied.error)")
            }
            let other = try await Self.helper(["inbox"], claim: claim, socket: socket, sandboxed: true, codexMarker: false)
            #expect(other.status == 3 && other.error.contains("A sandbox blocks Sphyrna's session channel"), "\(other.error)")
            #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        } catch { Issue.record("sandboxed helper fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aPeerSendToASandboxedCodexSessionIsRefusedBeforeAnythingIsStored() async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1"],
                                                                claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("sandboxed-target", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let sender = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
            let target = try await context.runtime.startConversation(provider: .codex, projectID: project.id)
            let claim = try #require(await context.runtime.taskRunPlans[sender.sessionID]?.claim)
            let targetClaim = try #require(await context.runtime.taskRunPlans[target.sessionID]?.claim)
            #expect(await SessionRuntimeRig.waitUntil(5) {
                let source = await context.runtime.authenticateTaskRun(claim)
                let destination = await context.runtime.authenticateTaskRun(targetClaim)
                return source != nil && destination != nil
            })
            var call = SessionTaskWireRequest(command: "peer-send", sessionID: claim.sessionID,
                runID: claim.managedRunID, generation: claim.generation, credential: claim.credential)
            let id = UUID()
            call.operationID = id; call.targetSessionID = target.sessionID; call.message = "never stored"
            let reply = await context.runtime.submitPeerSend(call)
            #expect(reply.status == "refused" && reply.detail == SessionChannelSandbox.codexReason, "\(reply)")
            #expect(await context.runtime.openRequestSnapshot().isEmpty, "no approval card")
            let mailbox = try #require(await context.runtime.peerMailbox)
            #expect(try await mailbox.record(id) == nil, "nothing was stored")
            #expect(try await context.runtime.sessionMailboxHasUnread(sessionID: target.sessionID) == false)
            #expect(try await context.runtime.stopConversation(sessionID: target.sessionID).succeeded)
            #expect(try await context.runtime.stopConversation(sessionID: sender.sessionID).succeeded)
        } catch { Issue.record("sandboxed target fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
