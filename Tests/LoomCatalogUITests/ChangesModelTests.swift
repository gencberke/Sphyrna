import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCatalogUITestRigs

/// V20: the Changes tab on the model. It reads only while the tab is open, reads again for a turn that ended, a new
/// scope or a new file, drops a read nobody waits for, and sends its comments as one message. Counting seams stand in
/// for the transcript scan and for git; nothing here opens a window or runs a program.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ChangesModelTests {
    /// Counts what the tab asked for, and answers from the values a test sets.
    final class ReadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _scans: [EditScan.Scope] = []
        private var _lists = 0
        private var _diffs: [String] = []
        var edits = EditScanResult.empty
        var git = GitChangesState.noBaseBranch
        var diff = GitFileDiff.hunks([])
        /// Holds the next scan until `release()` (a read that is slow).
        private var gate: CheckedContinuation<Void, Never>?
        private var holding = false
        private var released = false

        var scans: [EditScan.Scope] { lock.withLock { _scans } }
        var lists: Int { lock.withLock { _lists } }
        var diffs: [String] { lock.withLock { _diffs } }
        var total: Int { scans.count + lists + diffs.count }

        func holdNextScan() { lock.withLock { holding = true; released = false } }

        func release() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                released = true
                defer { gate = nil }
                return gate
            }
            continuation?.resume()
        }

        private func waitIfHeld() async {
            guard lock.withLock({ holding }) else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    holding = false
                    if released { return true }
                    gate = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        var reader: ChangesReader {
            ChangesReader(
                editScan: { [self] _, scope in
                    lock.withLock { _scans.append(scope) }
                    await waitIfHeld()
                    return edits
                },
                gitList: { [self] _ in lock.withLock { _lists += 1 }; return git },
                gitDiff: { [self] file, _ in lock.withLock { _diffs.append(file.path) }; return diff })
        }
    }

    /// Holds independent file reads so their completion order can be reversed.
    final class DelayedDiffs: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [Int: CheckedContinuation<GitFileDiff, Never>] = [:]
        private var started = 0
        var count: Int { lock.withLock { started } }

        func read() async -> GitFileDiff {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    let id = started
                    started += 1
                    pending[id] = continuation
                }
            }
        }

        func finish(_ id: Int, with result: GitFileDiff) {
            lock.withLock { pending.removeValue(forKey: id) }?.resume(returning: result)
        }

        func finishRemaining() {
            let rest = lock.withLock { () -> [CheckedContinuation<GitFileDiff, Never>] in
                defer { pending.removeAll() }
                return Array(pending.values)
            }
            rest.forEach { $0.resume(returning: .failed("Test ended")) }
        }
    }

    @MainActor private struct Fixture {
        let rig: InspectorRig
        let log: ReadLog
        var model: CatalogModel { rig.model }
        var id: UUID { rig.ids[0] }

        func cleanup() { rig.cleanup() }
    }

    /// A model with two sessions, the first one selected, and a log in place of the reads.
    private func fixture() async throws -> Fixture {
        let rig = try await InspectorRig.make()
        let log = ReadLog()
        rig.model.changes.reader = log.reader
        rig.model.setClaudeConfigDirectory(rig.root)
        rig.model.select(rig.ids[0])
        return Fixture(rig: rig, log: log)
    }

    private func edited(_ paths: [String], hunk: DiffHunk = DiffHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: ["-a", "+b"])) -> EditScanResult {
        EditScanResult(files: paths.map { path in
            EditedFile(path: path, edits: [EditRecord(toolName: "Edit", toolUseID: "t-" + path, timestamp: nil, path: path,
                                                      hunks: [hunk], isCreate: false)])
        }, truncated: false, bytesCovered: 100)
    }

    private func gitList(_ paths: [String], onBase: Bool = false) -> GitChangesState {
        .list(GitChangeList(root: "/repo", baseName: "main", onBase: onBase, compareTo: "abc",
                            files: paths.map { GitChangeFile(path: $0, status: .modified, added: 2, removed: 1) }, omittedFiles: 0))
    }

    // MARK: Reads only while the tab is open

    @Test func nothingReadsWhileTheTabIsClosedAndEachReasonToReadReadsOnce() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let (model, id) = (f.model, f.id)
        // Closed, and open on another tab: no trigger, so the inspector's task has nothing to run.
        #expect(model.changesTrigger == nil)
        await model.runChangesRead()
        model.setInspector(open: true, for: id)
        model.selectInspectorTab(.agents)
        #expect(model.changesTrigger == nil, "the inspector is open on Agents")
        await model.runChangesRead()
        // A turn that ends while the tab is not showing wakes nothing.
        model.noteChangesWorking(true, for: id)
        model.noteChangesWorking(false, for: id)
        #expect(f.log.total == 0)

        // Opening the tab is one reason to read.
        model.selectInspectorTab(.changes)
        #expect(model.changesTrigger == ChangesTrigger(session: id, scope: .lastTurn, revision: 0))
        await model.runChangesRead()
        #expect(f.log.scans == [.lastTurn] && f.log.lists == 0)

        // A turn that ends while it shows is another; a turn that starts is not.
        model.noteChangesWorking(true, for: id)
        #expect(model.changesTrigger?.revision == 0)
        model.noteChangesWorking(false, for: id)
        #expect(model.changesTrigger?.revision == 1)
        await model.runChangesRead()
        #expect(f.log.scans == [.lastTurn, .lastTurn])

        // So is a new scope (and only that scope is read).
        model.setChangesScope(.wholeSession, for: id)
        await model.runChangesRead()
        #expect(f.log.scans == [.lastTurn, .lastTurn, .wholeSession] && f.log.lists == 0)

        // Closed again: the same calls read nothing, and neither does a turn that ends.
        model.selectInspectorTab(.agents)
        #expect(model.changesTrigger == nil)
        await model.runChangesRead()
        model.noteChangesWorking(true, for: id)
        model.noteChangesWorking(false, for: id)
        model.setInspector(open: false, for: id)
        await model.runChangesRead()
        #expect(f.log.total == 3)
        // The tab on another session's inspector reads nothing for this one either.
        model.selectInspectorTab(.changes)
        model.select(f.rig.ids[1])
        #expect(model.changesTrigger == nil, "the second session's inspector is closed")
    }

    /// The Overview lists the last turn's files: it reads them while it is open, as the tab does, into the same state.
    @Test func theOverviewReadsTheLastTurnWhileItIsOpenWhateverScopeTheTabShows() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let (model, id) = (f.model, f.id)
        f.log.edits = edited(["/w/a.swift", "/w/b.swift"])
        #expect(model.changesTrigger == nil, "closed")
        model.setInspector(open: true, for: id)
        #expect(model.inspector.tab == .overview)
        #expect(model.changesTrigger == ChangesTrigger(session: id, scope: .lastTurn, revision: 0))
        await model.runChangesRead()
        #expect(f.log.scans == [.lastTurn] && f.log.lists == 0 && f.log.diffs.isEmpty)
        #expect(model.changes.session(for: id).state(.lastTurn).data?.files.map(\.absolutePath).sorted() == ["/w/a.swift", "/w/b.swift"])

        // The tab's scope is the tab's: the Overview still reads the last turn.
        model.setChangesScope(.branch, for: id)
        #expect(model.changesTrigger?.scope == .lastTurn)

        // A turn that ends while it shows is a reason to read again; one that starts is not.
        model.noteChangesWorking(true, for: id)
        #expect(model.changesTrigger?.revision == 0)
        model.noteChangesWorking(false, for: id)
        #expect(model.changesTrigger?.revision == 1)
        await model.runChangesRead()
        #expect(f.log.scans == [.lastTurn, .lastTurn])

        // Another tab: nothing reads for the Overview, and the tab opens on what the Overview read.
        model.selectInspectorTab(.agents)
        #expect(model.changesTrigger == nil)
        model.noteChangesWorking(true, for: id)
        model.noteChangesWorking(false, for: id)
        #expect(f.log.total == 2)
        model.setChangesScope(.lastTurn, for: id)
        model.selectInspectorTab(.changes)
        #expect(model.changes.session(for: id).state(.lastTurn).data?.files.count == 2)
        model.setInspector(open: false, for: id)
        #expect(model.changesTrigger == nil)
    }

    @Test func anEvictedSelectedScopeRequestsAReadAgainWithoutLosingAnOpenComment() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let model = f.model
        f.log.edits = edited(["/w/a.swift"])
        model.setInspector(open: true, for: f.id)
        model.selectInspectorTab(.changes)
        await model.runChangesRead()
        let session = model.changes.session(for: f.id)
        let anchor = ChangeAnchor(fileID: "/w/a.swift", line: 1, removed: false, text: "+b")
        session.saveComment("Saved", at: anchor, displayPath: "a.swift", in: .lastTurn)
        session.composing = anchor
        session.composingText = "Unsent"
        let before = try #require(model.changesTrigger)
        for _ in 0..<100 {
            model.changes.session(for: UUID()).setState(.ready(ChangesScopeData(files: [])), for: .lastTurn)
        }
        #expect(session.state(.lastTurn) == .idle)
        let after = try #require(model.changesTrigger)
        #expect(after != before, "the mounted reader's task identity changes when its cached scope is evicted")
        if after != before { await model.runChangesRead() }
        #expect(f.log.scans == [.lastTurn, .lastTurn])
        #expect(session.state(.lastTurn).data?.files.first?.id == "/w/a.swift")
        #expect(session.comments(in: .lastTurn).map(\.text) == ["Saved"])
        #expect(session.composing == anchor && session.composingText == "Unsent")
    }

    @Test func aLateEvictedFileReadCannotReplaceItsReopenedSuccessor() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let delayed = DelayedDiffs()
        defer { delayed.finishRemaining() }
        f.log.git = gitList(["a.txt"])
        var reader = f.log.reader
        reader.gitDiff = { _, _ in await delayed.read() }
        f.model.changes.reader = reader
        f.model.setInspector(open: true, for: f.id)
        f.model.selectInspectorTab(.changes)
        f.model.setChangesScope(.branch, for: f.id)
        await f.model.runChangesRead()
        #expect(await inspectorWaitUntil { delayed.count == 1 })
        let session = f.model.changes.session(for: f.id)
        // The same removal is used when the cached file is evicted; opening it starts a fresh read.
        session.setGitDiff(nil, for: "a.txt")
        f.model.selectChangesFile("a.txt", in: f.id)
        #expect(await inspectorWaitUntil { delayed.count == 2 })
        let newer = DiffHunk(oldStart: 1, oldLines: 0, newStart: 1, newLines: 1, lines: ["+new"])
        let older = DiffHunk(oldStart: 1, oldLines: 0, newStart: 1, newLines: 1, lines: ["+old"])
        delayed.finish(1, with: .hunks([newer]))
        #expect(await inspectorWaitUntil { session.gitDiffs["a.txt"] == .hunks([newer]) })
        delayed.finish(0, with: .hunks([older]))
        try await Task.sleep(for: .milliseconds(120))
        #expect(session.gitDiffs["a.txt"] == .hunks([newer]), "a late result cannot overwrite the new file read")
    }

    @Test func fileReadCapacityWaitsForPhysicalCompletionAndAllowsAnExplicitRetry() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let delayed = DelayedDiffs()
        defer { delayed.finishRemaining() }
        let files = (0..<9).map { String(format: "file-%02d.txt", $0) }
        f.log.git = gitList(files)
        var reader = f.log.reader
        reader.gitDiff = { _, _ in await delayed.read() }
        f.model.changes.reader = reader
        f.model.setInspector(open: true, for: f.id)
        f.model.selectInspectorTab(.changes)
        f.model.setChangesScope(.branch, for: f.id)
        await f.model.runChangesRead()
        #expect(await inspectorWaitUntil { delayed.count == 1 })
        for file in files.dropFirst().prefix(7) { f.model.selectChangesFile(file, in: f.id) }
        #expect(await inspectorWaitUntil { delayed.count == 8 })
        f.model.selectChangesFile(files[8], in: f.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(delayed.count == 8, "the ninth physical read must not begin while eight are still running")
        let session = f.model.changes.session(for: f.id)
        #expect(files.dropFirst().prefix(7).allSatisfy { session.gitDiffs[$0] == .loading },
                "unrelated pending reads remain valid")
        if case .failed = session.gitDiffs[files[8]] {} else { Issue.record("The busy file must offer an explicit retry") }

        // Removing an in-flight cache entry does not free its physical slot until that read returns.
        session.setGitDiff(nil, for: files[0])
        f.model.selectChangesFile(files[0], in: f.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(delayed.count == 8)
        guard delayed.count == 8 else { return }
        delayed.finish(0, with: .hunks([]))
        try await Task.sleep(for: .milliseconds(100))
        f.model.retryChangesFile(files[0], in: f.id)
        #expect(await inspectorWaitUntil { delayed.count == 9 })
        let newer = DiffHunk(oldStart: 1, oldLines: 0, newStart: 1, newLines: 1, lines: ["+retried"])
        delayed.finish(8, with: .hunks([newer]))
        #expect(await inspectorWaitUntil { session.gitDiffs[files[0]] == .hunks([newer]) })
    }

    @Test func cachePressureDoesNotInvalidateAnUnrelatedPendingFileRead() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let delayed = DelayedDiffs()
        defer { delayed.finishRemaining() }
        f.log.git = gitList(["a.txt"])
        var reader = f.log.reader
        reader.gitDiff = { _, _ in await delayed.read() }
        f.model.changes.reader = reader
        f.model.setInspector(open: true, for: f.id)
        f.model.selectInspectorTab(.changes)
        f.model.setChangesScope(.branch, for: f.id)
        await f.model.runChangesRead()
        #expect(await inspectorWaitUntil { delayed.count == 1 })
        let session = f.model.changes.session(for: f.id)
        for _ in 0..<100 {
            f.model.changes.session(for: UUID()).setState(.ready(ChangesScopeData(files: [])), for: .lastTurn)
        }
        #expect(session.state(.branch).data != nil && session.gitDiffs["a.txt"] == .loading)
        let result = DiffHunk(oldStart: 1, oldLines: 0, newStart: 1, newLines: 1, lines: ["+finished"])
        delayed.finish(0, with: .hunks([result]))
        #expect(await inspectorWaitUntil { session.gitDiffs["a.txt"] == .hunks([result]) })
    }

    @Test func aForgottenSessionCannotReinstallItsLateScopeReadIntoAReplacementHolder() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        f.log.edits = edited(["/w/a.swift"])
        f.model.setInspector(open: true, for: f.id)
        f.model.selectInspectorTab(.changes)
        f.log.holdNextScan()
        defer { f.log.release() }
        let slow = Task { await f.model.runChangesRead() }
        #expect(await inspectorWaitUntil { f.log.scans.count == 1 })
        let old = f.model.changes.session(for: f.id)
        let trigger = try #require(f.model.changesTrigger)
        f.model.changes.forget(f.id)
        let replacement = f.model.changes.session(for: f.id)
        #expect(old !== replacement && f.model.changesTrigger == trigger)
        f.log.release()
        await slow.value
        #expect(old.state(.lastTurn).data == nil, "a retired holder cannot install the late payload")
        #expect(replacement.state(.lastTurn).data == nil)
    }

    @Test func anEvictedScopeRejectsItsLateReadAndCanReload() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        f.log.edits = edited(["/w/a.swift"])
        f.model.setInspector(open: true, for: f.id)
        f.model.selectInspectorTab(.changes)
        await f.model.runChangesRead()
        let session = f.model.changes.session(for: f.id)
        f.log.holdNextScan()
        defer { f.log.release() }
        let slow = Task { await f.model.runChangesRead() }
        #expect(await inspectorWaitUntil { f.log.scans.count == 2 })
        for _ in 0..<100 {
            f.model.changes.session(for: UUID()).setState(.ready(ChangesScopeData(files: [])), for: .lastTurn)
        }
        #expect(session.state(.lastTurn) == .idle)
        f.log.release()
        await slow.value
        #expect(session.state(.lastTurn) == .idle, "a late read cannot restore an evicted payload")
        await f.model.runChangesRead()
        #expect(f.log.scans.count == 3 && session.state(.lastTurn).data?.files.first?.id == "/w/a.swift")
    }

    @Test func aForgottenSessionCannotReinstallItsLateFileReadIntoAReplacementHolder() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let delayed = DelayedDiffs()
        defer { delayed.finishRemaining() }
        f.log.git = gitList(["a.txt"])
        var reader = f.log.reader
        reader.gitDiff = { _, _ in await delayed.read() }
        f.model.changes.reader = reader
        f.model.setInspector(open: true, for: f.id)
        f.model.selectInspectorTab(.changes)
        f.model.setChangesScope(.branch, for: f.id)
        await f.model.runChangesRead()
        #expect(await inspectorWaitUntil { delayed.count == 1 })
        let old = f.model.changes.session(for: f.id)
        f.model.changes.forget(f.id)
        let replacement = f.model.changes.session(for: f.id)
        replacement.scope = .branch
        let result = DiffHunk(oldStart: 1, oldLines: 0, newStart: 1, newLines: 1, lines: ["+stale"])
        delayed.finish(0, with: .hunks([result]))
        try await Task.sleep(for: .milliseconds(120))
        #expect(old.gitDiffs["a.txt"] == nil, "a retired holder cannot install the late diff")
        #expect(replacement.gitDiffs["a.txt"] == nil)
    }

    /// RS-8: a card that waits moved the indicator off `.working`, so each approval card made a read and the allow made another.
    /// The tab's view reports the indicator (`noteChangesIndicator`); a waiting card is the turn still going.
    @Test func anApprovalCardInTheMiddleOfATurnMakesNoReadAndTheTurnsEndMakesExactlyOne() async throws {
        for scope in [ChangesScope.lastTurn, .branch] {
            let f = try await fixture()
            defer { f.cleanup() }
            let (model, id) = (f.model, f.id)
            f.log.git = gitList(["a.swift"])
            model.setInspector(open: true, for: id)
            model.selectInspectorTab(.changes)
            model.setChangesScope(scope, for: id)
            // The tab mounts on a session at its prompt, and opening it is one read.
            // The inspector's `.task(id: changesTrigger)` reads when the trigger changed, and only then.
            var seen: ChangesTrigger?
            func readLikeTheTask() async {
                guard let trigger = model.changesTrigger, trigger != seen else { return }
                seen = trigger
                await model.runChangesRead()
            }
            func reads() -> Int { f.log.scans.count + f.log.lists }
            model.noteChangesIndicator(.ready, for: id)
            await readLikeTheTask()
            #expect(reads() == 1, "\(scope)")

            // The turn starts, a card appears and is allowed, a second one waits and is allowed: no read comes.
            let revision = model.changesTrigger?.revision
            for indicator in [SessionIndicator.working, .waitingForApproval, .working, .waitingForApproval, .working] {
                model.noteChangesIndicator(indicator, for: id)
                #expect(model.changesTrigger?.revision == revision, "\(scope) \(indicator)")
                await readLikeTheTask()
            }
            #expect(reads() == 1, "\(scope): nothing reads while the turn goes on")

            // The turn ends: exactly one read.
            model.noteChangesIndicator(.ready, for: id)
            #expect(model.changesTrigger?.revision == (revision ?? 0) + 1, "\(scope)")
            await readLikeTheTask()
            #expect(reads() == 2, "\(scope): one read when the turn ends")

            // A turn that ends at a card nobody answered yet ends when the card is answered and the session rests.
            model.noteChangesIndicator(.working, for: id)
            model.noteChangesIndicator(.waitingForApproval, for: id)
            await readLikeTheTask()
            #expect(reads() == 2)
            model.noteChangesIndicator(.unviewedCompletion, for: id)
            await readLikeTheTask()
            #expect(reads() == 3, "\(scope)")
        }
    }

    @Test func aReadNobodyWaitsForAnyMoreIsDropped() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        f.log.edits = edited(["/w/a.txt"])
        f.model.setInspector(open: true, for: f.id)
        f.model.selectInspectorTab(.changes)
        f.log.holdNextScan()
        let slow = Task { await f.model.runChangesRead() }
        #expect(await inspectorWaitUntil { f.log.scans.count == 1 })
        // The tab closes while the scan is out (to Agents: the Overview reads the last turn too); its answer arrives and is
        // not shown.
        f.model.selectInspectorTab(.agents)
        f.log.release()
        await slow.value
        #expect(f.model.changes.session(for: f.id).state(.lastTurn).data == nil)
    }

    @Test func theTurnScopesShowTheEditsAndTheTabCountsTheFilesOfTheScope() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let model = f.model
        f.log.edits = edited(["/w/src/a.swift", "/w/b.swift"])
        model.setInspector(open: true, for: f.id)
        model.selectInspectorTab(.changes)
        #expect(model.changesFileCount(for: f.id) == nil, "not read yet")
        await model.runChangesRead()
        let state = model.changes.session(for: f.id).currentState
        let data = try #require(state.data)
        // Paths are shown relative to the session's folder (the rig's); the others keep their path.
        #expect(data.files.map(\.id) == ["/w/src/a.swift", "/w/b.swift"])
        #expect(data.files.map(\.absolutePath) == ["/w/src/a.swift", "/w/b.swift"])
        #expect(data.files[0].added == 1 && data.files[0].removed == 1)
        #expect(data.hunks["/w/b.swift"] == [DiffHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: ["-a", "+b"])])
        #expect(model.changesFileCount(for: f.id) == 2)
        // The first file of the list (folders first) is open.
        #expect(model.changes.session(for: f.id).selected[.lastTurn] == "/w/src/a.swift")
        // A file over the line bound is "too large" and shows no diff.
        f.log.edits = edited(["/w/big.txt"], hunk: DiffHunk(oldStart: 1, oldLines: 0, newStart: 1, newLines: 2_001,
                                                            lines: Array(repeating: "+x", count: 2_001)))
        model.retryChanges(for: f.id)
        await model.runChangesRead()
        #expect(model.changes.session(for: f.id).currentState.data?.files.first?.isTooLarge == true)
    }

    // MARK: The branch scope

    @Test func theBranchScopeReadsTheListOnceAndEachFileOnceWhenItIsShown() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let model = f.model
        f.log.git = gitList(["a.txt", "dir/b.txt"])
        f.log.diff = .hunks([DiffHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: ["-x", "+y"])])
        model.setInspector(open: true, for: f.id)
        model.selectInspectorTab(.changes)
        model.setChangesScope(.branch, for: f.id)
        await model.runChangesRead()
        let session = model.changes.session(for: f.id)
        #expect(f.log.lists == 1 && f.log.scans.isEmpty)
        let data = try #require(session.currentState.data)
        #expect(data.baseName == "main" && !data.onBase && data.files.map(\.id) == ["a.txt", "dir/b.txt"])
        #expect(data.files[1].absolutePath == "/repo/dir/b.txt")
        // The folder's file comes first (folders first), and its diff is read because it is the open one.
        #expect(session.selected[.branch] == "dir/b.txt")
        #expect(await inspectorWaitUntil { f.log.diffs == ["dir/b.txt"] && session.gitDiffs["dir/b.txt"] != .loading })
        #expect(session.gitDiffs["dir/b.txt"] == .hunks([DiffHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: ["-x", "+y"])]))

        // Another file reads its own diff, once: going back to the first one reads nothing more.
        model.selectChangesFile("a.txt", in: f.id)
        #expect(await inspectorWaitUntil { session.gitDiffs["a.txt"] != nil && session.gitDiffs["a.txt"] != .loading })
        model.selectChangesFile("dir/b.txt", in: f.id)
        model.selectChangesFile("a.txt", in: f.id)
        #expect(f.log.diffs == ["dir/b.txt", "a.txt"])

        // A new list (a turn ended) drops the diffs read for the old one and reads the open file again.
        model.noteChangesWorking(true, for: f.id)
        model.noteChangesWorking(false, for: f.id)
        await model.runChangesRead()
        #expect(f.log.lists == 2)
        #expect(await inspectorWaitUntil { f.log.diffs.count == 3 && session.gitDiffs["a.txt"] != .loading })
        #expect(session.gitDiffs["dir/b.txt"] == nil)
    }

    /// The list's letter per file (DESIGN §13): a rename keeps R and its old path, an untracked file is A, a tracked file that lost
    /// every line is D, and any other tracked change is M.
    @Test func theBranchListCarriesEachFilesStatusLetterAndARenamesOldPath() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        f.log.git = .list(GitChangeList(root: "/repo", baseName: "main", onBase: false, compareTo: "abc", files: [
            GitChangeFile(path: "src/new.swift", oldPath: "src/old.swift", status: .renamed, added: 1, removed: 1),
            GitChangeFile(path: "added.swift", status: .untracked, added: 3, removed: 0),
            GitChangeFile(path: "gone.swift", status: .modified, added: 0, removed: 7),
            GitChangeFile(path: "edited.swift", status: .modified, added: 2, removed: 1),
        ], omittedFiles: 0))
        f.model.openChanges(.branch, for: f.id)
        await f.model.runChangesRead()
        let data = try #require(f.model.changes.session(for: f.id).currentState.data)
        func file(_ id: String) -> ChangesFile? { data.files.first { $0.id == id } }
        #expect(file("src/new.swift")?.status == .renamed && file("src/new.swift")?.oldPath == "src/old.swift")
        #expect(file("added.swift")?.status == .added && file("added.swift")?.oldPath == nil)
        #expect(file("gone.swift")?.status == .deleted)
        #expect(file("edited.swift")?.status == .modified)
        #expect(ChangesFileStatus.allCases.map(\.letter) == ["M", "A", "D", "R"])
        // The row reads a rename as "old → new", and a plain file as its name.
        #expect(String(ChangesFileText.name("new.swift", oldPath: "old.swift").characters) == "old.swift \u{2192} new.swift")
        #expect(String(ChangesFileText.name("plain.swift", oldPath: nil).characters) == "plain.swift")
    }

    /// A file the turn created is A in the edit scopes; an edit of an existing file is M.
    @Test func theEditScopesMarkAFileTheScopeCreatedAsAdded() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        func edit(_ path: String, create: Bool, lines: [String]) -> EditRecord {
            EditRecord(toolName: create ? "Write" : "Edit", toolUseID: "t-" + path, timestamp: nil, path: path,
                       hunks: [DiffHunk(oldStart: create ? 0 : 1, oldLines: create ? 0 : 1, newStart: 1, newLines: lines.count,
                                        lines: lines)], isCreate: create)
        }
        f.log.edits = EditScanResult(files: [
            EditedFile(path: "/w/made.swift", edits: [edit("/w/made.swift", create: true, lines: ["+new"])]),
            EditedFile(path: "/w/edited.swift", edits: [edit("/w/edited.swift", create: false, lines: ["-a", "+b"])]),
        ], truncated: false, bytesCovered: 10)
        f.model.openChanges(.lastTurn, for: f.id)
        await f.model.runChangesRead()
        let files = try #require(f.model.changes.session(for: f.id).currentState.data?.files)
        #expect(files.first { $0.id == "/w/made.swift" }?.status == .added)
        #expect(files.first { $0.id == "/w/edited.swift" }?.status == .modified)
    }

    @Test func theBranchScopeIsOffOrFailedWithItsOwnWords() async throws {        let f = try await fixture()
        defer { f.cleanup() }
        let model = f.model
        model.setInspector(open: true, for: f.id)
        model.selectInspectorTab(.changes)
        model.setChangesScope(.branch, for: f.id)
        let session = model.changes.session(for: f.id)
        let cases: [(GitChangesState, ChangesScopeState)] = [
            (.notARepository, .off("Not a Git repository")), (.noBaseBranch, .off("No base branch found")),
            (.timedOut, .timedOut), (.failed("fatal: nope"), .failed("fatal: nope")),
        ]
        for (git, expected) in cases {
            f.log.git = git
            await model.runChangesRead()
            #expect(session.currentState == expected)
        }
        // On the base branch the list is the uncommitted changes, and the tab says so.
        f.log.git = gitList(["a.txt"], onBase: true)
        await model.runChangesRead()
        let state = session.currentState
        #expect(state.data?.onBase == true)
        #expect(ChangesBodyWords.note(scope: .branch, state: state) == "You are on main. Showing the uncommitted changes.")
        #expect(ChangesBodyWords.emptyText(scope: .branch, data: ChangesScopeData(files: [], baseName: "main", onBase: true)) == "No uncommitted changes.")
        // A folder that is not a repository: the session's own folder is what git is asked about.
        #expect(ChangesBodyWords.note(scope: .lastTurn, state: .ready(ChangesScopeData(files: [], truncated: true)))
                == "Claude's file edits. Shell commands and subagents show under Branch. Older edits were not read.")
    }

    // MARK: Opening from the card

    @Test func openInChangesOpensTheInspectorOnTheTabWithTheScope() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let model = f.model
        #expect(!model.inspector.isOpen(for: f.id))
        model.openChanges(.wholeSession, for: f.id)
        #expect(model.inspector.isOpen(for: f.id) && model.inspector.tab == .changes)
        #expect(model.changesTrigger?.scope == .wholeSession)
        model.openChanges(.lastTurn, for: f.id)
        #expect(model.changesTrigger?.scope == .lastTurn)
    }

    // MARK: Comments

    private func anchor(_ line: Int?, _ text: String, file: String = "/w/a.swift", removed: Bool = false) -> ChangeAnchor {
        ChangeAnchor(fileID: file, line: line, removed: removed, text: text)
    }

    @Test func theMessageIsOnePlainTextWithEachCommentUnderItsLine() {
        func comment(_ path: String, _ anchor: ChangeAnchor, _ text: String) -> ChangeComment {
            ChangeComment(id: UUID(), anchor: anchor, displayPath: path, text: text)
        }
        let text = ChangesMessage.text(scopeName: "Last turn", comments: [
            comment("src/auth/token_service.py", anchor(49, "            expires = now() + timedelta(days=30)"),
                    "Use the existing REFRESH_TTL setting instead of the literal 30 days."),
            comment("src/auth/token_service.py", anchor(44, "        return self._issue(record.user_id)", removed: true),
                    "Why was this return dropped?\nIt looked right."),
            comment("tests/test_rotation.py", anchor(7, "def test_reuse():", file: "/w/tests/test_rotation.py"), "Name it for the 401."),
            comment("notebook.ipynb", anchor(nil, "x = 1", file: "/w/notebook.ipynb"), "Should this be a function?"),
        ])
        #expect(text == """
        Comments on the changes (Last turn):

        src/auth/token_service.py:49
        >             expires = now() + timedelta(days=30)
        Use the existing REFRESH_TTL setting instead of the literal 30 days.

        src/auth/token_service.py:44
        >         return self._issue(record.user_id)
        Why was this return dropped?
        It looked right.

        tests/test_rotation.py:7
        > def test_reuse():
        Name it for the 401.

        notebook.ipynb
        > x = 1
        Should this be a function?
        """)
        #expect(ChangesFooterText.summary(comments: 1, files: 1) == "1 comment in 1 file")
        #expect(ChangesFooterText.summary(comments: 2, files: 2) == "2 comments in 2 files")
    }

    @Test func aCommentIsAnchoredToItsLineAndTheDraftsReadInTheOrderOfTheList() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let model = f.model
        f.log.edits = edited(["/w/b.swift", "/w/a.swift"])
        model.openChanges(.lastTurn, for: f.id)
        await model.runChangesRead()
        let session = model.changes.session(for: f.id)

        // Box open on a line of the second file, then saved; an empty text removes the comment.
        model.beginChangeComment(at: anchor(9, "+b", file: "/w/b.swift"), in: f.id)
        #expect(session.composing != nil && session.composingText.isEmpty)
        session.composingText = "  second file, line 9  "
        model.saveChangeComment(in: f.id)
        #expect(session.composing == nil && session.comments(in: .lastTurn).map(\.text) == ["second file, line 9"])
        model.beginChangeComment(at: anchor(2, "x", file: "/w/a.swift"), in: f.id)
        session.composingText = "first file, line 2"
        model.saveChangeComment(in: f.id)
        model.beginChangeComment(at: anchor(1, "y", file: "/w/a.swift"), in: f.id)
        session.composingText = "first file, line 1"
        model.saveChangeComment(in: f.id)
        // The list shows a.swift before b.swift: the message follows it, then the lines.
        #expect(model.orderedChangeComments(for: f.id).map(\.text) == ["first file, line 1", "first file, line 2", "second file, line 9"])
        // A second comment on a line replaces the first; the saved text comes back into the box.
        model.beginChangeComment(at: anchor(2, "x", file: "/w/a.swift"), in: f.id)
        #expect(session.composingText == "first file, line 2")
        session.composingText = "changed"
        model.saveChangeComment(in: f.id)
        #expect(session.comments(in: .lastTurn).count == 3 && session.comments(in: .lastTurn).contains { $0.text == "changed" })
        model.beginChangeComment(at: anchor(2, "x", file: "/w/a.swift"), in: f.id)
        session.composingText = "   "
        model.saveChangeComment(in: f.id)
        #expect(session.comments(in: .lastTurn).count == 2)
        // Each scope keeps its own drafts, and Discard clears the open scope's only.
        model.setChangesScope(.wholeSession, for: f.id)
        #expect(session.comments(in: .wholeSession).isEmpty)
        model.setChangesScope(.lastTurn, for: f.id)
        model.discardChangeComments(in: f.id)
        #expect(session.comments(in: .lastTurn).isEmpty)
    }

    @Test func aSessionOutsideTheChatFaceShowsTheDiffsButCannotSend() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let model = f.model
        f.log.edits = edited(["/w/a.swift"])
        model.openChanges(.lastTurn, for: f.id)
        await model.runChangesRead()
        let session = model.changes.session(for: f.id)
        session.saveComment("note", at: anchor(1, "x"), displayPath: "a.swift", in: .lastTurn)
        var sent: [String] = []
        model.changes.sendOverride = { text, _ in sent.append(text) }
        // No Chat host and no driver: this session is a terminal session.
        #expect(model.changesSendAvailability(for: f.id) == .unavailable)
        await model.sendChangeComments(for: f.id)
        #expect(sent.isEmpty && session.comments(in: .lastTurn).count == 1, "nothing went out, nothing was lost")
        #expect(session.currentState.data?.files.count == 1, "the diffs still show")
    }

    // MARK: The lines of a diff

    @Test func theDiffLinesCarryTheirAnchorsAndTheFirstLineOfARepeatedAnchorHoldsTheComment() {
        let first = DiffHunk(oldStart: 10, oldLines: 2, newStart: 10, newLines: 2, lines: [" keep", "-gone", "+came"])
        let again = DiffHunk(oldStart: 10, oldLines: 1, newStart: 10, newLines: 1, lines: [" keep"])
        let items = ChangesDiffLayout.items(of: [first, again], fileID: "f")
        let rows = items.compactMap { item -> (DiffRow, ChangeAnchor?, Bool)? in
            if case let .row(row) = item.kind { (row, item.anchor, item.showsComments) } else { nil }
        }
        #expect(items.count == 6 && rows.count == 4)
        #expect(rows[0].1 == ChangeAnchor(fileID: "f", line: 10, removed: false, text: "keep") && rows[0].2)
        // A removed line is anchored to the old side, an added one to the new side.
        #expect(rows[1].1 == ChangeAnchor(fileID: "f", line: 11, removed: true, text: "gone"))
        #expect(rows[2].1 == ChangeAnchor(fileID: "f", line: 11, removed: false, text: "came"))
        // The same line again (another edit of the file): the comment is drawn once, under the first.
        #expect(rows[3].1 == rows[0].1 && !rows[3].2)
        // A comment whose line left the diff is kept and drawn after the lines.
        let stale = ChangeComment(id: UUID(), anchor: ChangeAnchor(fileID: "f", line: 99, removed: false, text: "moved"),
                                  displayPath: "f", text: "t")
        let live = ChangeComment(id: UUID(), anchor: rows[1].1!, displayPath: "f", text: "t")
        #expect(ChangesDiffLayout.orphans([stale, live], in: items) == [stale])
        // A hunk without line numbers (a notebook cell) has no header and no numbers, and its comment names the file.
        let cell = ChangesDiffLayout.items(of: [DiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 1, lines: ["+x = 1"], isNumbered: false)],
                                           fileID: "n")
        #expect(cell.count == 1 && cell[0].anchor == ChangeAnchor(fileID: "n", line: nil, removed: false, text: "x = 1"))
    }

    /// DESIGN §13 Diff: the two line-number columns run from each hunk's own starts, and a hunk header line opens each hunk.
    @Test func twoHunksCarryTheirOwnHeaderAndTheirOwnLineNumbersOnBothSides() {
        let first = DiffHunk(oldStart: 10, oldLines: 2, newStart: 10, newLines: 3, lines: [" a", "-b", "+B", "+C"])
        let second = DiffHunk(oldStart: 40, oldLines: 2, newStart: 41, newLines: 2, lines: [" keep", " last"])
        let items = ChangesDiffLayout.items(of: [first, second], fileID: "f")
        #expect(items.count == 8, "a header and four rows, then a header and two rows")
        #expect(items[0].kind == .hunkHeader("@@ -10,2 +10,3 @@"))
        #expect(items[5].kind == .hunkHeader("@@ -40,2 +41,2 @@"))
        let rows = items.compactMap { item -> DiffRow? in if case let .row(row) = item.kind { row } else { nil } }
        #expect(rows.map(\.oldNumber) == [10, 11, nil, nil, 40, 41])
        #expect(rows.map(\.newNumber) == [10, nil, 11, 12, 41, 42])
    }

    @Test func theFileListIsATreeWithFoldersFirst() {        func file(_ path: String) -> ChangesFile { ChangesFile(id: path, displayPath: path, absolutePath: "/r/" + path, added: 1, removed: 0) }
        let lines = ChangesTree.lines(of: [file("README.md"), file("src/auth/login.swift"), file("src/auth/token.swift"), file("z.swift")])
        #expect(lines.map(\.name) == ["src/auth/", "login.swift", "token.swift", "README.md", "z.swift"])
        #expect(lines.map(\.isFolder) == [true, false, false, false, false])
        #expect(lines.compactMap(\.file).map(\.id) == ["src/auth/login.swift", "src/auth/token.swift", "README.md", "z.swift"])
        #expect(lines[0].added == 2)
    }
}
