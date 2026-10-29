import Foundation
import Synchronization
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport
@testable import LoomChatTestRigs

// Rewind files (V21) on the driver, through the real runtime and the fake provider's checkpoints: the dry run, the idle rule,
// the copy that comes before the CLI call, the error frame, the marker, and Undo. The fake restores files the way S8 saw the
// CLI do it (only what its Write tool touched, to the state before the chosen message).

/// The paths the injected trash step was asked to take.
private final class TrashLog: Sendable {
    private let state = Mutex<[String]>([])
    func add(_ path: String) { state.withLock { $0.append(path) } }
    var paths: [String] { state.withLock { $0 } }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(5)))
struct ChatRewindDriverTests {
    private final class Bench: Sendable {
        let rig: Rig
        let store: ChatRewindStore
        let trashed: TrashLog
        let driver: ChatSessionDriver
        let id = UUID()

        /// - Parameter trashDelay: how long the trash step takes (an Undo that holds the session for a while).
        init(environment: [String: String] = [:], trashDelay: TimeInterval = 0) async throws {
            let rig = try await Rig.make(environment: environment)
            let log = TrashLog()
            let store = ChatRewindStore(directory: rig.root.appendingPathComponent("chat-rewinds", isDirectory: true), trash: { url in
                if trashDelay > 0 { Thread.sleep(forTimeInterval: trashDelay) }
                log.add(url.path)
                try FileManager.default.removeItem(at: url)
            })
            let driver = rig.driver(id, rewinds: store)
            try await driver.startNew(projectID: nil)
            try await driver.setPermissionMode("acceptEdits")
            self.rig = rig
            self.store = store
            trashed = log
            self.driver = driver
        }

        /// A message that makes the Write tool write `text` to `name` in the session's folder; the id the CLI knows it by.
        @discardableResult
        func write(_ name: String, _ text: String) async throws -> String {
            let sent = try await driver.send("/scenario file \(name) \(text)")
            #expect(await idle(driver))
            return sent.id
        }

        func finish() async { await rig.finish() }
    }

    private func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    private func names(_ paths: [String]) -> [String] { paths.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted() }

    // MARK: The dry run

    @Test func aPreviewListsTheFilesWithTheCliTotalsAndChangesNothing() async throws {
        let bench = try await Bench()
        let first = try await bench.write("a.txt", "one")
        let second = try await bench.write("a.txt", "two")

        let toSecond = try await bench.driver.rewindPreview(userMessageID: second)
        #expect(names(toSecond.files) == ["a.txt"] && toSecond.insertions == 1 && toSecond.deletions == 1)
        #expect(toSecond.canKeepCopy)
        // To before the first message the file did not exist: the rewind would delete its one line.
        let toFirst = try await bench.driver.rewindPreview(userMessageID: first)
        #expect(names(toFirst.files) == ["a.txt"] && toFirst.insertions == 0 && toFirst.deletions == 1)

        let path = try #require(toSecond.files.first)
        #expect(text(path) == "two")
        #expect(bench.store.rewindIDs(sessionID: bench.id).isEmpty)
        #expect(await bench.driver.snapshot().markers.allSatisfy { if case .rewound = $0 { false } else { true } })
        await bench.finish()
    }

    @Test func aMessageWithoutACheckpointAndARunWithoutTheSwitchCannotBeRewound() async throws {
        let bench = try await Bench()
        try await bench.write("a.txt", "one")
        for unknown in [UUID().uuidString.lowercased(), "not-a-message"] {
            await #expect(throws: ChatRewindError.cannot(.noCheckpoint)) { try await bench.driver.rewindPreview(userMessageID: unknown) }
            await #expect(throws: ChatRewindError.cannot(.noCheckpoint)) { try await bench.driver.rewindFiles(userMessageID: unknown) }
        }
        #expect(RewindCannot.noCheckpoint.text == "No file checkpoint for this message")
        #expect(bench.store.rewindIDs(sessionID: bench.id).isEmpty)
        await bench.finish()

        let off = try await Bench(environment: ["LOOM_FAKE_CHAT_CHECKPOINTS": "off"])
        let message = try await off.write("a.txt", "one")
        await #expect(throws: ChatRewindError.cannot(.notEnabled)) { try await off.driver.rewindPreview(userMessageID: message) }
        #expect(RewindCannot.notEnabled.text == "File rewinding is off for this run")
        await off.finish()
    }

