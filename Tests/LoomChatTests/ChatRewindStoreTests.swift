import Foundation
import Synchronization
import Testing
@testable import LoomChat

// The copies a files rewind keeps for Undo (V21): the manifest and its hashes, the bounds, the newest three per session, the
// session's copies gone with it, Undo from the copy, and the marks of "changed outside Claude". No process.

/// The paths the injected trash step was asked to take.
private final class TrashLog: Sendable {
    private let state = Mutex<[String]>([])
    func add(_ path: String) { state.withLock { $0.append(path) } }
    var paths: [String] { state.withLock { $0 } }
}

@Suite(.timeLimit(.minutes(2)))
struct ChatRewindStoreTests {
    private final class Bench: Sendable {
        let root: URL
        let work: URL
        let store: ChatRewindStore
        let trashed: TrashLog

        init() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-rewind-\(UUID())", isDirectory: true)
            let work = root.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let log = TrashLog()
            // The injected trash step removes the file, as the Trash does, and remembers it.
            self.root = root
            self.work = work
            trashed = log
            store = ChatRewindStore(directory: root.appendingPathComponent("chat-rewinds", isDirectory: true), trash: { url in
                log.add(url.path)
                try FileManager.default.removeItem(at: url)
            })
        }

        func file(_ name: String, _ text: String) throws -> String {
            let url = work.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }

