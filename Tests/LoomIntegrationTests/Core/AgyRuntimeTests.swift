import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct AgyRuntimeTests {
    @Test func draftStartsOnceAndResumesTheSameNativeSessionWithoutInput() async throws {
        let provider = try #require(ManagedSession.Provider(rawValue: "agy"))
        let descriptor = try #require(HarnessCatalogue.descriptor(for: .agy))
        #expect(descriptor.startable)
        #expect(descriptor.provider == provider)
        let model = ModelCatalogEntry(harness: .agy, id: "fake-agy", title: "Fake AGY", efforts: ["low"])
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: [
            "LOOM_FAKE_AGY_CHILD": "1",
            "LOOM_FAKE_AGY_CHILD_EXECUTABLE": RuntimeFixture.binaries.appendingPathComponent("loom-test-child").path,
        ], scoped: true, openedModels: { _ in [model] })
        defer { context.cleanup() }
        do {
            let profile = context.home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            let folder = context.root.appendingPathComponent("agy-project", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let choices = HarnessLaunchChoices(harness: .agy, model: model.id, effort: "low", mode: .acceptEdits)
            let first = SessionRuntimeRig.Screen()
            let launch = try await context.runtime.startConversation(provider: provider, projectID: project.id,
                outputSink: first, draft: NewSessionLaunch(firstMessage: "owned initial prompt", choices: choices))
            first.attach(launch.terminal)
            #expect(await first.contains("FAKE-AGY INPUT owned initial prompt"))
            #expect(try await SessionRuntimeRig.waitUntil {
                try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID != nil
            })
            let native = try #require(try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID)
            #expect(UUID(uuidString: native) != nil)
            let old = try #require(await context.runtime.agyRuns[launch.runID])
            #expect(await SessionRuntimeRig.waitUntil {
                await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .turnComplete
            })
            #expect(await context.runtime.agyReportedModel(sessionID: launch.sessionID) == "fake-agy")
            let pids = context.state.appendingPathComponent("agy-child-pids.log")
            #expect(await SessionRuntimeRig.waitUntil { FileManager.default.fileExists(atPath: pids.path) }, "\(first.snapshot)")
            let child = try #require(Int32(try String(contentsOf: pids, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(ProcessTable.record(pid: child)?.zombie == false)
            #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
            #expect(await SessionRuntimeRig.waitUntil { ProcessTable.record(pid: child).map(\.zombie) ?? true })
            let second = SessionRuntimeRig.Screen()
            let resumed = try await context.runtime.resumeConversation(sessionID: launch.sessionID, outputSink: second)
            second.attach(resumed.terminal)
            #expect(await second.contains("FAKE-AGY RESUMED \(native.lowercased())"))
            #expect(try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID == native)
            #expect(await SessionRuntimeRig.waitUntil {
                await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .unknown
            })
            let staleRoot = old.profileRoot.appendingPathComponent("brain/\(native.lowercased())")
            let stale = AgyHookEvent(kind: .stop, conversationID: try #require(UUID(uuidString: native)),
                workspacePaths: [folder.path, old.discovery.path],
                transcriptPath: staleRoot.appendingPathComponent(".system_generated/logs/transcript.jsonl").path,
                artifactDirectoryPath: staleRoot.path, modelName: "fake-agy", invocationNum: nil, initialNumSteps: nil,
                executionNum: 0, terminationReason: "model_stop", fullyIdle: true)
            await context.runtime.receiveAgyHook(stale, runID: launch.runID)
            #expect(await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .unknown)
            let inputs = try String(contentsOf: context.state.appendingPathComponent("agy-inputs.log"), encoding: .utf8)
            #expect(inputs.split(separator: "\n").map(String.init) == ["owned initial prompt"])
            let log = try String(contentsOf: context.state.appendingPathComponent("agy-arguments.log"), encoding: .utf8)
            let calls = try log.split(separator: "\n").map { line in
                try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String])
            }
            #expect(calls.count == 2)
            if calls.count == 2 {
                #expect(calls[0].contains("-i") && calls[0].contains("owned initial prompt"))
                #expect(calls[0].contains("--model") && calls[0].contains("--effort") && calls[0].contains("--mode"))
                #expect(calls[1].contains("--conversation") && calls[1].contains(native.lowercased()))
                #expect(!calls[1].contains("-i") && !calls[1].contains("--model") && !calls[1].contains("--effort") && !calls[1].contains("--mode"))
                #expect(calls[0][1] != calls[1][1])
            }
            #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        } catch {
            _ = await context.runtime.shutdown()
            throw error
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func mismatchedWorkspaceCannotChangeStatusAndAnotherIdentityCannotRetargetTheRun() async throws {
        let provider = try #require(ManagedSession.Provider(rawValue: "agy"))
        let context = try await SessionRuntimeRig.makeContext(scoped: true)
        defer { context.cleanup() }
        do {
            try FileManager.default.createDirectory(at: context.home.appendingPathComponent(".gemini/antigravity-cli"),
                                                    withIntermediateDirectories: true)
            let screen = SessionRuntimeRig.Screen()
            let launch = try await context.runtime.startConversation(provider: provider, projectID: nil, outputSink: screen,
                draft: NewSessionLaunch(firstMessage: "one input", choices: .init(harness: .agy)))
            screen.attach(launch.terminal)
            #expect(await screen.contains("FAKE-AGY INPUT one input"))
            #expect(await SessionRuntimeRig.waitUntil {
                await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .turnComplete
            })
            let original = try #require(try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID)
            try await screen.send("/fake-tool")
            #expect(await screen.contains("FAKE-AGY TOOL-POLICY-PENDING"))
            #expect(await SessionRuntimeRig.waitUntil {
                await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .unknown
            })
            try await screen.send("/fake-error")
            #expect(await SessionRuntimeRig.waitUntil {
                await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .failed(nil)
            })
            try await screen.send("/fake-wrong-cwd")
            #expect(await screen.contains("FAKE-AGY WRONG-CWD SENT"))
            try await Task.sleep(for: .milliseconds(150))
            #expect(await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .failed(nil))
            try await screen.send("/fake-wrong-profile")
            #expect(await screen.contains("FAKE-AGY WRONG-PROFILE SENT"))
            try await Task.sleep(for: .milliseconds(150))
            #expect(await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .failed(nil))
            try await screen.send("/fake-foreign-id")
            #expect(await screen.contains("FAKE-AGY FOREIGN-ID SENT"))
            #expect(await SessionRuntimeRig.waitUntil {
                await context.supervisor.events.snapshot().sessions[launch.sessionID]?.identity == .ambiguous
            })
            #expect(await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .unknown)
            #expect(try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID == original)
            #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        } catch {
            _ = await context.runtime.shutdown()
            throw error
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
