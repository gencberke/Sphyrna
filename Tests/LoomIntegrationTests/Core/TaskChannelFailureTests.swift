import Darwin
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

/// The task channel's failures: a task socket whose cleanup fails (N4), a mailbox that does not open (N5), and a client
/// that never reads its reply (N8).
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2))) // serialized: a wall-clock bound on the reply deadline and a log read-back
struct TaskChannelFailureTests {
    /// The first Quit cannot verify the task socket's cleanup (its node was replaced); Try Again asks the same socket
    /// again and still reports the failure instead of a verified Quit.
    @Test func aRetriedQuitStillReportsATaskSocketCleanupFailure() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let path = try #require(await context.runtime.taskSocketPath)
        #expect(unlink(path) == 0)
        #expect(FileManager.default.createFile(atPath: path, contents: Data("not the socket".utf8)))
        defer { unlink(path) }
        let first = await context.runtime.shutdown()
        #expect(!first.succeeded)
        #expect(first.errors.contains { $0.contains("Task socket") }, "\(first.errors)")
        let retry = await context.runtime.shutdown()
        #expect(!retry.succeeded, "the retry reported a verified Quit with the socket node left behind")
        #expect(retry.errors.contains { $0.contains("Task socket") }, "\(retry.errors)")
    }

    /// The mailbox is held by another owner, so the runtime's does not open: an authenticated agent's send hears
    /// "unavailable", not a refusal, and the start logged one line naming the error's category and nothing else.
    @Test func aMailboxThatCannotOpenMakesSendUnavailableAndIsLoggedOnce() async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1"],
                                                                startRuntime: false, claudeVersion: "2.0.0")
        defer { context.cleanup() }
        let holder = try await SessionMailbox.open(
            url: context.root.appendingPathComponent("session-mailbox/mailbox.sqlite3"), exclusive: true)
        let since = Date()
        try await context.runtime.start()
        do {
            let sender = try await context.runtime.startConversation(provider: .claude, projectID: nil)
            let claim = try #require(await context.runtime.taskRunPlans[sender.sessionID]?.claim)
            #expect(await waitFor("the sender's task run to authenticate") {
                await context.runtime.authenticateTaskRun(claim) != nil
            }, "the sender's task run never authenticated")
            var call = SessionTaskWireRequest(command: "peer-send", sessionID: claim.sessionID,
                runID: claim.managedRunID, generation: claim.generation, credential: claim.credential)
            call.operationID = UUID(); call.targetSessionID = UUID(); call.message = "hello"
            let reply = await context.runtime.submitPeerSend(call)
            #expect(reply.status == "unavailable", "\(reply.status) \(reply.detail ?? "")")
            #expect(try await context.runtime.stopConversation(sessionID: sender.sessionID).succeeded)
        } catch { Issue.record("mailbox fixture failed: \(error)") }
        let lines = try await LogReadBack.lines(category: .lifecycle, since: since, containing: "Peer mailbox unavailable")
        #expect(lines.count == 1, "\(lines.map(\.message))")
        #expect(lines.allSatisfy { $0.message.contains("SessionTaskError") && !$0.message.contains("/") },
                "\(lines.map(\.message))")
        #expect((await context.runtime.shutdown()).succeeded)
        await holder.shutdown()
    }

    /// More clients than the cooperative pool has threads send a request and never read the 64 KiB reply. Each reply's
    /// write waits off the pool, so all of them give up together at the 2 s deadline (not in waves), and each client
    /// then holds less than the whole reply before the end of the stream.
    @Test func repliesToClientsThatNeverReadTimeOutTogetherOffTheCooperativePool() async throws {
        let reply = Data(repeating: UInt8(ascii: "a"), count: SessionTaskWireLimits.replyBytes)
        let folder = "/tmp/lts-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/t.sock"
        let socket = try SessionTaskSocket(path: path) { _ in reply }
        let count = ProcessInfo.processInfo.activeProcessorCount + 2
        var clients: [Int32] = []
        defer { for fd in clients { close(fd) } }
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<count {
            let fd = try LocalSocket.connect(path: path, timeout: 2)
            clients.append(fd)
            var size: Int32 = 2048
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            try LocalSocket.writeAll(Data(#"{"version":5}"#.utf8), to: fd, deadline: ProcessInfo.processInfo.systemUptime + 2)
            #expect(Darwin.shutdown(fd, SHUT_WR) == 0)
        }
        let waiting = clients
        // The server's close shows as a hang-up beside the unread bytes; nothing is read before it.
        let closed = await waitFor("every reply to give up", within: .seconds(8), observe: {
            waiting.filter { fd in
                var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                return poll(&item, 1, 0) == 1 && item.revents & Int16(POLLHUP) != 0
            }.count
        }, until: { $0 == count })
        let elapsed = clock.now - start
        #expect(closed == count)
        #expect(elapsed >= .seconds(1.5), "the replies gave up after \(elapsed), before their 2 s deadline")
        #expect(elapsed < .seconds(3), "\(count) replies that time out at 2 s each took \(elapsed): they queued for pool threads")
        for fd in clients {
            let received = try LocalSocket.readToEnd(from: fd, limit: reply.count,
                                                     deadline: ProcessInfo.processInfo.systemUptime + 2)
            #expect(received.count < reply.count, "a client that never read received the whole reply")
        }
        #expect(await socket.stopAndWait())
    }
}