        func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
    }

    @Test func theCopyAndItsManifestRecordTheFilesBeforeAndAfterAndAreOwnerOnly() throws {
        let bench = try Bench()
        defer { bench.remove() }
        let session = UUID()
        let kept = try bench.file("kept.txt", "before")
        let absent = bench.work.appendingPathComponent("absent.txt").path
        let manifest = try bench.store.begin(sessionID: session, userMessageID: "m1", paths: [kept, absent])
        #expect(manifest.userMessageID == "m1" && manifest.sessionID == session.uuidString.lowercased())
        #expect(!manifest.completed && !manifest.undone)
        let first = manifest.files[0]
        #expect(first.existed && first.size == 6 && first.sha256 == ChatRewindStore.hash(Data("before".utf8)))
        #expect(manifest.files[1] == ChatRewindManifest.File(path: absent, existed: false))

        // The rewind changes the file and creates the other; the hashes after are recorded in the same manifest.
        try "after".write(toFile: kept, atomically: true, encoding: .utf8)
        try "brought back".write(toFile: absent, atomically: true, encoding: .utf8)
        let done = try bench.store.finish(sessionID: session, rewindID: manifest.rewindID)
        #expect(done.completed)
        #expect(done.files[0].existsAfter == true && done.files[0].sha256After == ChatRewindStore.hash(Data("after".utf8)))
        #expect(done.files[1].existsAfter == true && done.files[1].sha256After == ChatRewindStore.hash(Data("brought back".utf8)))
        #expect(try bench.store.load(sessionID: session, rewindID: manifest.rewindID) == done)

        let folder = bench.store.folder(session, manifest.rewindID)
        #expect(try permissions(folder) == 0o700)
        #expect(try permissions(bench.store.sessionFolder(session)) == 0o700)
        #expect(try permissions(folder.appendingPathComponent("files")) == 0o700)
        #expect(try permissions(folder.appendingPathComponent("manifest.json")) == 0o600)
        #expect(try permissions(folder.appendingPathComponent("files/0")) == 0o600)
        #expect(try Data(contentsOf: folder.appendingPathComponent("files/0")) == Data("before".utf8))
    }

    @Test func aFileOverTheBoundOrAllTogetherOverTheRewindBoundRefusesBeforeAnythingIsWritten() throws {
        let bench = try Bench()
        defer { bench.remove() }
        // Sparse files: the sizes are real to `stat`, the disk holds nothing.
        func sparse(_ name: String, megabytes: Int) throws -> String {
            let url = bench.work.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(megabytes) << 20)
            try handle.close()
            return url.path
        }
        let big = try sparse("big.bin", megabytes: 65)
        #expect(bench.store.verdict(for: [big]) == .tooLarge)
        let fits = try sparse("fits.bin", megabytes: 64)
        #expect(bench.store.verdict(for: [fits]) == .ok(totalBytes: 64 << 20))
        // Five files of 60 MiB are each under the file bound and together over the rewind's.
        let five = try (0..<5).map { try sparse("part\($0).bin", megabytes: 60) }
        #expect(bench.store.verdict(for: five) == .tooLarge)
        #expect(bench.store.verdict(for: Array(five.prefix(4))) == .ok(totalBytes: 240 << 20))

        let session = UUID()
        #expect(throws: ChatRewindStoreError.tooLarge) { try bench.store.begin(sessionID: session, userMessageID: "m", paths: [big]) }
        #expect(throws: ChatRewindStoreError.tooLarge) { try bench.store.begin(sessionID: session, userMessageID: "m", paths: five) }
        #expect(bench.store.rewindIDs(sessionID: session).isEmpty)

        // A directory is no file Loom can copy.
        #expect(bench.store.verdict(for: [bench.work.path]) == .cannotCopy([bench.work.path]))
        #expect(throws: ChatRewindStoreError.cannotCopy([bench.work.path])) {
            try bench.store.begin(sessionID: session, userMessageID: "m", paths: [bench.work.path])
        }
    }

    @Test func aSessionKeepsItsNewestThreeRewindsAndDeletingTheSessionRemovesAll() throws {
        let bench = try Bench()
        defer { bench.remove() }
        let session = UUID(), other = UUID()
        let path = try bench.file("a.txt", "x")
        var ids: [String] = []
        for index in 0..<5 {
            ids.append(try bench.store.begin(sessionID: session, userMessageID: "m\(index)", paths: [path],
                                             now: Date(timeIntervalSince1970: 1_000 + Double(index))).rewindID)
        }
        _ = try bench.store.begin(sessionID: other, userMessageID: "o", paths: [path])
        #expect(bench.store.rewindIDs(sessionID: session) == Array(ids.suffix(3)))
        #expect(bench.store.rewindIDs(sessionID: other).count == 1)
        #expect(bench.store.sessionIDs() == [session, other])

        try bench.store.forget(sessionID: session)
        #expect(bench.store.rewindIDs(sessionID: session).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bench.store.sessionFolder(session).path))
        #expect(bench.store.sessionIDs() == [other])
        // Forgetting a session with no copies is no error.
        try bench.store.forget(sessionID: session)
    }

    @Test func undoPutsTheCopiesBackAndMovesAFileThatDidNotExistBeforeToTheTrash() throws {
        let bench = try Bench()
        defer { bench.remove() }
        let session = UUID()
        let changed = try bench.file("changed.txt", "original")
        let gone = try bench.file("gone.txt", "will be deleted by the rewind")
        let appears = bench.work.appendingPathComponent("appears.txt").path
        let manifest = try bench.store.begin(sessionID: session, userMessageID: "m", paths: [changed, gone, appears])

        // What the rewind did.
        try "restored by rewind".write(toFile: changed, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: gone)
        try "recreated".write(toFile: appears, atomically: true, encoding: .utf8)
        try bench.store.finish(sessionID: session, rewindID: manifest.rewindID)
        #expect(try bench.store.changedSinceRewind(sessionID: session, rewindID: manifest.rewindID).isEmpty)

        let report = try bench.store.restore(sessionID: session, rewindID: manifest.rewindID)
        #expect(bench.text(changed) == "original" && bench.text(gone) == "will be deleted by the rewind")
        #expect(report.restored == [changed, gone] && report.trashed == [appears])
        // Never a plain delete: the injected trash step took the file.
        #expect(bench.trashed.paths == [appears])
        #expect(try bench.store.load(sessionID: session, rewindID: manifest.rewindID).undone)
        // A rewind is undone once.
        #expect(throws: ChatRewindStoreError.self) { try bench.store.restore(sessionID: session, rewindID: manifest.rewindID) }
    }

    @Test func aFileChangedAfterTheRewindIsNamedAndACorruptCopyRestoresNothing() throws {
        let bench = try Bench()
        defer { bench.remove() }
        let session = UUID()
        let one = try bench.file("one.txt", "1")
        let two = try bench.file("two.txt", "2")
        let manifest = try bench.store.begin(sessionID: session, userMessageID: "m", paths: [one, two])
        try "1 after".write(toFile: one, atomically: true, encoding: .utf8)
        try "2 after".write(toFile: two, atomically: true, encoding: .utf8)
        try bench.store.finish(sessionID: session, rewindID: manifest.rewindID)
        // The user edits one file, and deletes the other, after the rewind.
        try "1 after plus the user's line".write(toFile: one, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: two)
        #expect(try bench.store.changedSinceRewind(sessionID: session, rewindID: manifest.rewindID) == [one, two])

        // A copy that no longer matches its hash stops the whole restore before any file is written.
        let copy = bench.store.folder(session, manifest.rewindID).appendingPathComponent("files/1")
        try "tampered".write(to: copy, atomically: true, encoding: .utf8)
        #expect(throws: ChatRewindStoreError.self) { try bench.store.restore(sessionID: session, rewindID: manifest.rewindID) }
        #expect(bench.text(one) == "1 after plus the user's line")
    }

    // MARK: Changed outside Claude

    private func scan(_ path: String, at time: Date?) -> EditScanResult {
        let edit = EditRecord(toolName: "Edit", toolUseID: "t", timestamp: time, path: path, hunks: [], isCreate: false)
        return EditScanResult(files: [EditedFile(path: path, edits: [edit])], truncated: false, bytesCovered: 1)
    }

    @Test func aFileModifiedMoreThanTwoSecondsAfterClaudesLastEditIsMarkedAndOneWithinTheToleranceIsNot() {
        let edited = Date(timeIntervalSince1970: 1_000_000)
        let result = scan("/work/a.swift", at: edited)
        func marks(modified: Date?, exists: Bool = true) -> [String: RewindFileMark] {
            RewindOutsideChange.marks(files: ["/work/a.swift"], scan: result) { _ in
                RewindOutsideChange.FileState(exists: exists, modified: modified)
            }
        }
        #expect(marks(modified: edited.addingTimeInterval(0.4))["/work/a.swift"] == nil)
        #expect(marks(modified: edited.addingTimeInterval(2))["/work/a.swift"] == nil)
        #expect(marks(modified: edited.addingTimeInterval(2.5))["/work/a.swift"] == .changedSinceClaude)
        #expect(marks(modified: edited.addingTimeInterval(-60))["/work/a.swift"] == nil)
        // A file that is gone now: the rewind would bring it back.
        #expect(marks(modified: nil, exists: false)["/work/a.swift"] == .deletedSinceClaude)
        #expect(RewindFileMark.changedSinceClaude.text == "Changed since Claude's last edit")
        #expect(RewindFileMark.deletedSinceClaude.text == "Deleted since Claude's last edit")
        #expect(RewindFileMark.couldNotCheck.text == "Could not check")
    }

    @Test func aFileWithNoRecordInTheScanCouldNotBeChecked() {
        let edited = Date(timeIntervalSince1970: 1_000_000)
        let state: (String) -> RewindOutsideChange.FileState = { _ in .init(exists: true, modified: edited.addingTimeInterval(500)) }
        // No edit of this file was found (it lies beyond the scan's bound, or only a subagent or a shell command touched it).
        let marks = RewindOutsideChange.marks(files: ["/work/other.swift"], scan: scan("/work/a.swift", at: edited), state: state)
        #expect(marks == ["/work/other.swift": .couldNotCheck])
        // A record with no time cannot be compared; an empty scan cannot check anything; a missing file with no record is
        // not called deleted.
        #expect(RewindOutsideChange.marks(files: ["/work/a.swift"], scan: scan("/work/a.swift", at: nil), state: state)
                == ["/work/a.swift": .couldNotCheck])
        #expect(RewindOutsideChange.marks(files: ["/work/a.swift"], scan: .empty, state: { _ in .init(exists: false) })
                == ["/work/a.swift": .couldNotCheck])
    }

    @Test func pathsAreComparedWithoutThePrivatePrefixOfTmp() {
        let edited = Date(timeIntervalSince1970: 1_000_000)
        let marks = RewindOutsideChange.marks(
            files: ["/private/tmp/work/a.txt"], scan: scan("/tmp/work/a.txt", at: edited),
            state: { _ in .init(exists: true, modified: edited.addingTimeInterval(30)) })
        #expect(marks == ["/private/tmp/work/a.txt": .changedSinceClaude])
    }

    @Test func theMarkerTitleIsTheFirstWordsOfTheMessage() {
        #expect(RewindMarker.title(from: "fix the login") == "fix the login")
        #expect(RewindMarker.title(from: "  fix   the\nlogin bug in the auth module today ") == "fix the login bug in the\u{2026}")
        #expect(RewindMarker.title(from: String(repeating: "x", count: 80)).count == 48)
        #expect(RewindMarker.title(from: "") == "")
    }
}
