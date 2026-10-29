import Foundation
import Testing
@testable import LoomCore

private final class AgyEventCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(1)))
struct AgyHookPeerTests {
    @Test func sameUserWithCorrectTokenOutsideTheOwnedRunCannotSendHooks() async throws {
        let context = try await SessionRuntimeTests.makeContext(scoped: true)
        defer { context.cleanup() }
        let scope = try await context.supervisor.openScope()
        let sessionID = UUID(), runID = UUID(), native = UUID()
        let ingress = AgyHookIngress(supervisor: context.supervisor, runID: runID)
        let socket = context.socketDirectory.appendingPathComponent("agy-peer-test.sock").path
        let token = UUID().uuidString
        let server = try AgyHookServer(path: socket, token: token, sessionID: sessionID, runID: runID,
            scope: scope, helperPath: RuntimeFixture.binaries.appendingPathComponent("loom-hook").path, ingress: ingress)
        let observed = AgyEventCount()
        let reader = Task { for await _ in ingress.stream { observed.add() } }
        let event = AgyHookEvent(kind: .sessionStart, conversationID: native, workspacePaths: ["/tmp/work"],
            transcriptPath: "/tmp/profile/transcript.jsonl", artifactDirectoryPath: "/tmp/profile",
            modelName: nil, invocationNum: nil, initialNumSteps: nil, executionNum: nil,
            terminationReason: nil, fullyIdle: nil)
        let wire = try JSONEncoder().encode(AgyHookWire(token: token, sessionID: sessionID, runID: runID, event: event))
        // The test process is the same user and knows the exact token, but is
        // outside the synthetic run host's coalition.
        do {
            let answer = try OpenSessionClient.roundTrip(raw: wire, socketPath: socket, connectTimeout: 1, replyTimeout: 1)
            #expect(answer.isEmpty)
            try await Task.sleep(for: .milliseconds(100))
            #expect(observed.value == 0)
        } catch {
            ingress.finish(); _ = await server.stopAndWait(); _ = await reader.value
            _ = await context.supervisor.releaseScope(scope); _ = await context.runtime.shutdown()
            throw error
        }
        ingress.finish()
        #expect(await server.stopAndWait())
        _ = await reader.value
        #expect(await context.supervisor.releaseScope(scope).isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
