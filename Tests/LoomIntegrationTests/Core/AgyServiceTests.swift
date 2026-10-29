import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

@MainActor private final class AgyTestTerminal: TerminalFaceSinks {
    let screen = SessionRuntimeRig.Screen()
    var launches: [RuntimeLaunch] = []
    func newRunSink() -> TerminalRunSink? { TerminalRunSink(rows: 24, columns: 80, output: screen, handle: NSObject()) }
    func adopt(_ launch: RuntimeLaunch, into sink: TerminalRunSink) {
        launches.append(launch); screen.attach(launch.terminal)
    }
    func runFailedToStart(_ sink: TerminalRunSink) {}
    func reconcile() async {}
    func captureForStop(sessionID: UUID) -> UUID? { launches.last?.runID }
    func releaseStopCapture(run: UUID) {}
}

@MainActor @Suite(.serialized, .processHeavy, .timeLimit(.minutes(1)))
struct AgyServiceTests {
    @Test func draftAndResumeUseTheOwnedTerminalEvenWhenChatIsPreferred() async throws {
        let provider = try #require(ManagedSession.Provider(rawValue: "agy"))
        let context = try await SessionRuntimeRig.makeContext(scoped: true)
        defer { context.cleanup() }
        do {
            try FileManager.default.createDirectory(at: context.home.appendingPathComponent(".gemini/antigravity-cli"),
                                                    withIntermediateDirectories: true)
            let terminal = AgyTestTerminal()
            let service = SessionService(runtime: context.runtime, startableProviders: [provider], runsIn: .chat,
                                         terminal: terminal)
            var card: UUID?, refused = false, started: Bool?
            let draft = NewSessionLaunch(firstMessage: "service prompt", choices: .init(harness: .agy))
            let offered = service.startSession(projectID: nil, launch: draft,
                cardCreated: { card = $0 }, notStarted: { refused = true }, startResolved: { started = $0 })
            let task = try #require(offered)
            await task.value
            let id = try #require(card)
            #expect(!refused && started == true && terminal.launches.count == 1)
            #expect(await terminal.screen.contains("FAKE-AGY INPUT service prompt"))
            var observedNative: String?
            for _ in 0..<500 {
                observedNative = try await context.catalog.session(id: id)?.session.providerConversationID
                if observedNative != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let native = try #require(observedNative)
            var stopped = false
            let stopRequest = service.stop(sessionID: id, liveRunID: terminal.launches[0].runID) { stopped = $0.report.succeeded }
            let stop = try #require(stopRequest)
            await stop.value
            #expect(stopped)
            var shown: UUID?
            let resumeRequest = service.resume(sessionID: id, knownProvider: provider) { shown = $0 }
            let resume = try #require(resumeRequest)
            await resume.value
            #expect(shown == id && terminal.launches.count == 2)
            #expect(await terminal.screen.contains("FAKE-AGY RESUMED \(native.lowercased())"))
            let finalRequest = service.stop(sessionID: id, liveRunID: terminal.launches.last?.runID) { stopped = $0.report.succeeded }
            let finalStop = try #require(finalRequest)
            await finalStop.value
            #expect(stopped)
        } catch {
            _ = await context.runtime.shutdown()
            throw error
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
