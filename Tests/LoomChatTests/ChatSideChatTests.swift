import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing
@testable import LoomChat
@testable import LoomCore

// The side chat's fork on the fake provider, through the real runtime and the host (V22 part 2): one card for a fork, the
// request policy at the card's door, the guards of a side chat, and a discard that leaves the parent as it was. The fork's
// messages start with `~scenario` (the fake's alias of `/scenario`): a side chat sends no text that starts with a slash.

private func transcript(named conversation: String, under root: URL) -> URL? {
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
        if url.lastPathComponent == "\(conversation).jsonl" { return url }
    }
    return nil
}

private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

private func records(_ snapshot: ChatDriverSnapshot) -> [String] {
    snapshot.model.entries.compactMap { if case let .request(record) = $0.body { record.summary } else { nil } }
}

private final class MoveCount: Sendable {
    let count = Mutex(0)
}

/// A latch a test opens to let a parked task go on.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(5)))
struct ChatSideChatTests {
    /// A parent that has answered once, and the host that forks it.
    private func parent(_ rig: Rig, moves: MoveCount = MoveCount()) async throws
        -> (host: ChatSessionHost, id: UUID, conversation: String, driver: ChatSessionDriver) {
        let host = await MainActor.run {
            ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root, driversChanged: { moves.count.withLock { $0 += 1 } })
        }
        let id = UUID()
        let driver = try await host.startNewSession(projectID: nil, sessionID: id, draft: NewSessionLaunch(firstMessage: "hello"))
        #expect(await idle(driver))
        let conversation = try #require(await rig.supervisor.session(id: id)?.providerConversationID)
        return (host, id, conversation, driver)
    }

    private func waiting(_ driver: ChatSessionDriver, _ count: Int = 1) async -> Bool {
        await waitUntil {
            let snapshot = await driver.snapshot()
            return snapshot.requests.count == count && snapshot.phase == .needsYou
        }
    }

    @Test func aForkIsOneCardHiddenFromEveryListAndLeavesTheParentAsItWas() async throws {
        let rig = try await Rig.make()
        let moves = MoveCount()
        let (host, parentID, parentConversation, parentDriver) = try await parent(rig, moves: moves)
        let file = try #require(transcript(named: parentConversation, under: rig.profile))
        let before = try sha256(file)

        let side = try await host.startSideChat(parentSessionID: parentID)
        let sideID = await side.sessionID
        // One card for the fork, hidden: the listed sessions are the parent alone, and the one hidden row is the fork's.
        #expect(try await rig.catalog.sessions().map(\.session.id) == [parentID])
        let rows = try await rig.catalog.sideChats(of: parentID)
        #expect(rows.map(\.session.id) == [sideID])
        let forkConversation = try #require(rows.first?.session.providerConversationID)
        #expect(forkConversation != parentConversation)
        // The fork's SessionStart hook (source `fork`) found its card by the stored id and made no second one.
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await rig.catalog.sessions().map(\.session.id) == [parentID])
        #expect(try await rig.catalog.sideChats(of: parentID).count == 1)
        #expect(await rig.supervisor.session(id: parentID)?.providerConversationID == parentConversation)
        #expect(await rig.supervisor.session(id: sideID)?.providerConversationID == forkConversation)
        // The fork's file starts with a copy of the parent's records.
        let forkFile = try #require(transcript(named: forkConversation, under: rig.profile))
        #expect(try String(contentsOf: forkFile, encoding: .utf8).contains("hello"))
        // The parent kept its own run and state, and no driver moved to another card (`followMove`, `driversChanged`).
        #expect(await parentDriver.snapshot().isIdle)
        #expect(moves.count.withLock { $0 } == 0)
        #expect(await parentDriver.sessionID == parentID)

        // Discard: the fork's process, file and card go; the parent's file is byte for byte what it was.
        #expect(try await host.discardSideChat(id: sideID) == .deleted)
        #expect(try await rig.catalog.sideChats(of: parentID).isEmpty)
        #expect(try await rig.catalog.session(id: sideID) == nil)
        #expect(transcript(named: forkConversation, under: rig.profile) == nil)
        #expect(try sha256(file) == before)
        #expect(try await rig.catalog.sessions().map(\.session.id) == [parentID])
        await rig.finish()
    }

    @Test func theSideChatPolicyAnswersAtTheDoorAndOnlyAllowedEditsBecomeACard() async throws {
        let titles = FileManager.default.temporaryDirectory.appendingPathComponent("loom-titles-\(UUID()).log")
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_TITLE_LOG": titles.path])
        defer { try? FileManager.default.removeItem(at: titles) }
        let (host, parentID, _, _) = try await parent(rig)
        let titleLines = { (try? String(contentsOf: titles, encoding: .utf8))?.split(separator: "\n").count ?? 0 }
        let atStart = titleLines()
        let side = try await host.startSideChat(parentSessionID: parentID)
        let sideID = await side.sessionID
        #expect(await side.sideChatState()?.allowsEdits == false)

        // A Write is refused: no card, no request in the hub, one line in the stream, and the turn goes on to its end.
        try await side.send("~scenario approval write")
        #expect(await idle(side))
        var snapshot = await side.snapshot()
        #expect(snapshot.requests.isEmpty)
        #expect(await rig.events.snapshot().sessions[sideID]?.pendingRequests.isEmpty == true)
        #expect(records(snapshot).count == 1 && records(snapshot).first?.hasPrefix("Refused Write") == true, "\(records(snapshot))")
        #expect(snapshot.texts.last == "Understood, I did not do it.")
        // The text the policy gave is the tool's result: it reached the CLI, and the model reads it.
        let outputs = snapshot.model.entries.compactMap { entry -> String? in
            if case let .tool(call) = entry.body { call.output?.head } else { nil }
        }
        #expect(outputs.contains { $0.contains(SideChatPolicy.editsRefused) }, "\(outputs)")
        #expect(await side.sideChatState()?.refusedCount == 1)
        // The first question went to the card: its title is the line, the fork's first message is recorded, and Claude was never
        // asked to title the fork.
        let card = try #require(try await rig.catalog.session(id: sideID))
        #expect(card.title == "~scenario approval write")
        #expect(card.sideChat?.firstUUID != nil)
        #expect(titleLines() == atStart)

        // A Bash that writes is refused whatever its shape; one that provably reads is allowed without a card.
        try await side.send("~scenario approval redirect")
        #expect(await idle(side))
        try await side.send("~scenario approval")
        #expect(await idle(side))
        #expect(await side.sideChatState()?.refusedCount == 3)
        try await side.send("~scenario run cut -c1-3 notes.txt")
        #expect(await idle(side))
        snapshot = await side.snapshot()
        #expect(snapshot.requests.isEmpty)
        #expect(await side.sideChatState()?.allowedCount == 1)
        #expect(snapshot.texts.last?.contains("ran the command") == true, "\(snapshot.texts.last ?? "")")

        // Other tools ask as in a main session, and "for this session" is not offered.
        try await side.send("~scenario approval web")
        #expect(await waiting(side))
        let web = try #require(await side.snapshot().requests.first)
        await #expect(throws: ChatDriverError.notOffered) { try await side.answer(requestID: web.requestID, .allowForSession) }
        try await side.answer(requestID: web.requestID, .deny(note: "no"))
        #expect(await idle(side))

        // Allow edits: the same Write is now a card, and an allowed answer runs it; off again, it is refused.
        await side.setAllowsEdits(true)
        #expect(await side.sideChatState()?.allowsEdits == true)
        try await side.send("~scenario approval write")
        #expect(await waiting(side))
        let write = try #require(await side.snapshot().requests.first)
        try await side.answer(requestID: write.requestID, .allowOnce)
        #expect(await idle(side))
        await side.setAllowsEdits(false)
        try await side.send("~scenario approval write")
        #expect(await idle(side))
        #expect(await side.sideChatState()?.refusedCount == 4)
        #expect(titleLines() == atStart)

        // The listed sessions are still the parent's alone, and the summary shows the fork with its first question.
        #expect(try await rig.catalog.sessions().map(\.session.id) == [parentID])
        let listed = try await rig.catalog.sideChats(of: parentID)
        #expect(listed.map(\.session.id) == [sideID] && listed.first?.title == "~scenario approval write")
        #expect(listed.first?.sideChat?.parentSessionID == parentID)
        #expect(try await host.discardSideChat(id: sideID) == .deleted)
        await rig.finish()
    }

    @Test func everyRunOfASideChatStartsWithEditsOffHoweverTheLastOneEnded() async throws {
        let rig = try await Rig.make()
        let (host, parentID, _, _) = try await parent(rig)
        let side = try await host.startSideChat(parentSessionID: parentID)
        let sideID = await side.sessionID
        try await side.send("hello")
        #expect(await idle(side))
        await side.setAllowsEdits(true)
        #expect(await side.sideChatState()?.allowsEdits == true)
        // The run ends by the driver's own stop, not the tab's Close (which turns the toggle off itself), then resumes.
        _ = try await side.stop()
        #expect(await waitUntil { await side.currentPhase == .stopped })
        try await side.resume()
        #expect(await side.sideChatState()?.allowsEdits == false, "the permission was the last process's")
        try await side.send("~scenario approval write")
        #expect(await idle(side))
        #expect(await side.snapshot().requests.isEmpty, "refused, not asked")
        #expect(await side.sideChatState()?.refusedCount == 1)
        #expect(try await host.discardSideChat(id: sideID) == .deleted)
        await rig.finish()
    }

    /// The fork can run its first turn to the end while the first send still waits (on the card's write of the first question,
    /// `recordSideChatFirstSend`): that send then begins no turn of its own, and the side chat is idle with its answer. Before,
    /// it began a turn that never ended, and the side chat stayed Working.
    @Test func aTurnThatEndsWhileItsSendStillWaitsLeavesTheSideChatIdle() async throws {
        let rig = try await Rig.make()
        let (host, parentID, _, _) = try await parent(rig)
        let side = try await host.startSideChat(parentSessionID: parentID)
        let sideID = await side.sessionID
        // The send waits, its message gone to the CLI, until the fork has answered and its turn has ended.
        await side.setSendParked { delivered in
            guard delivered else { return }
            _ = await waitUntil { let snapshot = await side.snapshot(); return !snapshot.texts.isEmpty && snapshot.isIdle }
        }
        try await side.send("What is this?")
        let snapshot = await side.snapshot()
        #expect(snapshot.texts == ["Fake answer to: What is this?"])
        #expect(snapshot.phase == .ready && !snapshot.turnRunning, "\(snapshot.phase), turn running: \(snapshot.turnRunning)")
        // The next question is an ordinary turn.
        await side.setSendParked(nil)
        try await side.send("And this?")
        #expect(await idle(side))
        #expect(await side.snapshot().texts.last == "Fake answer to: And this?")
        #expect(try await host.discardSideChat(id: sideID) == .deleted)
        await rig.finish()
    }

    /// A side chat with a message on its way is not settled: the message's row is in the model before its turn begins, and a
    /// side chat retired in that moment (`CatalogModel.retireSideChat`) was stopped under its question instead of once its turn
    /// ended.
    @Test func aSideChatWithAMessageOnItsWayIsNotSettled() async throws {
        let rig = try await Rig.make()
        let (host, parentID, _, _) = try await parent(rig)
        let side = try await host.startSideChat(parentSessionID: parentID)
        let sideID = await side.sessionID
        #expect(await side.isLiveAndSettled)
        let reached = Gate(), parked = Gate()
        await side.setSendParked { delivered in
            guard !delivered else { return }
            await reached.open()
            await parked.wait()
        }
        let send = Task { try await side.send("What is this?") }
        await reached.wait()
        #expect(await side.snapshot().isIdle, "ready, and no turn runs yet")
        #expect(await side.isLiveAndSettled == false)
        await parked.open()
        try await send.value
        #expect(await idle(side))
        #expect(await side.isLiveAndSettled)
        #expect(try await host.discardSideChat(id: sideID) == .deleted)
        await rig.finish()
    }

    @Test func aSideChatRefusesWhatOnlyAMainSessionDoes() async throws {
        let rig = try await Rig.make()
        let (host, parentID, _, _) = try await parent(rig)
        let side = try await host.startSideChat(parentSessionID: parentID)
        let sideID = await side.sessionID
        await #expect(throws: ChatDriverError.commandsRefused) { try await side.send("/clear") }
        await #expect(throws: ChatDriverError.commandsRefused) { try await side.send("  /compact") }
        await #expect(throws: ChatDriverError.notInSideChat) { try await side.setModel("opus") }
        await #expect(throws: ChatDriverError.notInSideChat) { try await side.setEffort("high") }
        await #expect(throws: ChatDriverError.notInSideChat) { try await side.handOverToTerminal() }
        await #expect(throws: ChatDriverError.notInSideChat) { try await side.setPermissionMode("acceptEdits") }
        // Nothing of it reached the card's choices, and a main session's driver is none of this.
        #expect(await side.isSideChat)
        let parentDriver = await host.driver(for: parentID)
        #expect(await parentDriver.sideChatState() == nil)
        await #expect(throws: ChatDriverError.notASideChat) { try await parentDriver.startFork() }
        // A fork of a side chat is refused by the runtime.
        await #expect(throws: (any Error).self) { _ = try await host.startSideChat(parentSessionID: sideID) }
        #expect(try await rig.catalog.sideChats(of: sideID).isEmpty)
        #expect(try await host.discardSideChat(id: sideID) == .deleted)
        await rig.finish()
    }

    @Test func aForkThatCannotStartLeavesNothingBehind() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_INIT": "exit"])
        // The parent was made before the fake began to fail: a card with an identity, no run.
        let host = await MainActor.run { ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root) }
        let folder = rig.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let parent = ManagedSession(provider: .claude, providerConversationID: UUID().uuidString.lowercased(),
                                    workingDirectory: folder.path)
        try await rig.catalog.insertSession(parent, title: "Parent")
        await #expect(throws: (any Error).self) { _ = try await host.startSideChat(parentSessionID: parent.id) }
        #expect(try await rig.catalog.sideChats(of: parent.id, includingDeleting: true).isEmpty)
        #expect(try await rig.catalog.sessions().map(\.session.id) == [parent.id])
        await rig.finish()
    }
}
