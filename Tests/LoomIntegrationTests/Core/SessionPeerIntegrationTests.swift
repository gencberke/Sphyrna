import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

private struct PeerNullPipeSink: PipeOutputSink {
    func receive(_ data: Data, from stream: PipeStream) {}
    func ended(_ stream: PipeStream) {}
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct SessionPeerIntegrationTests {
    private enum FixtureError: Error { case timeout }

    private static func inbox(_ arguments: [String], claim: SessionTaskClaim, socket: String) async throws -> (Int32, String) {
        let process = Process(), output = Pipe()
        process.executableURL = RuntimeFixture.binaries.appendingPathComponent("loom-hook")
        process.arguments = ["inbox"] + arguments
        process.environment = ["SPHYRNA_TASK_SOCKET": socket, "SPHYRNA_TASK_TOKEN": claim.credential,
            "SPHYRNA_TASK_SESSION_ID": claim.sessionID.uuidString, "SPHYRNA_TASK_RUN_ID": claim.managedRunID.uuidString,
            "SPHYRNA_TASK_GENERATION": claim.generation.uuidString]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        guard await childEnded(process, within: .seconds(8)) else {
            process.terminate(); _ = await childEnded(process, within: .seconds(1)); throw FixtureError.timeout
        }
        return (process.terminationStatus, String(decoding: await readToEnd(output.fileHandleForReading), as: UTF8.self))
    }

    @Test func approvalDeliversOnlyAPointerAfterReadyAndInboxReadsOnce() async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1"],
                                                                claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("peer-flow", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let senderScreen = SessionRuntimeRig.Screen(), targetScreen = SessionRuntimeRig.Screen(), gate = context.runtime.inputGate
            let sender = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: senderScreen)
            senderScreen.attach(sender.terminal)
            let senderQueue = TerminalInputQueue(endpoint: sender.terminal, onError: { _ in })
            gate.register(runID: sender.runID, queue: senderQueue)
            let target = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: targetScreen)
            targetScreen.attach(target.terminal)
            let targetQueue = TerminalInputQueue(endpoint: target.terminal, onError: { _ in })
            gate.register(runID: target.runID, queue: targetQueue)
            let senderClaim = try #require(await context.runtime.taskRunPlans[sender.sessionID]?.claim)
            let targetClaim = try #require(await context.runtime.taskRunPlans[target.sessionID]?.claim)
            #expect(try await SessionRuntimeRig.waitUntil(3) {
                let source = await context.runtime.authenticateTaskRun(senderClaim)
                let destination = await context.runtime.authenticateTaskRun(targetClaim)
                return source != nil && destination != nil
            })
            let socket = try #require(await context.runtime.taskSocketPath)
            let marker = "approved-peer-content-\(UUID().uuidString)"
            let file = folder.appendingPathComponent("message.txt")
            try marker.write(to: file, atomically: true, encoding: .utf8)
            #expect(targetQueue.enqueue(Data("/work 2500\r".utf8)))
            #expect(await targetScreen.contains("WORKING 2500"))
            let operation = UUID()
            #expect(senderQueue.enqueue(Data("/fake-sphyrna-send \(target.sessionID.uuidString) \(operation.uuidString) \(file.path)\r".utf8)))
            #expect(try await SessionRuntimeRig.waitUntil(4) {
                await context.runtime.openRequestSnapshot().contains { $0.id == operation && $0.send?.targetSessionID == target.sessionID }
            })
            try await context.runtime.approvePeerSendRequest(operation)
            #expect(await senderScreen.contains("FAKE-PEER-SENT"))
            #expect(!targetScreen.snapshot.contains("Sphyrna: message"), "working targets never receive input")
            #expect(await targetScreen.contains("Sphyrna: message", timeout: 6))
            #expect(!targetScreen.snapshot.contains(marker), "only a pointer enters the target's context")
            let peek = try await Self.inbox(["--peek"], claim: targetClaim, socket: socket)
            #expect(peek.0 == 0 && peek.1.contains(marker))
            let first = try await Self.inbox([], claim: targetClaim, socket: socket)
            #expect(first.0 == 0 && first.1.contains(marker))
            let second = try await Self.inbox([], claim: targetClaim, socket: socket)
            #expect(second.0 == 0 && !second.1.contains(marker))
            #expect(try await context.runtime.stopConversation(sessionID: target.sessionID).succeeded)
            #expect(try await context.runtime.stopConversation(sessionID: sender.sessionID).succeeded)
        } catch { Issue.record("peer send fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func denialAndStoppedTargetNeverDeliverOrCreateAChild() async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1"],
                                                                claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("peer-decisions", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let sender = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
            let target = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
            let claim = try #require(await context.runtime.taskRunPlans[sender.sessionID]?.claim)
            let targetClaim = try #require(await context.runtime.taskRunPlans[target.sessionID]?.claim)
            #expect(try await SessionRuntimeRig.waitUntil(3) {
                let senderBinding = await context.runtime.authenticateTaskRun(claim)
                let targetBinding = await context.runtime.authenticateTaskRun(targetClaim)
                return senderBinding != nil && targetBinding != nil
            })
            @Sendable func call(_ id: UUID, _ body: String) -> SessionTaskWireRequest {
                var value = SessionTaskWireRequest(command: "peer-send", sessionID: claim.sessionID,
                    runID: claim.managedRunID, generation: claim.generation, credential: claim.credential)
                value.operationID = id; value.targetSessionID = target.sessionID; value.message = body
                return value
            }
            var forged = call(UUID(), "forged")
            forged.credential = "another-run-token"
            #expect(await context.runtime.submitPeerSend(forged).status == "refused")
            #expect(await context.runtime.openRequestSnapshot().isEmpty)
            let unsupported = ManagedSession(provider: .synthetic, providerConversationID: "synthetic-native",
                                             workingDirectory: folder.path)
            try await context.supervisor.createSession(unsupported, projectID: project.id)
            var unsupportedDraft = call(UUID(), "unsupported target")
            unsupportedDraft.targetSessionID = unsupported.id
            let unsupportedCall = unsupportedDraft
            let unsupportedReply = Task { await context.runtime.submitPeerSend(unsupportedCall) }
            let unsupportedOffered = await SessionRuntimeRig.waitUntil(1) {
                await context.runtime.openRequestSnapshot().contains { $0.id == unsupportedCall.operationID }
            }
            #expect(!unsupportedOffered, "a session without a registered harness cannot receive an approval")
            if unsupportedOffered, let id = unsupportedCall.operationID { try await context.runtime.denyOpenRequest(id) }
            #expect(await unsupportedReply.value.status == "refused")
            let deniedID = UUID(), denied = Task { await context.runtime.submitPeerSend(call(deniedID, "must stay private")) }
            #expect(try await SessionRuntimeRig.waitUntil(3) {
                await context.runtime.openRequestSnapshot().contains { $0.id == deniedID }
            })
            try await context.runtime.denyOpenRequest(deniedID)
            #expect(await denied.value.status == "denied")
            #expect(await context.runtime.submitPeerSend(call(deniedID, "different body")).status == "denied")
            #expect(try await context.runtime.sessionMailboxHasUnread(sessionID: target.sessionID) == false)

            let staleID = UUID(), stale = Task { await context.runtime.submitPeerSend(call(staleID, "do not redirect")) }
            #expect(try await SessionRuntimeRig.waitUntil(3) {
                await context.runtime.openRequestSnapshot().contains { $0.id == staleID }
            })
            #expect(try await context.runtime.stopConversation(sessionID: target.sessionID).succeeded)
            await #expect(throws: SessionTaskError.unauthorized) {
                try await context.runtime.approvePeerSendRequest(staleID)
            }
            #expect(await stale.value.status == "failed")
            #expect(try await context.runtime.sessionMailboxHasUnread(sessionID: target.sessionID) == false)
            #expect(try await context.catalog.sessions().count == 3, "a send never starts a child")
        } catch { Issue.record("peer decision fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }


    @Test func aStoppedTargetReceivesItsPendingPointerAfterItsSameNativeSessionResumes() async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1",
            "LOOM_FAKE_PEER_RESUME_DELAY": "1"], claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("peer-resume", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let sender = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
            let target = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
            let claim = try #require(await context.runtime.taskRunPlans[sender.sessionID]?.claim)
            let targetClaim = try #require(await context.runtime.taskRunPlans[target.sessionID]?.claim)
            #expect(await SessionRuntimeRig.waitUntil(3) {
                let a = await context.runtime.authenticateTaskRun(claim)
                let b = await context.runtime.authenticateTaskRun(targetClaim)
                return a != nil && b != nil
            })
            let original = try #require(await context.runtime.authenticateTaskRun(targetClaim)?.nativeSessionID)
            #expect(try await context.runtime.stopConversation(sessionID: target.sessionID).succeeded)
            var call = SessionTaskWireRequest(command: "peer-send", sessionID: claim.sessionID,
                runID: claim.managedRunID, generation: claim.generation, credential: claim.credential)
            let id = UUID(); call.operationID = id; call.targetSessionID = target.sessionID; call.message = "after resume"
            let reply = Task { await context.runtime.submitPeerSend(call) }
            #expect(await SessionRuntimeRig.waitUntil(3) {
                await context.runtime.openRequestSnapshot().contains { $0.id == id }
            })
            try await context.runtime.approvePeerSendRequest(id)
            #expect(await reply.value.status == "sent")
            let screen = SessionRuntimeRig.Screen()
            let resumed = try await context.runtime.resumeConversation(sessionID: target.sessionID, outputSink: screen)
            screen.attach(resumed.terminal)
            let queue = TerminalInputQueue(endpoint: resumed.terminal, onError: { _ in })
            context.runtime.inputGate.register(runID: resumed.runID, queue: queue)
            #expect(await screen.contains("Sphyrna: message", timeout: 4), "early attachment must not lose a pending delivery")
            let resumedClaim = try #require(await context.runtime.taskRunPlans[target.sessionID]?.claim)
            #expect(await context.runtime.authenticateTaskRun(resumedClaim)?.nativeSessionID == original)
        } catch { Issue.record("peer resume fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }


    @Test(arguments: [ManagedSession.Provider.claude, .codex])
    func aProviderDescendantSendsToTheOtherHarness(senderProvider: ManagedSession.Provider) async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1"],
                                                                claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("cross-peer", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let targetProvider: ManagedSession.Provider = senderProvider == .claude ? .codex : .claude
            let senderScreen = SessionRuntimeRig.Screen(), targetScreen = SessionRuntimeRig.Screen()
            let sender = try await context.runtime.startConversation(provider: senderProvider, projectID: project.id, outputSink: senderScreen)
            senderScreen.attach(sender.terminal)
            let target = try await context.runtime.startConversation(provider: targetProvider, projectID: project.id, outputSink: targetScreen)
            targetScreen.attach(target.terminal)
            let targetQueue = TerminalInputQueue(endpoint: target.terminal, onError: { _ in })
            context.runtime.inputGate.register(runID: target.runID, queue: targetQueue)
            let senderClaim = try #require(await context.runtime.taskRunPlans[sender.sessionID]?.claim)
            let targetClaim = try #require(await context.runtime.taskRunPlans[target.sessionID]?.claim)
            #expect(await SessionRuntimeRig.waitUntil(5) {
                let source = await context.runtime.authenticateTaskRun(senderClaim)
                let destination = await context.runtime.authenticateTaskRun(targetClaim)
                guard source != nil, let destination else { return false }
                return await context.runtime.taskNativeStatus(destination) == .ready
            })
            let socket = try #require(await context.runtime.taskSocketPath)
            let marker = "cross-peer-body-\(UUID().uuidString)"
            let file = folder.appendingPathComponent("message.txt")
            try marker.write(to: file, atomically: true, encoding: .utf8)
            let operation = UUID()
            try await senderScreen.send("/fake-sphyrna-send \(target.sessionID.uuidString) \(operation.uuidString) \(file.path)")
            guard await SessionRuntimeRig.waitUntil(5, { await context.runtime.openRequestSnapshot().contains { $0.id == operation } }) else {
                Issue.record("cross-provider send was not offered"); _ = await context.runtime.shutdown(); return
            }
            try await context.runtime.approvePeerSendRequest(operation)
            #expect(await senderScreen.contains("FAKE-PEER-SENT"))
            let pointerEvidence = targetProvider == .codex ? "FAKE-PEER-WAKE" : "Sphyrna: message"
            #expect(await targetScreen.contains(pointerEvidence, timeout: 6))
            #expect(!targetScreen.snapshot.contains(marker))
            let received = try await Self.inbox([], claim: targetClaim, socket: socket)
            #expect(received.0 == 0 && received.1.contains(marker))
            #expect(try await Self.inbox([], claim: targetClaim, socket: socket).1.contains(marker) == false)
            #expect(try await context.runtime.stopConversation(sessionID: target.sessionID).succeeded)
            #expect(try await context.runtime.stopConversation(sessionID: sender.sessionID).succeeded)
        } catch { Issue.record("cross-provider peer fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }


    @Test func ordinaryOpenAPIsCannotConsumeOrStartAQueuedPeerSend() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        for chat in [false, true] {
            let id = UUID(), target = UUID()
            let request = OpenSessionRequest(id: id, requesterID: UUID(), projectID: UUID(), projectName: "unused",
                title: "Target", message: "must not start", choices: HarnessLaunchChoices(harness: .claude),
                send: OpenSessionSendRequest(targetSessionID: target, targetTitle: "Target", targetHarness: .claude, operationID: id))
            let inserted = await context.runtime.openRequests.submitSend(request) { true }
            #expect(inserted)
            if chat {
                await #expect(throws: SessionTaskError.unauthorized) {
                    _ = try await context.runtime.approveOpenRequestInChat(id, outputSink: PeerNullPipeSink())
                }
            } else {
                await #expect(throws: SessionTaskError.unauthorized) {
                    _ = try await context.runtime.approveOpenRequest(id)
                }
            }
            #expect(await context.runtime.openRequestSnapshot().first { $0.id == id }?.phase == .waiting)
            try? await context.runtime.openRequests.dismiss(id)
        }
        #expect(try await context.catalog.sessions().isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

}
