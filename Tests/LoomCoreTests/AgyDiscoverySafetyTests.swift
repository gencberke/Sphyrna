import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(1)))
struct AgyDiscoverySafetyTests {
    @Test func cleanupPreservesAModifiedDiscoveryFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agy-cleanup-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try AgySessionDiscovery.install(in: root, helper: URL(fileURLWithPath: "/usr/bin/true"))
        let witness = try #require(AgyDiscoveryWitness.capture(root: root))
        let hook = root.appendingPathComponent(".agents/hooks.json")
        let original = try Data(contentsOf: hook)
        let changed = Data("synthetic modification".utf8)
        try changed.write(to: hook)
        #expect(!witness.remove())
        #expect(try Data(contentsOf: hook) == changed)
        try original.write(to: hook)
        #expect(witness.remove())
    }

    @Test func stopPreservesUnexpectedFilesInTheAddedWorkspaceRoot() async throws {
        let provider = try #require(ManagedSession.Provider(rawValue: "agy"))
        let context = try await SessionRuntimeTests.makeContext(scoped: true)
        defer { context.cleanup() }
        do {
            try FileManager.default.createDirectory(at: context.home.appendingPathComponent(".gemini/antigravity-cli"),
                                                    withIntermediateDirectories: true)
            let screen = SessionRuntimeTests.Screen()
            let launch = try await context.runtime.startConversation(provider: provider, projectID: nil, outputSink: screen)
            screen.attach(launch.terminal)
            #expect(await screen.contains("FAKE-AGY STARTED"))
            #expect(try await SessionRuntimeTests.waitUntil {
                try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID != nil
            })
            let state = try #require(await context.runtime.agyRuns[launch.runID])
            let unexpected = state.discovery.appendingPathComponent("not-owned.txt")
            try Data("keep this synthetic file".utf8).write(to: unexpected)
            let report = try await context.runtime.stopConversation(sessionID: launch.sessionID)
            #expect(!report.succeeded)
            #expect((try? Data(contentsOf: unexpected)) == Data("keep this synthetic file".utf8))
            if !report.succeeded {
                await #expect(throws: SessionRuntimeError.unverifiedStop(launch.sessionID)) {
                    _ = try await context.runtime.resumeConversation(sessionID: launch.sessionID)
                }
            }
            // Only this test-created file is removed; the runtime retries its own cleanup.
            if FileManager.default.fileExists(atPath: unexpected.path) { try FileManager.default.removeItem(at: unexpected) }
            #expect(await context.runtime.finishAgyRun(launch.runID).isEmpty)
        } catch {
            _ = await context.runtime.shutdown()
            throw error
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
