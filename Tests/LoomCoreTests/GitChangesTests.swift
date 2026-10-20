import Foundation
import Testing
@testable import LoomCore

/// The Changes tab's Branch scope (V20): the file list and one file's diff, read through the supervisor's owned, bounded
/// helper. The repositories are made in temporary folders, by the same helper, with a git that reads no user config.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct GitChangesTests {
    private static let gitEnvironment = [
        "PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "LC_ALL": "C", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
    ]

    private struct Rig {
        let supervisor: ProcessSupervisor
        let root: URL

        func reader(_ limits: GitChanges.Limits = GitChanges.Limits()) -> GitChanges {
            let supervisor = supervisor
            return GitChanges(limits: limits) { arguments, timeout, outputLimit in
                try await supervisor.captureHelper("/usr/bin/git", arguments, environment: GitChangesTests.gitEnvironment,
                                                   timeout: timeout, outputLimit: outputLimit)
            }
        }

        @discardableResult
        func git(_ folder: URL, _ arguments: String...) async throws -> String {
            try await supervisor.captureHelper("/usr/bin/git", ["-C", folder.path, "-c", "commit.gpgsign=false"] + arguments,
                                               environment: GitChangesTests.gitEnvironment, timeout: 30)
        }

        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func write(_ folder: URL, _ path: String, _ text: String) throws {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        /// A repository on `main` with a committed base, then `feature` one commit ahead, with uncommitted work on it.
        func featureRepository() async throws -> URL {
            let repo = try folder("repo")
            try await git(repo, "init", "-q", "-b", "main")
            try write(repo, ".gitignore", "ignored.log\n")
            try write(repo, "a.txt", "1\n2\n3\n")
            try write(repo, "sub/b.txt", "x\n")
            try await git(repo, "add", "-A")
            try await git(repo, "commit", "-q", "-m", "base")
            try await git(repo, "checkout", "-q", "-b", "feature")
            try write(repo, "a.txt", "1\ntwo\n3\n")
            try await git(repo, "commit", "-q", "-am", "committed on the branch")
            // main moves on after the branch left it: that is not part of the branch.
            try await git(repo, "checkout", "-q", "main")
            try write(repo, "main-only.txt", "m\n")
            try await git(repo, "add", "-A")
            try await git(repo, "commit", "-q", "-m", "main moves")
            try await git(repo, "checkout", "-q", "feature")
            // Uncommitted: a tracked change, an untracked file, an ignored one.
            try write(repo, "sub/b.txt", "x\ny\n")
            try write(repo, "new.txt", "n1\nn2\n")
            try write(repo, "ignored.log", "noise\n")
            return repo
        }

        func cleanup() async {
            _ = await supervisor.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func rig() throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-git-changes-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Rig(supervisor: try ProcessSupervisor(ledger: OwnershipLedger()), root: root)
    }

    private func listOf(_ state: GitChangesState) throws -> GitChangeList {
        guard case let .list(list) = state else { throw ListError.notAList("\(state)") }
        return list
    }

    private enum ListError: Error { case notAList(String) }

    // MARK: The list

    @Test func theBranchListHasTheMergeBaseDiffTheUncommittedWorkAndTheUntrackedFiles() async throws {
        let rig = try rig()
        let repo = try await rig.featureRepository()
        let list = try listOf(await rig.reader().list(directory: repo.path))
        #expect(list.baseName == "main" && !list.onBase && list.omittedFiles == 0)
        #expect(list.files.map(\.path) == ["a.txt", "new.txt", "sub/b.txt"], "main's own commit and the ignored file are not part of it")
        let byPath = Dictionary(uniqueKeysWithValues: list.files.map { ($0.path, $0) })
        let changed = try #require(byPath["a.txt"]), tracked = try #require(byPath["sub/b.txt"]), untracked = try #require(byPath["new.txt"])
        #expect(changed.added == 1 && changed.removed == 1 && changed.status == .modified)
        #expect(tracked.added == 1 && tracked.removed == 0)
        #expect(untracked.added == 2 && untracked.removed == 0 && untracked.status == .untracked)
        #expect(list.absolutePath(of: untracked).hasSuffix("/repo/new.txt"))

        // One file's diff: the hunk with its numbers.
        let diff = await rig.reader().diff(of: changed, in: list)
        guard case let .hunks(hunks) = diff else { Issue.record("not hunks: \(diff)"); return }
        #expect(hunks == [DiffHunk(oldStart: 1, oldLines: 3, newStart: 1, newLines: 3, lines: [" 1", "-2", "+two", " 3"])])
        #expect(hunks[0].rows.map(\.newNumber) == [1, nil, 2, 3] && hunks[0].rows.map(\.oldNumber) == [1, 2, nil, 3])
        // An untracked file is all added lines.
        let added = await rig.reader().diff(of: untracked, in: list)
        #expect(added == .hunks([DiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 2, lines: ["+n1", "+n2"])]))
        await rig.cleanup()
    }

    /// Loom only reads: a command the repository's own config names (`core.fsmonitor`, a hook git would start while it
    /// looks at the working tree) never runs for the list or a file's diff.
    @Test func aCommandTheRepositorysConfigNamesNeverRuns() async throws {
        let rig = try rig()
        let repo = try await rig.featureRepository()
        let mark = rig.root.appendingPathComponent("fsmonitor-ran")
        let hook = rig.root.appendingPathComponent("fsmonitor-hook")
        try "#!/bin/sh\ntouch '\(mark.path)'\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try await rig.git(repo, "config", "core.fsmonitor", hook.path)
        let list = try listOf(await rig.reader().list(directory: repo.path))
        for file in list.files { _ = await rig.reader().diff(of: file, in: list) }
        #expect(!FileManager.default.fileExists(atPath: mark.path))
        await rig.cleanup()
    }

    @Test func onTheBaseBranchTheListIsTheUncommittedChanges() async throws {
        let rig = try rig()
        let repo = try await rig.featureRepository()
        try await rig.git(repo, "stash", "-q", "-u")
        try await rig.git(repo, "checkout", "-q", "main")
        try rig.write(repo, "a.txt", "1\n2\n3\n4\n")
        let list = try listOf(await rig.reader().list(directory: repo.path))
        #expect(list.onBase && list.baseName == "main")
        #expect(list.files.map(\.path) == ["a.txt"] && list.files.first?.added == 1)
        await rig.cleanup()
    }

    @Test func theBaseBranchIsWhereOriginHeadPointsElseMainElseMaster() async throws {
        let rig = try rig()
        // A clone whose origin calls its default branch "develop": origin/HEAD wins, and there is no local main.
        let source = try rig.folder("source")
        try await rig.git(source, "init", "-q", "-b", "develop")
        try rig.write(source, "f.txt", "1\n")
        try await rig.git(source, "add", "-A")
        try await rig.git(source, "commit", "-q", "-m", "base")
        let clone = rig.root.appendingPathComponent("clone")
        try await rig.supervisor.captureHelper("/usr/bin/git", ["clone", "-q", source.path, clone.path],
                                               environment: Self.gitEnvironment, timeout: 30)
        try await rig.git(clone, "checkout", "-q", "-b", "topic")
        try rig.write(clone, "f.txt", "1\n2\n")
        let fromOrigin = try listOf(await rig.reader().list(directory: clone.path))
        #expect(fromOrigin.baseName == "develop" && !fromOrigin.onBase && fromOrigin.files.map(\.path) == ["f.txt"])

        // master, when there is no main and no origin.
        let old = try rig.folder("old")
        try await rig.git(old, "init", "-q", "-b", "master")
        try rig.write(old, "f.txt", "1\n")
        try await rig.git(old, "add", "-A")
        try await rig.git(old, "commit", "-q", "-m", "base")
        try await rig.git(old, "checkout", "-q", "-b", "topic")
        #expect(try listOf(await rig.reader().list(directory: old.path)).baseName == "master")
        await rig.cleanup()
    }

    @Test func noBaseBranchAndNoRepositoryTurnTheScopeOff() async throws {
        let rig = try rig()
        let trunk = try rig.folder("trunk")
        try await rig.git(trunk, "init", "-q", "-b", "trunk")
        try rig.write(trunk, "f.txt", "1\n")
        try await rig.git(trunk, "add", "-A")
        try await rig.git(trunk, "commit", "-q", "-m", "base")
        #expect(await rig.reader().list(directory: trunk.path) == .noBaseBranch)
        // A repository with no commit has no base branch either.
        let empty = try rig.folder("empty")
        try await rig.git(empty, "init", "-q", "-b", "main")
        #expect(await rig.reader().list(directory: empty.path) == .noBaseBranch)
        #expect(await rig.reader().list(directory: try rig.folder("plain").path) == .notARepository)
        #expect(await rig.reader().list(directory: rig.root.appendingPathComponent("missing").path) == .notARepository)
        await rig.cleanup()
    }

    // MARK: The bounds

    @Test func aDiffOverTheByteBoundOrTheLineBoundIsTooLargeAndNothingElseIsAffected() async throws {
        let rig = try rig()
        let repo = try await rig.featureRepository()
        try rig.write(repo, "big.txt", (0..<400).map { "line \($0)" }.joined(separator: "\n") + "\n")
        try await rig.git(repo, "add", "big.txt")
        var bytes = GitChanges.Limits()
        bytes.diffBytes = 300
        let reader = rig.reader(bytes)
        let list = try listOf(await reader.list(directory: repo.path))
        let big = try #require(list.files.first { $0.path == "big.txt" })
        let small = try #require(list.files.first { $0.path == "sub/b.txt" })
        #expect(big.added == 400 && big.status == .modified)
        #expect(await reader.diff(of: big, in: list) == .tooLarge, "git's answer is stopped at the byte limit")
        #expect(await reader.diff(of: small, in: list) != .tooLarge)

        var lines = GitChanges.Limits()
        lines.diffLines = 100
        let linesReader = rig.reader(lines)
        #expect(await linesReader.diff(of: big, in: list) == .tooLarge, "401 diff lines are over the line bound")
        // An untracked file over the bound is marked in the list, and its diff is not built.
        try rig.write(repo, "huge.txt", String(repeating: "x\n", count: 500))
        let again = try listOf(await linesReader.list(directory: repo.path))
        let huge = try #require(again.files.first { $0.path == "huge.txt" })
        #expect(huge.isTooLarge)
        #expect(await linesReader.diff(of: huge, in: again) == .tooLarge)
        await rig.cleanup()
    }

    @Test func aHelperOutputOverItsLimitStopsWithTheSizedError() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let fake = RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider").path
        var failure: (any Error)?
        do { _ = try await supervisor.captureHelper(fake, ["--probe-flood"], environment: [:], timeout: 10, outputLimit: 1_000) }
        catch { failure = error }
        guard case let LoomError.outputTooLarge(limit)? = failure else { Issue.record("got \(String(describing: failure))"); return }
        #expect(limit == 1_000)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func aGitThatDoesNotAnswerHitsItsTimeoutInsteadOfWaiting() async throws {
        let rig = try rig()
        let script = rig.root.appendingPathComponent("hung-git")
        try "#!/bin/sh\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var limits = GitChanges.Limits()
        limits.listTimeout = 0.6
        limits.fileTimeout = 0.6
        let reader = GitChanges.live(supervisor: rig.supervisor, executable: script.path, limits: limits)
        let clock = ContinuousClock()
        var state: GitChangesState?
        let listElapsed = await clock.measure { state = await reader.list(directory: rig.root.path) }
        #expect(state == .timedOut)
        #expect(listElapsed < .seconds(8), "took \(listElapsed)")

        let list = GitChangeList(root: rig.root.path, baseName: "main", onBase: false, compareTo: "HEAD", files: [], omittedFiles: 0)
        var diff: GitFileDiff?
        let fileElapsed = await clock.measure {
            diff = await reader.diff(of: GitChangeFile(path: "a.txt", status: .modified, added: 1, removed: 0), in: list)
        }
        #expect(diff == .timedOut)
        #expect(fileElapsed < .seconds(8), "took \(fileElapsed)")
        await rig.cleanup()
    }

    // MARK: Parsing

    @Test func aUnifiedDiffIsReadByItsCountsSoARemovedDashLineIsNotAHeader() {
        let text = """
        diff --git a/f b/f
        index 1..2 100644
        --- a/f
        +++ b/f
        @@ -1,2 +1,2 @@ func x()
         keep
        --- removed text that starts with dashes
        +added
        @@ -10 +10,2 @@
        -last
        \\ No newline at end of file
        +last
        +more

        """
        let parsed = UnifiedDiff.parse(text)
        #expect(parsed.hunks.count == 2 && !parsed.isBinary)
        #expect(parsed.hunks[0].lines == [" keep", "--- removed text that starts with dashes", "+added"])
        #expect(parsed.hunks[0].rows.map(\.oldNumber) == [1, 2, nil] && parsed.hunks[0].rows.map(\.newNumber) == [1, nil, 2])
        #expect(parsed.hunks[1].oldLines == 1 && parsed.hunks[1].newLines == 2)
        #expect(parsed.hunks[1].lines == ["-last", "\\ No newline at end of file", "+last", "+more"])
        #expect(parsed.hunks[1].rows.map(\.kind) == [.removed, .note, .added, .added])
        #expect(parsed.hunks[0].header == "@@ -1,2 +1,2 @@" && parsed.hunks[1].header == "@@ -10 +10,2 @@")
        #expect(UnifiedDiff.parse("Binary files a/x and b/x differ\n").isBinary)
    }

    @Test func numstatReadsRenamesAndBinaryFilesFromItsNulSeparatedForm() {
        let output = "3\t1\tsrc/a.swift\0-\t-\timage.png\00\t0\t\0old name.txt\0new name.txt\0"
        let files = GitChanges.parseNumstat(output)
        #expect(files == [
            GitChangeFile(path: "src/a.swift", status: .modified, added: 3, removed: 1),
            GitChangeFile(path: "image.png", status: .modified, added: 0, removed: 0, isBinary: true),
            GitChangeFile(path: "new name.txt", oldPath: "old name.txt", status: .renamed, added: 0, removed: 0),
        ])
    }
}