    // MARK: The rule

    @Test func theIdleRuleRefusesWhileATurnRunsWhileARequestWaitsAndWhileStopped() async throws {
        let bench = try await Bench()
        let message = try await bench.write("a.txt", "one")
        let path = try #require(try await bench.driver.rewindPreview(userMessageID: message).files.first)
        #expect(await bench.driver.rewindAvailability() == .available)
        #expect(await bench.driver.composerState().rewind == .available)

        // A turn runs.
        try await bench.driver.send("/scenario work 3000")
        #expect(await waitUntil { await bench.driver.currentPhase == .working })
        #expect(await bench.driver.rewindAvailability() == .notIdle)
        await #expect(throws: ChatRewindError.notAvailable(.notIdle)) { try await bench.driver.rewindPreview(userMessageID: message) }
        await #expect(throws: ChatRewindError.notAvailable(.notIdle)) { try await bench.driver.rewindFiles(userMessageID: message) }
        await bench.driver.interrupt()
        #expect(await idle(bench.driver))

        // A request waits for the user.
        try await bench.driver.send("/scenario approval")
        #expect(await waitUntil { await bench.driver.currentPhase == .needsYou })
        await #expect(throws: ChatRewindError.notAvailable(.notIdle)) { try await bench.driver.rewindFiles(userMessageID: message) }
        let request = try #require(await bench.driver.snapshot().requests.first)
        try await bench.driver.answer(requestID: request.requestID, .deny(note: nil))
        #expect(await idle(bench.driver))

        // Nothing was copied and nothing was rewound by any of those refusals.
        #expect(bench.store.rewindIDs(sessionID: bench.id).isEmpty)
        #expect(text(path) == "one")

        // No process: the user resumes the session first; a rewind never does.
        _ = try await bench.driver.stop()
        #expect(await bench.driver.rewindAvailability() == .stopped)
        await #expect(throws: ChatRewindError.notAvailable(.stopped)) { try await bench.driver.rewindFiles(userMessageID: message) }
        await #expect(throws: ChatRewindError.notAvailable(.stopped)) { try await bench.driver.rewindPreview(userMessageID: message) }
        #expect(await bench.driver.currentPhase == .stopped)
        #expect(RewindAvailability.notIdle.reason == "Rewind works while the session waits for you")
        #expect(RewindAvailability.stopped.reason == "Resume the session to rewind its files")
        await bench.finish()
    }

    @Test func aPhaseChangeBetweenThePreviewAndTheConfirmRefusesTheRewind() async throws {
        let bench = try await Bench()
        try await bench.write("a.txt", "one")
        let second = try await bench.write("a.txt", "two")
        let preview = try await bench.driver.rewindPreview(userMessageID: second)
        let path = try #require(preview.files.first)

        // The sheet is open and a turn begins (a queued message, a background task, a send from elsewhere).
        try await bench.driver.send("/scenario work 3000")
        #expect(await waitUntil { await bench.driver.currentPhase == .working })
        await #expect(throws: ChatRewindError.notAvailable(.notIdle)) { try await bench.driver.rewindFiles(userMessageID: second) }
        #expect(text(path) == "two")
        #expect(bench.store.rewindIDs(sessionID: bench.id).isEmpty)
        await bench.driver.interrupt()
        #expect(await idle(bench.driver))
        await bench.finish()
    }

    // MARK: The copy comes first

    @Test func filesLoomCannotKeepACopyOfAreNeverRewoundBecauseTheCopyComesBeforeTheCliCall() async throws {
        let bench = try await Bench()
        try await bench.write("big.txt", "small")
        let second = try await bench.write("big.txt", "smaller")
        let preview = try await bench.driver.rewindPreview(userMessageID: second)
        let path = try #require(preview.files.first)
        // The user grows the file past the 64 MiB a copy may hold (sparse: the size is real, the disk is not).
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: UInt64(ChatRewindStore.maximumFileBytes) + (1 << 20))
        try handle.close()

