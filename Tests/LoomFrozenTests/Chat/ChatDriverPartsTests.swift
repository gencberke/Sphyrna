import Darwin
import Foundation
import Synchronization
import Testing
import LoomCore
@testable import LoomChat
@testable import LoomChatTestRigs

// The Chat driver's parts without a process: the live model's stop rule and "Read now" re-keying, the background
// count, the queue's bounds and files, the stdout backlog.

private func lifecycle(_ uuid: String, _ state: String) -> StreamMessage {
    .commandLifecycle(CommandLifecycle(json: ["command_uuid": .string(uuid), "state": .string(state)])!)
}

private func nowCut(isError: Bool) -> StreamMessage {
    Fixture.message(Fixture.line([
        "type": "result", "subtype": "success", "is_error": .bool(isError), "result": "partial",
        "terminal_reason": "aborted_streaming", "queued_turn_count": 1, "session_id": "s1",
    ]))
}

private func interruptResult() -> StreamMessage {
    Fixture.message(Fixture.line([
        "type": "result", "subtype": "error_during_execution", "is_error": true,
        "terminal_reason": "aborted_streaming", "session_id": "s1",
    ]))
}

private extension TurnModel {
    var youStopped: Bool {
        entries.contains { if case .marker(.interrupted) = $0.body { true } else { false } }
    }

    func delivery(_ id: String) -> UserPrompt.Delivery? {
        guard case let .user(prompt) = entry(id: id)?.body else { return nil }
        return prompt.delivery
    }
}

struct ChatDriverPartsTests {
    // MARK: The stop rule

    /// Regression (V16 fix round): a `now` send that cuts a stream ends the turn with an aborted result, which S1 §0.9
    /// says can carry `is_error: true`. Only Loom's own interrupt makes it "You stopped", whatever `is_error` says.
    @Test(arguments: [true, false])
    func aNowCutIsNotYouStoppedWhateverItsErrorFlag(isError: Bool) {
        var model = TurnModel(source: .live)
        model.appendPendingUser(uuid: "u1", text: "hello")
        model.apply(nowCut(isError: isError))
        #expect(model.turns.last?.status == .succeeded)
        #expect(!model.youStopped)

        // The same result after Loom's interrupt is the user's stop.
        var stopped = TurnModel(source: .live)
        stopped.appendPendingUser(uuid: "u1", text: "hello")
        stopped.noteInterruptSent()
        stopped.apply(interruptResult())
        #expect(stopped.turns.last?.status == .interrupted)
        #expect(stopped.youStopped)
    }

    /// An Esc at the very end of a turn (or a "Deny and stop" that never went out) must not make the next turn's
    /// cut read "You stopped": every turn boundary forgets the interrupt.
    @Test func anInterruptDoesNotOutliveItsTurn() {
        var model = TurnModel(source: .live)
        model.appendPendingUser(uuid: "u1", text: "first")
        model.apply(Fixture.message(Fixture.result()))
        model.noteInterruptSent()
        // The interrupt reached an idle CLI: its own result has no turn and says nothing.
        model.apply(interruptResult())
        #expect(!model.entries.contains { if case .marker(.notice) = $0.body { true } else { false } })
        model.appendPendingUser(uuid: "u2", text: "second")
        model.apply(nowCut(isError: true))
        #expect(model.turns.last?.status == .succeeded)
        #expect(!model.youStopped)

        // Noted, then a new turn starts before any result: the new turn is not the one that was stopped.
        model.noteInterruptSent()
        model.appendPendingUser(uuid: "u3", text: "third")
        model.apply(nowCut(isError: true))
        #expect(!model.youStopped)

        // A "Deny and stop" whose answer could not be written.
        model.appendPendingUser(uuid: "u4", text: "fourth")
        model.noteInterruptSent()
        model.clearInterruptSent()
        model.apply(nowCut(isError: false))
        #expect(!model.youStopped)
    }

    // MARK: "Read now"

    /// The re-sent message keeps its row and its id, so the change is one updated row an incremental reader can
    /// apply; the CLI's records for the new uuid are the row's, the old uuid's are not.
    @Test func readNowKeepsTheRowAndItsIdAndIsOneUpdatedRow() {
        var model = TurnModel(source: .live)
        model.appendPendingUser(uuid: "old", text: "look now")
        model.apply(lifecycle("old", "queued"))
        #expect(model.delivery("old") == .queued)
        let delta = model.rekeyPendingUser(from: "old", to: "new")
        #expect(delta.inserted.isEmpty)
        #expect(delta.updated == ["old"])
        #expect(model.delivery("old") == .pending)
        #expect(model.sentUUID(ofRow: "old") == "new")
        #expect(model.rowID(forSent: "new") == "old")
        // A late record of the uuid that was taken back changes nothing.
        #expect(model.apply(lifecycle("old", "cancelled")).isEmpty)
        #expect(model.delivery("old") == .pending)
        // The new uuid's lifecycle and echo are the row's.
        #expect(model.apply(lifecycle("new", "started")).updated == ["old"])
        #expect(model.delivery("old") == .read)
        model.apply(Fixture.message(Fixture.echo("look now", uuid: "new")))
        #expect(model.entries.filter { if case .user = $0.body { true } else { false } }.count == 1)
        #expect(model.entry(id: "new") == nil)
        #expect(model.pendingUserMessageIDs.isEmpty)
    }

    // MARK: Background work

