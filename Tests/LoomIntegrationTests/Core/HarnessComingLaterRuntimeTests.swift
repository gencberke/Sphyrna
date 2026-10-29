import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

/// D-120: opencode and agy are coming later. The runtime's start and resume guards refuse them with the reason before any
/// card, branch or process exists, whoever asks (a stored draft, a plain start, a resume of a stored session), and the
/// session service does not even offer the start.
@Suite(.processHeavy, .timeLimit(.minutes(1)))
struct HarnessComingLaterRuntimeTests {
    static func reason(_ name: String) -> String {
        "\(name) is coming later: this version of Sphyrna cannot start its sessions"
    }

    @Test func startsAndResumesOfAFrozenHarnessAreRefusedWithTheReason() async throws {
        let agy = try #require(ManagedSession.Provider(rawValue: "agy"))
        let context = try await SessionRuntimeRig.makeContext(scoped: true)
        defer { context.cleanup() }
        do {
            try FileManager.default.createDirectory(at: context.home.appendingPathComponent(".gemini/antigravity-cli"),
                                                    withIntermediateDirectories: true)
            let before = try await context.catalog.sessions().count
            func refused(_ expected: String, _ start: () async throws -> RuntimeLaunch) async {
                do {
                    _ = try await start()
                    Issue.record("started, expected: \(expected)")
                } catch {
                    #expect(String(describing: error) == expected)
                }
            }
            // A stored draft for agy, a plain agy start, and a draft whose choices name opencode.
            await refused(Self.reason("agy")) {
                try await context.runtime.startConversation(provider: agy, projectID: nil, outputSink: SessionRuntimeRig.Screen(),
                    draft: NewSessionLaunch(firstMessage: "do not start", choices: .init(harness: .agy)))
            }
            await refused(Self.reason("agy")) {
                try await context.runtime.startConversation(provider: agy, projectID: nil, outputSink: SessionRuntimeRig.Screen())
            }
            await refused(Self.reason("opencode")) {
                try await context.runtime.startConversation(provider: .claude, projectID: nil, outputSink: SessionRuntimeRig.Screen(),
                    draft: NewSessionLaunch(firstMessage: "do not start", choices: .init(harness: .opencode)))
            }
            #expect(try await context.catalog.sessions().count == before, "no card for a refused start")

            // A stored agy session still lists, and its resume is refused with the same reason.
            let stored = ManagedSession(provider: agy, providerConversationID: UUID().uuidString.lowercased(),
                                        workingDirectory: context.home.path)
            try await context.supervisor.createSession(stored)
            #expect(try await context.catalog.session(id: stored.id) != nil)
            await refused(Self.reason("agy")) {
                try await context.runtime.resumeConversation(sessionID: stored.id, outputSink: SessionRuntimeRig.Screen())
            }

            // The service, even in a build that lists agy as startable, offers no start.
            let offered = await MainActor.run {
                let service = SessionService(runtime: context.runtime, startableProviders: [agy, .claude])
                return service.startSession(projectID: nil, launch: NewSessionLaunch(firstMessage: "x", choices: .init(harness: .agy)),
                                            cardCreated: { _ in }, notStarted: {}) != nil
            }
            #expect(!offered)
        } catch {
            _ = await context.runtime.shutdown()
            throw error
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