        let large = try await bench.driver.rewindPreview(userMessageID: second)
        #expect(large.copy == .tooLarge && !large.canKeepCopy)
        await #expect(throws: ChatRewindError.tooLarge) { try await bench.driver.rewindFiles(userMessageID: second) }
        // The CLI was not asked: the file is as the user left it, and no copy or marker exists.
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
        #expect(size == ChatRewindStore.maximumFileBytes + (1 << 20))
        #expect(bench.store.rewindIDs(sessionID: bench.id).isEmpty)
        #expect(await bench.driver.openUndoRewindID() == nil)
        await bench.finish()
    }

    @Test func aRealRewindsErrorFrameIsAClearFailureThatChangesNothingAndKeepsNoCopy() async throws {
        let bench = try await Bench(environment: ["LOOM_FAKE_CHAT_CHECKPOINTS": "fail"])
        try await bench.write("a.txt", "one")
        let second = try await bench.write("a.txt", "two")
        let path = try #require(try await bench.driver.rewindPreview(userMessageID: second).files.first)
        do {
            try await bench.driver.rewindFiles(userMessageID: second)
            Issue.record("the rewind succeeded")
        } catch let ChatRewindError.failed(message) {
            #expect(message.contains("could not be restored"))
        }
        #expect(text(path) == "two")
        #expect(bench.store.rewindIDs(sessionID: bench.id).isEmpty)
        #expect(await bench.driver.openUndoRewindID() == nil)
        #expect(await bench.driver.snapshot().markers.allSatisfy { if case .rewound = $0 { false } else { true } })
        // The session is still at its prompt and can try again.
        #expect(await bench.driver.rewindAvailability() == .available)
        await bench.finish()
    }

    // MARK: Rewind, marker, Undo

    @Test func aRewindRestoresTheFilesRecordsTheCopyAndLeavesAMarkerAndUndoBringsTheFilesBack() async throws {
        let bench = try await Bench()
        try await bench.write("a.txt", "one")
        let second = try await bench.write("a.txt", "two")
        try await bench.write("b.txt", "bee")
        let preview = try await bench.driver.rewindPreview(userMessageID: second)
        #expect(names(preview.files) == ["a.txt", "b.txt"])
        let a = try #require(preview.files.first { $0.hasSuffix("a.txt") })
        let b = try #require(preview.files.first { $0.hasSuffix("b.txt") })

        let result = try await bench.driver.rewindFiles(userMessageID: second, messageTitle: RewindMarker.title(from: "/scenario file a.txt two"))
        #expect(names(result.files) == ["a.txt", "b.txt"])
        // Claude's tracked files are back to before the message; the file made after it is gone.
        #expect(text(a) == "one" && text(b) == nil)

        let marker = try #require(await bench.driver.snapshot().markers.compactMap { marker -> RewindMarker? in
            if case let .rewound(rewound) = marker { rewound } else { nil }
        }.last)
        #expect(marker.rewindID == result.rewindID && marker.undo == .available && marker.title == "/scenario file a.txt two")
        #expect(await bench.driver.openUndoRewindID() == result.rewindID)

        // The copy was made before the call: it holds what the files held then, and the manifest the state the rewind left.
        let manifest = try bench.store.load(sessionID: bench.id, rewindID: result.rewindID)
        #expect(manifest.completed && manifest.userMessageID == second)
        let copyOfA = try #require(manifest.files.first { $0.path == a })
        let copyOfB = try #require(manifest.files.first { $0.path == b })
        #expect(copyOfA.sha256 == ChatRewindStore.hash(Data("two".utf8)) && copyOfA.sha256After == ChatRewindStore.hash(Data("one".utf8)))
        #expect(copyOfB.sha256 == ChatRewindStore.hash(Data("bee".utf8)) && copyOfB.existsAfter == false)

        let undone = try await bench.driver.undoRewind(rewindID: result.rewindID)
        #expect(Set(undone.restored) == [a, b] && undone.trashed.isEmpty)
        #expect(text(a) == "two" && text(b) == "bee")
        let after = try #require(await bench.driver.snapshot().markers.compactMap { marker -> RewindMarker? in
            if case let .rewound(rewound) = marker { rewound } else { nil }
        }.last)
        #expect(after.undo == .undone)
        #expect(await bench.driver.openUndoRewindID() == nil)
        await #expect(throws: ChatRewindError.undoUnavailable) { try await bench.driver.undoRewind(rewindID: result.rewindID) }
        await bench.finish()
    }

    @Test func aFileTheRewindBroughtBackThatDidNotExistBeforeGoesToTheTrashOnUndo() async throws {
        let bench = try await Bench()
        try await bench.write("c.txt", "see")
        let second = try await bench.write("d.txt", "dee")
        let preview = try await bench.driver.rewindPreview(userMessageID: second)
        let d = try #require(preview.files.first { $0.hasSuffix("d.txt") })
        let c = URL(fileURLWithPath: d).deletingLastPathComponent().appendingPathComponent("c.txt").path
        // The user deletes c.txt after Claude wrote it: the rewind would bring it back.
        try FileManager.default.removeItem(atPath: c)
        let result = try await bench.driver.rewindFiles(userMessageID: second)
        #expect(names(result.files) == ["c.txt", "d.txt"])
        #expect(text(c) == "see")

        let undone = try await bench.driver.undoRewind(rewindID: result.rewindID)
        #expect(undone.trashed == [c])
        #expect(bench.trashed.paths == [c])
        #expect(text(c) == nil)
        #expect(text(d) == "dee")
        await bench.finish()
    }

    @Test func aRewindClaudeNeverAnsweredStillLeavesItsMarkerAndUndoFromLoomsCopy() async throws {
        // The fake restores the files and exits without an answer: the request ends unanswered when the channel closes.
        let bench = try await Bench(environment: ["LOOM_FAKE_CHAT_CHECKPOINTS": "die"])
        try await bench.write("a.txt", "one")
        let second = try await bench.write("a.txt", "two")
        let path = try #require(try await bench.driver.rewindPreview(userMessageID: second).files.first)
        await #expect(throws: ChatRewindError.noAnswer) { try await bench.driver.rewindFiles(userMessageID: second) }
        #expect(text(path) == "one")

        // The copy Loom kept is within reach: the marker offers Undo, and Undo puts the file back as it was before.
        let rewindID = try #require(await bench.driver.openUndoRewindID())
        #expect(try bench.store.load(sessionID: bench.id, rewindID: rewindID).completed)
        try await bench.driver.undoRewind(rewindID: rewindID)
        #expect(text(path) == "two")
        await bench.finish()
    }

    @Test func theQueuesSendNowAndResumeWaitWhileAnUndoRuns() async throws {
        // The Undo's trash step is slow, so the Undo holds the session for a while.
        let bench = try await Bench(trashDelay: 2)
        try await bench.write("c.txt", "see")
        let second = try await bench.write("d.txt", "dee")
        let d = try #require(try await bench.driver.rewindPreview(userMessageID: second).files.first { $0.hasSuffix("d.txt") })
        let c = URL(fileURLWithPath: d).deletingLastPathComponent().appendingPathComponent("c.txt").path
        try FileManager.default.removeItem(atPath: c)
        let result = try await bench.driver.rewindFiles(userMessageID: second)
        let item = try await bench.driver.enqueue("after the undo")

        async let undo = bench.driver.undoRewind(rewindID: result.rewindID)
        #expect(await waitUntil { await bench.driver.rewindAvailability() == .notIdle })
        // No turn starts in the middle of it, from the queue either; the item stays.
        await #expect(throws: ChatDriverError.busy) { try await bench.driver.sendQueuedNow(id: item) }
        await #expect(throws: ChatDriverError.busy) { try await bench.driver.resumeQueue() }
        #expect(await bench.driver.snapshot().queue.items.map(\.id) == [item])
        #expect(try await undo.trashed == [c])

        try await bench.driver.sendQueuedNow(id: item)
        #expect(await waitUntil { await bench.driver.snapshot().texts.last == "Fake answer to: after the undo" })
        await bench.finish()
    }

    @Test func aFileChangedAfterTheRewindIsNamedBeforeUndoOverwritesIt() async throws {
        let bench = try await Bench()
        try await bench.write("a.txt", "one")
        let second = try await bench.write("a.txt", "two")
        let a = try #require(try await bench.driver.rewindPreview(userMessageID: second).files.first)
        let result = try await bench.driver.rewindFiles(userMessageID: second)
        try "one, and a line the user added".write(toFile: a, atomically: true, encoding: .utf8)

        await #expect(throws: ChatRewindError.changedSince([a])) { try await bench.driver.undoRewind(rewindID: result.rewindID) }
        // Nothing was written, and Undo is still offered.
        #expect(text(a) == "one, and a line the user added")
        #expect(await bench.driver.openUndoRewindID() == result.rewindID)
        try await bench.driver.undoRewind(rewindID: result.rewindID, overwritingChanged: true)
        #expect(text(a) == "two")
        await bench.finish()
    }

    @Test func undoGoesWhenTheNextMessageIsSentAndOnlyTheNewestRewindOffersIt() async throws {
        let bench = try await Bench()
        try await bench.write("a.txt", "one")
        let second = try await bench.write("a.txt", "two")
        let first = try await bench.driver.rewindFiles(userMessageID: second)
        #expect(await bench.driver.openUndoRewindID() == first.rewindID)

        // A message after the rewind: the files are no longer as it left them.
        try await bench.driver.send("a plain question")
        #expect(await idle(bench.driver))
        #expect(await bench.driver.openUndoRewindID() == nil)
        await #expect(throws: ChatRewindError.undoUnavailable) { try await bench.driver.undoRewind(rewindID: first.rewindID) }
        let marker = try #require(await bench.driver.snapshot().markers.compactMap { marker -> RewindMarker? in
            if case let .rewound(rewound) = marker { rewound } else { nil }
        }.last)
        #expect(marker.undo == .expired)

        // A newer rewind takes the offer from the older one.
        let third = try await bench.write("a.txt", "three")
        let one = try await bench.driver.rewindFiles(userMessageID: third)
        #expect(await bench.driver.openUndoRewindID() == one.rewindID)
        await bench.finish()
    }

    /// D-72: a rewind's copies exist only while its Undo can be offered, whichever way the Undo closes.
    @Test func aRewindsCopiesGoWhenItsUndoClosesBySendByANewerRewindOrByUndoItself() async throws {
        let bench = try await Bench()
        try await bench.write("a.txt", "one")
        let second = try await bench.write("a.txt", "two")
        let first = try await bench.driver.rewindFiles(userMessageID: second)
        #expect(bench.store.rewindIDs(sessionID: bench.id) == [first.rewindID])

        // A message after the rewind closes its Undo, and the copies go with it.
        try await bench.driver.send("a plain question")
        #expect(await idle(bench.driver))
        #expect(await bench.driver.openUndoRewindID() == nil)
        #expect(bench.store.rewindIDs(sessionID: bench.id).isEmpty)
        #expect(bench.store.sessionIDs().isEmpty)

        // Undo itself closes it.
        let third = try await bench.write("a.txt", "three")
        let undone = try await bench.driver.rewindFiles(userMessageID: third)
        #expect(bench.store.rewindIDs(sessionID: bench.id) == [undone.rewindID])
        try await bench.driver.undoRewind(rewindID: undone.rewindID)
        #expect(bench.store.rewindIDs(sessionID: bench.id).isEmpty)

        // A newer rewind replaces the older: only its own copies stay.
        let fourth = try await bench.write("a.txt", "four")
        let fifth = try await bench.write("a.txt", "five")
        let older = try await bench.driver.rewindFiles(userMessageID: fifth)
        #expect(bench.store.rewindIDs(sessionID: bench.id) == [older.rewindID])
        let newer = try await bench.driver.rewindFiles(userMessageID: fourth)
        #expect(bench.store.rewindIDs(sessionID: bench.id) == [newer.rewindID])
        #expect(await bench.driver.openUndoRewindID() == newer.rewindID)
        #expect(bench.store.sessionIDs() == [bench.id])
        await bench.finish()
    }

    @Test func twoRewindsAtOnceDoOneOnlyAndAnEmptyRewindIsRefused() async throws {
        let bench = try await Bench()
        try await bench.write("a.txt", "one")
        let second = try await bench.write("a.txt", "two")
        func attempt(_ body: () async throws -> RewindResult) async -> Result<RewindResult, Error> {
            do { return .success(try await body()) } catch { return .failure(error) }
        }
        // Whichever comes second is refused while the first runs, or finds nothing left to rewind.
        async let first = attempt { try await bench.driver.rewindFiles(userMessageID: second) }
        async let again = attempt { try await bench.driver.rewindFiles(userMessageID: second) }
        let outcomes = await [first, again]
        #expect(outcomes.filter { if case .success = $0 { true } else { false } }.count == 1)
        for case let .failure(error) in outcomes {
            #expect(error as? ChatRewindError == .notAvailable(.notIdle) || error as? ChatRewindError == .nothingToChange)
        }
        #expect(bench.store.rewindIDs(sessionID: bench.id).count == 1)
        await #expect(throws: ChatRewindError.nothingToChange) { try await bench.driver.rewindFiles(userMessageID: second) }
        await bench.finish()
    }

    // MARK: The host

    /// D-72: an Undo lives only in memory, so what an earlier run (or a driver that is gone) left is removed when the host starts.
    @MainActor
    @Test func copiesAnEarlierRunLeftAreRemovedWhenTheHostStarts() async throws {
        let rig = try await Rig.make()
        let root = rig.root.appendingPathComponent("data", isDirectory: true)
        let earlier = ChatRewindStore(directory: root.appendingPathComponent("chat-rewinds", isDirectory: true))
        let session = UUID()
        let file = rig.root.appendingPathComponent("f.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        _ = try earlier.begin(sessionID: session, userMessageID: "m", paths: [file.path])
        #expect(earlier.sessionIDs() == [session])

        let host = ChatSessionHost(runtime: rig.runtime, dataRoot: root)
        #expect(host.rewindStore.sessionIDs().isEmpty)
        // A rewind made in this run is kept (the sweep runs once, before any driver).
        _ = try host.rewindStore.begin(sessionID: session, userMessageID: "m", paths: [file.path])
        #expect(host.driver(for: session) === host.driver(for: session))
        #expect(host.rewindStore.sessionIDs() == [session])
        await rig.finish()
    }

    @MainActor
    @Test func theHostKeepsTheStoreInTheDataFolderAndDeletingTheSessionRemovesItsCopies() async throws {
        let rig = try await Rig.make()
        let root = rig.root.appendingPathComponent("data", isDirectory: true)
        let host = ChatSessionHost(runtime: rig.runtime, dataRoot: root)
        #expect(host.rewindStore.directory == root.appendingPathComponent("chat-rewinds", isDirectory: true))
        let session = UUID(), orphan = UUID()
        let file = rig.root.appendingPathComponent("f.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        _ = try host.rewindStore.begin(sessionID: session, userMessageID: "m", paths: [file.path])
        _ = try host.rewindStore.begin(sessionID: orphan, userMessageID: "m", paths: [file.path])
        #expect(host.driver(for: session) === host.driver(for: session))

        host.forget(sessionID: session)
        #expect(host.rewindStore.rewindIDs(sessionID: session).isEmpty)
        #expect(host.rewindStore.sessionIDs() == [orphan])
        // Launch recovery: copies of a session the catalog no longer has go too.
        await host.removeQueuesOfDeletedSessions()
        #expect(host.rewindStore.sessionIDs().isEmpty)
        await rig.finish()
    }
}
