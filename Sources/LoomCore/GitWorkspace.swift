import Foundation
import Synchronization

/// Creates the branch or worktree a draft's strip asked for (V07), right before the first send and never
/// earlier. It runs `git` as a short-lived child of Loom, outside any run scope, bounded in time and
/// output (ARCHITECTURE §4). It reads nothing else. It removes only what it made itself, and only through
/// `undo`, when the start that asked for it failed.
public enum GitWorkspace {
    public enum Failure: Error, Equatable, LocalizedError, CustomStringConvertible, Sendable {
        case notARepository(String)
        case invalidBranchName(String)
        case branchExists(String)
        case worktreeFolderExists(String)
        case git(String)

        /// What a git call that outlived its deadline throws.
        static let timedOut = Failure.git("Git did not answer in time.")

        public var errorDescription: String? {
            switch self {
            case .notARepository(let folder): "\(folder) is not inside a Git repository."
            case .invalidBranchName(let name): "\"\(name)\" is not a valid branch name."
            case .branchExists(let name): "The branch \(name) already exists."
            case .worktreeFolderExists(let folder): "The folder \(folder) already exists."
            case .git(let message): message
            }
        }

        public var description: String { errorDescription ?? "Git failed." }
    }

    /// Where a worktree of a repository goes: Claude's own place for them, `<repository>/.claude/worktrees`,
    /// so the folder sits under the project and inherits its folder trust.
    public static func worktreeFolder(repository: String, branch: String) -> String {
        URL(fileURLWithPath: repository, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(folderName(for: branch), isDirectory: true).path
    }

    /// A branch name as one folder name: `feat/PAY-418-note` becomes `feat-PAY-418-note`.
    public static func folderName(for branch: String) -> String {
        let mapped = branch.unicodeScalars.map { scalar -> Character in
            let keep = (scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar))))
                || ".-_".unicodeScalars.contains(scalar)
            return keep ? Character(scalar) : "-"
        }
        let name = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return name.isEmpty ? "session" : name
    }

    /// What `begin` made, and what takes it away again.
    public struct Prepared: Sendable, Equatable {
        /// The folder Claude starts in.
        public let folder: String
        fileprivate let undo: Undo?

        fileprivate enum Undo: Sendable, Equatable {
            /// The branch `name` was created and checked out in `projectFolder`; `previous` was checked out before.
            case branch(projectFolder: String, name: String, previous: Previous)
            /// The worktree at `folder` on the new branch `name`, in the repository at `root`. `parents` are the
            /// folders of `.claude/worktrees` that did not exist before and go again when empty.
            case worktree(root: String, folder: String, name: String, parents: [String])
        }

        fileprivate enum Previous: Sendable, Equatable {
            case branch(String)
            case detached(String)
        }
    }

    /// Makes what `workspace` asks for and returns the folder Claude starts in: the project folder itself
    /// (`.projectFolder`, nothing touched), the project folder on the new branch, or the same place inside
    /// the new worktree. The branch is created from the current HEAD; an existing branch or folder is an
    /// error and nothing is overwritten.
    public static func prepare(
        _ workspace: SessionWorkspace, projectFolder: String, git: String = "/usr/bin/git",
        timeout: TimeInterval = 30
    ) async throws -> String {
        try await begin(workspace, projectFolder: projectFolder, git: git, timeout: timeout).folder
    }

    /// `prepare`, keeping what it takes to put things back (`undo`).
    public static func begin(
        _ workspace: SessionWorkspace, projectFolder: String, git: String = "/usr/bin/git",
        timeout: TimeInterval = 30
    ) async throws -> Prepared {
        switch workspace {
        case .projectFolder:
            return Prepared(folder: projectFolder, undo: nil)
        case .newBranch(let name):
            try await check(name, projectFolder: projectFolder, git: git, timeout: timeout)
            let head = try await run(git, ["-C", projectFolder, "rev-parse", "--abbrev-ref", "HEAD"], timeout: timeout)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var previous = Prepared.Previous.branch(head)
            if head == "HEAD" {
                let sha = try await run(git, ["-C", projectFolder, "rev-parse", "HEAD"], timeout: timeout)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                previous = .detached(sha)
            }
            let made = Prepared(folder: projectFolder, undo: .branch(projectFolder: projectFolder, name: name, previous: previous))
            try await changing(made, git: git, timeout: timeout) {
                _ = try await run(git, ["-C", projectFolder, "switch", "-c", name], timeout: timeout)
            }
            return made
        case .newWorktree(let name):
            try await check(name, projectFolder: projectFolder, git: git, timeout: timeout)
            let root = try await repositoryRoot(of: projectFolder, git: git, timeout: timeout)
            let folder = worktreeFolder(repository: root, branch: name)
            guard !FileManager.default.fileExists(atPath: folder) else { throw Failure.worktreeFolderExists(folder) }
            let claude = URL(fileURLWithPath: root).appendingPathComponent(".claude", isDirectory: true).path
            let worktrees = claude + "/worktrees"
            let parents = [worktrees, claude].filter { !FileManager.default.fileExists(atPath: $0) }
            // A project that is a subfolder of its repository starts at the same place in the worktree.
            let relative = relativePath(of: projectFolder, in: root)
            let start = relative.isEmpty ? folder : URL(fileURLWithPath: folder).appendingPathComponent(relative).path
            let made = Prepared(folder: start, undo: .worktree(root: root, folder: folder, name: name, parents: parents))
            try await changing(made, git: git, timeout: timeout) {
                _ = try await run(git, ["-C", root, "worktree", "add", "-b", name, folder], timeout: timeout)
            }
            return made
        }
    }

    /// Runs the git call that changes the repository. When it outlived its deadline the change may have been made
    /// (a `post-checkout` hook that never returns runs after the switch), so it is put back before the failure
    /// goes on; any other failure changed nothing (the name was checked free) and is passed on as it is.
    private static func changing(_ made: Prepared, git: String, timeout: TimeInterval,
                                 _ call: () async throws -> Void) async throws {
        do {
            try await call()
        } catch let failure as Failure where failure == .timedOut {
            let problems = await undo(made, git: git, timeout: timeout)
            guard !problems.isEmpty else { throw failure }
            throw Failure.git("\(failure). Not undone: \(problems.joined(separator: "; "))")
        }
    }

    /// Puts back what `begin` made, after a start that failed: for a new branch, the old branch is checked out
    /// and the new one deleted; for a new worktree, the worktree is removed and its branch deleted. Returns what
    /// could not be undone, one sentence each; nothing when all went back (or nothing was made).
    public static func undo(
        _ prepared: Prepared, git: String = "/usr/bin/git", timeout: TimeInterval = 30
    ) async -> [String] {
        guard let undo = prepared.undo else { return [] }
        var problems: [String] = []
        func attempt(_ what: String, _ arguments: [String]) async -> Bool {
            do {
                // Without the repository's hooks: putting a change back must not wait for the hook that hung it.
                _ = try await run(git, ["-c", "core.hooksPath=/dev/null"] + arguments, timeout: timeout)
                return true
            } catch {
                problems.append("\(what): \(error)")
                return false
            }
        }
        switch undo {
        case .branch(let folder, let name, let previous):
            let back: [String]
            switch previous {
            case .branch(let old): back = ["-C", folder, "switch", old]
            case .detached(let sha): back = ["-C", folder, "switch", "--detach", sha]
            }
            // The new branch is deleted only once it is no longer checked out.
            if await attempt("Could not go back to the previous branch, so the new branch \(name) stays", back) {
                _ = await attempt("Could not delete the new branch \(name)", ["-C", folder, "branch", "-D", name])
            }
        case .worktree(let root, let folder, let name, let parents):
            if await attempt("Could not remove the new worktree \(folder)", ["-C", root, "worktree", "remove", "--force", folder]) {
                _ = await attempt("Could not delete the new branch \(name)", ["-C", root, "branch", "-D", name])
                // Folders this start made for it and nothing else is in: they go too, deepest first.
                for parent in parents {
                    if (try? FileManager.default.contentsOfDirectory(atPath: parent))?.isEmpty == true {
                        try? FileManager.default.removeItem(atPath: parent)
                    }
                }
            }
        }
        return problems
    }

    /// The branch name is valid for Git and free; the folder is inside a repository.
    private static func check(_ name: String, projectFolder: String, git: String, timeout: TimeInterval) async throws {
        guard !name.hasPrefix("-"), !name.isEmpty else { throw Failure.invalidBranchName(name) }
        let root = try await repositoryRoot(of: projectFolder, git: git, timeout: timeout)
        do { _ = try await run(git, ["check-ref-format", "--branch", name], timeout: timeout) }
        catch { throw Failure.invalidBranchName(name) }
        let taken = try? await run(git, ["-C", root, "show-ref", "--verify", "--quiet", "refs/heads/\(name)"],
                                   timeout: timeout)
        if taken != nil { throw Failure.branchExists(name) }
    }

    private static func repositoryRoot(of folder: String, git: String, timeout: TimeInterval) async throws -> String {
        do {
            let output = try await run(git, ["-C", folder, "rev-parse", "--show-toplevel"], timeout: timeout)
            let root = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !root.isEmpty else { throw Failure.notARepository(folder) }
            return root
        } catch let failure as Failure {
            if case .git = failure { throw Failure.notARepository(folder) }
            throw failure
        }
    }

    private static func relativePath(of folder: String, in root: String) -> String {
        let folderPath = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        let rootPath = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        guard folderPath.hasPrefix(rootPath + "/") else { return "" }
        return String(folderPath.dropFirst(rootPath.count + 1))
    }

    /// One `git` call: no prompts, no user pager, output capped at 64 KiB, killed after `timeout`. A failure
    /// carries git's own first line. The reads stop at the deadline, at the cap and when git has exited, not at
    /// the end of the pipe: a hook that leaves a background child holding the pipe cannot keep the call waiting.
    ///
    /// The waiting is done on a thread of its own (the call is made of sleeps and polls for up to `timeout`
    /// plus a few seconds), never on a thread of Swift's cooperative pool: several git steps at once, or one
    /// that hangs on a hook, must not starve the async work of the rest of the app.
    static func run(_ git: String, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            let thread = Thread {
                continuation.resume(with: Result { try runBlocking(git, arguments, timeout: timeout) })
            }
            thread.name = "loom.git"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// `run`'s body: blocks the calling thread until git has exited, the deadline has passed or the output is read.
    private static func runBlocking(_ git: String, _ arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "HOME": NSHomeDirectory(), "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat",
        ]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure.git("Git could not be started.") }
        let deadline = Date().addingTimeInterval(timeout)
        let timedOut = Mutex(false)
        let watchdog = DispatchWorkItem {
            timedOut.withLock { $0 = true }
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Stderr is read on its own thread so neither pipe can fill and stall the child.
        let errorData = Mutex(Data())
        let errorHandle = errors.fileHandleForReading
        let finished = Mutex(false)
        let drain = Thread {
            let data = readCapped(errorHandle.fileDescriptor, process: process, deadline: deadline)
            errorData.withLock { $0 = data }
            finished.withLock { $0 = true }
        }
        drain.start()
        let data = readCapped(output.fileHandleForReading.fileDescriptor, process: process, deadline: deadline)
        while !finished.withLock({ $0 }) { usleep(1_000) }
        try? output.fileHandleForReading.close()
        try? errorHandle.close()
        // The pipes are done; git may still be exiting. Past the deadline it is told to end and only reaped.
        while process.isRunning, Date() < deadline { usleep(2_000) }
        if process.isRunning {
            timedOut.withLock { $0 = true }
            process.terminate()
        }
        watchdog.cancel()
        let reapBy = Date().addingTimeInterval(2)
        while process.isRunning, Date() < reapBy { usleep(2_000) }
        if timedOut.withLock({ $0 }) || process.isRunning { throw Failure.timedOut }
        guard process.terminationStatus == 0 else {
            let text = String(decoding: errorData.withLock { $0 }, as: UTF8.self)
            let line = text.split(separator: "\n").first.map(String.init) ?? "Git exited with status \(process.terminationStatus)."
            throw Failure.git(line)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads a pipe until its end, or until the process has exited and nothing more is waiting, or the deadline:
    /// keeps the first 64 KiB and drops the rest (still reading it, so the writer never blocks).
    private static func readCapped(_ descriptor: Int32, process: Process, deadline: Date) -> Data {
        var kept = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while Date() < deadline {
            var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&entry, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                // Quiet: finished when git is gone (a child that kept the pipe open writes nothing we wait for).
                if !process.isRunning { break }
                continue
            }
            let count = read(descriptor, &chunk, chunk.count)
            if count > 0 {
                if kept.count < 65_536 { kept.append(contentsOf: chunk.prefix(min(count, 65_536 - kept.count))) }
            } else if count == 0 {
                break
            } else if errno != EINTR && errno != EAGAIN {
                break
            }
        }
        return kept
    }
}