    @Test func backgroundWorkFollowsTheStreamsTaskRecords() {
        var tasks = ChatBackgroundTasks()
        func applied(_ message: StreamMessage) -> Bool { tasks.apply(message) }
        func system(_ subtype: String, _ fields: [String: JSONValue]) -> StreamMessage {
            var object = fields
            object["type"] = "system"
            object["subtype"] = .string(subtype)
            return Fixture.message(Fixture.line(.object(object)))
        }
        // A foreground Bash announcing itself is not background work.
        #expect(!applied(system("task_started", ["task_id": "b1", "task_type": "local_bash", "is_backgrounded": false])))
        // S1 t07-priority-now: moved to the background.
        #expect(applied(system("background_tasks_changed", ["tasks": [["task_id": "b1", "task_type": "local_bash"]]])))
        #expect(!applied(system("task_updated", ["task_id": "b1", "patch": ["is_backgrounded": true]])))
        #expect(tasks.count == 1)
        // A background subagent.
        #expect(applied(system("task_started", ["task_id": "a1", "task_type": "local_agent", "is_backgrounded": true])))
        #expect(tasks.count == 2)
        #expect(applied(system("task_updated", ["task_id": "b1", "patch": ["status": "completed", "end_time": 1]])))
        #expect(applied(system("task_notification", ["task_id": "a1", "status": "completed"])))
        #expect(tasks.count == 0)
        // Replace semantics.
        #expect(applied(system("background_tasks_changed", ["tasks": [["task_id": "x"], ["task_id": "y"]]])))
        #expect(applied(system("background_tasks_changed", ["tasks": []])))
        #expect(tasks.count == 0)
    }

    // MARK: Queue files

    @Test func theQueueIsBoundedByItemsAndBytes() {
        var queue = ChatQueue()
        for i in 0..<ChatQueue.maximumItems { queue.items.append(ChatQueue.Item(text: "item \(i)")) }
        #expect(!queue.admits("one more"))
        queue.items.removeLast()
        #expect(queue.admits("one more"))
        let big = String(repeating: "x", count: ChatQueue.maximumBytes)
        #expect(!queue.admits(big))
        // An edit is measured in place of the item it replaces.
        let small = ChatQueue(items: [ChatQueue.Item(id: "a", text: String(repeating: "y", count: ChatQueue.maximumBytes - 10))])
        #expect(small.admits(String(repeating: "z", count: ChatQueue.maximumBytes - 5), replacing: "a"))
        #expect(!small.admits("0123456789A"))
    }

    @Test func anUnreadableQueueFileIsSetAsideNotOverwrittenAndADeletedSessionLosesItsFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loom-queue-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatQueueStore(directory: directory)
        let id = UUID()
        #expect(try store.load(sessionID: id).isEmpty)
        try store.save(ChatQueue(items: [ChatQueue.Item(text: "kept")]), sessionID: id)
        #expect(try store.load(sessionID: id).items.map(\.text) == ["kept"])
        try Data("{not a queue".utf8).write(to: store.url(for: id))
        var keptAs: String?
        do {
            _ = try store.load(sessionID: id)
            Issue.record("an unreadable file must throw")
        } catch let ChatQueueStoreError.unreadable(name) {
            keptAs = name
        }
        let aside = try #require(keptAs)
        #expect(String(decoding: try Data(contentsOf: directory.appendingPathComponent(aside)), as: UTF8.self) == "{not a queue")
        #expect(!FileManager.default.fileExists(atPath: store.url(for: id).path))
        #expect(store.sessionIDs() == [id])
        // Deleting the session removes its queue and what was set aside.
        try store.save(ChatQueue(items: [ChatQueue.Item(text: "new")]), sessionID: id)
        try store.forget(sessionID: id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        try store.forget(sessionID: id)
    }

    // MARK: Stdout backlog

    /// The driver's backlog is bounded: past the limit the read waits (the child's pipe fills) until the driver
    /// takes what it was given. Nothing is dropped.
    @Test func theStdoutBacklogIsBoundedAndNothingIsDropped() async throws {
        let sink = ChatPipeSink(maximumBacklog: 1_000)
        let line = Data((Fixture.result() + "\n").utf8)
        #expect(line.count > 100)
        let fed = FedCount()
        let feeder = Thread {
            for _ in 0..<40 {
                sink.receive(line, from: .standardOutput)
                fed.value.withLock { $0 += 1 }
            }
            sink.ended(.standardOutput)
        }
        feeder.start()
        try await Task.sleep(for: .milliseconds(300))
        let blocked = fed.value.withLock { $0 }
        #expect(blocked < 40)
        #expect(sink.pendingBytes >= 1_000)
        var frames = 0
        for await input in sink.inputs {
            guard case let .frames(got, _, bytes) = input else { break }
            frames += got.count
            sink.taken(bytes)
        }
        #expect(frames == 40)
        #expect(fed.value.withLock { $0 } == 40)
        #expect(sink.pendingBytes == 0)
    }

    @Test func stderrGivesItsFirstLineClipped() {
        let sink = ChatPipeSink()
        sink.receive(Data("\n  Error: no such flag --foo\nUsage: claude …\n".utf8), from: .standardError)
        #expect(sink.standardErrorFirstLine == "Error: no such flag --foo")
        let long = ChatPipeSink()
        long.receive(Data(String(repeating: "e", count: 500).utf8), from: .standardError)
        #expect(long.standardErrorFirstLine?.count == 301)
    }
}

private final class FedCount: Sendable {
    let value = Mutex(0)
}
