import Foundation

/// How a file differs from the base.
public enum GitChangeStatus: Equatable, Sendable {
    /// Added, changed or deleted in a tracked file: the counts tell which.
    case modified
    case renamed
    /// Not tracked and not ignored: shown as an added file.
    case untracked
}

/// One file of the branch's change list.
public struct GitChangeFile: Equatable, Sendable, Identifiable {
    /// The path below the repository root.
    public var path: String
    /// The path before a rename.
    public var oldPath: String?
    public var status: GitChangeStatus
    public var added: Int
    public var removed: Int
    public var isBinary: Bool
    /// Its diff is over the reader's bounds; the counts are zero for an untracked file this large.
    public var isTooLarge: Bool

    public var id: String { path }

    public init(path: String, oldPath: String? = nil, status: GitChangeStatus, added: Int, removed: Int,
                isBinary: Bool = false, isTooLarge: Bool = false) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.added = added
        self.removed = removed
        self.isBinary = isBinary
        self.isTooLarge = isTooLarge
    }
}

/// The working tree against the merge base with the base branch.
public struct GitChangeList: Equatable, Sendable {
    /// The repository's top folder.
    public var root: String
    /// The base branch as the user reads it: "main".
    public var baseName: String
    /// The session's branch is the base branch: the list is the uncommitted changes against HEAD.
    public var onBase: Bool
    /// What the files are compared with (a commit id).
    public var compareTo: String
    public var files: [GitChangeFile]
    /// Files past the reader's cap, not listed.
    public var omittedFiles: Int

    public init(root: String, baseName: String, onBase: Bool, compareTo: String, files: [GitChangeFile], omittedFiles: Int = 0) {
        self.root = root
        self.baseName = baseName
        self.onBase = onBase
        self.compareTo = compareTo
        self.files = files
        self.omittedFiles = omittedFiles
    }

    public func absolutePath(of file: GitChangeFile) -> String { root + "/" + file.path }
}

/// What the Branch scope shows: a list, or the reason it is off or failed.
public enum GitChangesState: Equatable, Sendable {
    case notARepository
    /// Neither `origin/HEAD`, `main` nor `master` exists.
    case noBaseBranch
    case timedOut
    case failed(String)
    case list(GitChangeList)
}

/// One file's diff.
public enum GitFileDiff: Equatable, Sendable {
    case hunks([DiffHunk])
    case binary
    /// Over the byte or the line bound.
    case tooLarge
    case timedOut
    case failed(String)
}

/// What the git calls of one read share. A read (`GitChanges.list`, or one file's `diff`) makes all its calls inside one `run`,
/// and whatever `run` opened (a run scope) is released when `body` returns or throws.
public protocol GitReadScope: Sendable {
    func run<Result: Sendable>(_ body: @Sendable (GitChanges.Capture) async throws -> Result) async throws -> Result
}

/// No shared scope: each call goes to the capture as it is.
struct DirectGitScope: GitReadScope {
    let capture: GitChanges.Capture

    func run<Result: Sendable>(_ body: @Sendable (GitChanges.Capture) async throws -> Result) async throws -> Result {
        try await body(capture)
    }
}

/// The supervisor's owned helpers, the calls of one read in one run scope (`ProcessSupervisor.withHelperScope`).
struct SupervisedGitScope: GitReadScope {
    let supervisor: ProcessSupervisor
    let executable: String
    let environment: [String: String]

    func run<Result: Sendable>(_ body: @Sendable (GitChanges.Capture) async throws -> Result) async throws -> Result {
        let executable = executable, environment = environment
        return try await supervisor.withHelperScope { helpers in
            try await body { arguments, timeout, outputLimit in
                try await helpers.capture(executable, arguments, environment: environment, timeout: timeout,
                                          outputLimit: outputLimit)
            }
        }
    }
}

/// Reads what changed in a Git folder, for the Changes tab's Branch scope. Read only, and never more than the list and
/// one file's diff at a time. Git runs as an owned, bounded helper (`ProcessSupervisor.withHelperScope`: one run scope per read): a fixed
/// environment, `--no-optional-locks`, a deadline per call and a byte limit on every answer.
public struct GitChanges: Sendable {
    public struct Limits: Equatable, Sendable {
        /// One list read (every git call of it shares the deadline).
        public var listTimeout: TimeInterval = 10
        public var fileTimeout: TimeInterval = 15
        /// A file whose diff is over either bound is "too large".
        public var diffBytes = 1_048_576
        public var diffLines = 2_000
        /// The list keeps this many files and says how many more there were.
        public var maxFiles = 1_000

        public init() {}
    }

    /// Runs `git` with these arguments and returns its standard output; throws on a non-zero exit, a timeout, an output
    /// over `outputLimit` or any other failure.
    public typealias Capture = @Sendable (_ arguments: [String], _ timeout: TimeInterval, _ outputLimit: Int) async throws -> String

    private let scope: any GitReadScope
    private let limits: Limits

    /// Every call goes straight to `capture`, with nothing shared (tests).
    public init(limits: Limits = Limits(), capture: @escaping Capture) {
        self.limits = limits
        self.scope = DirectGitScope(capture: capture)
    }

    public init(limits: Limits = Limits(), scope: any GitReadScope) {
        self.limits = limits
        self.scope = scope
    }

    /// Git through the supervisor's owned helper path, with the fixed environment of `CleanupWorktreeProtection.live`. The git
    /// calls of one read run in one run scope (`ProcessSupervisor.withHelperScope`), each as its own owned, bounded job.
    public static func live(supervisor: ProcessSupervisor, executable: String = "/usr/bin/git",
                            limits: Limits = Limits()) -> GitChanges {
        let environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LC_ALL": "C",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        return GitChanges(limits: limits, scope: SupervisedGitScope(
            supervisor: supervisor, executable: executable, environment: environment))
    }

    // MARK: The list

    /// The files of `directory`'s repository that differ from the merge base with the base branch: tracked changes
    /// (uncommitted ones included) and untracked files that are not ignored.
    public func list(directory: String) async -> GitChangesState {
        do {
            return try await scope.run { capture in try await self.list(directory: directory, capture: capture) }
        } catch {
            return Self.state(for: error)
        }
    }

    private func list(directory: String, capture: Capture) async throws -> GitChangesState {
        let started = ProcessInfo.processInfo.systemUptime
        func budget() -> TimeInterval { max(0.5, limits.listTimeout - (ProcessInfo.processInfo.systemUptime - started)) }
        let outputLimit = 4 * 1024 * 1024
        do {
            let top: String
            do {
                top = try await capture(Self.safety + ["-C", directory, "rev-parse", "--show-toplevel"], budget(), 64 * 1024)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch LoomError.helperExit { return .notARepository }
            guard !top.isEmpty else { return .notARepository }
            let base = Self.safety + ["--literal-pathspecs", "-C", top]

            func attempt(_ arguments: [String]) async throws -> String? {
                do { return try await capture(base + arguments, budget(), outputLimit) } catch LoomError.helperExit { return nil }
            }

            // The base branch: where origin/HEAD points, else a local main, else master.
            var baseRef: String?
            var baseName = ""
            if let target = try await attempt(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"])?
                .trimmingCharacters(in: .whitespacesAndNewlines), target.hasPrefix("refs/remotes/"),
               try await attempt(["rev-parse", "--verify", "--quiet", target + "^{commit}"]) != nil {
                baseRef = target
                // "refs/remotes/origin/main" is read as "main" (the remote's name is dropped).
                baseName = target.dropFirst("refs/remotes/".count).split(separator: "/", maxSplits: 1).last.map(String.init) ?? target
            }
            if baseRef == nil {
                for name in ["main", "master"] {
                    if try await attempt(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)^{commit}"]) != nil {
                        baseRef = "refs/heads/\(name)"
                        baseName = name
                        break
                    }
                }
            }
            guard let baseRef else { return .noBaseBranch }

            let current = try await attempt(["symbolic-ref", "--quiet", "--short", "HEAD"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let onBase = current == baseName
            var compareTo = "HEAD"
            if !onBase {
                guard let mergeBase = try await attempt(["merge-base", baseRef, "HEAD"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !mergeBase.isEmpty else {
                    return .failed("No common history with \(baseName)")
                }
                compareTo = mergeBase
            } else if try await attempt(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]) == nil {
                return .noBaseBranch
            }

            let numstat = try await capture(
                base + ["diff", "--numstat", "-z", "-M", "--no-ext-diff", "--no-textconv", compareTo, "--"], budget(), outputLimit)
            var files = Self.parseNumstat(numstat)
            let untracked = try await capture(base + ["ls-files", "--others", "--exclude-standard", "-z"], budget(), outputLimit)
            for path in untracked.split(separator: "\0", omittingEmptySubsequences: true).map(String.init) {
                files.append(GitChangeFile(path: path, status: .untracked, added: 0, removed: 0))
            }
            files.sort { $0.path < $1.path }
            let omitted = max(0, files.count - limits.maxFiles)
            if omitted > 0 { files.removeLast(omitted) }
            // Only the untracked files that are listed are read, for their line counts.
            let topURL = URL(fileURLWithPath: top, isDirectory: true)
            for index in files.indices where files[index].status == .untracked {
                files[index] = untrackedFile(files[index].path, root: topURL)
            }
            return .list(GitChangeList(root: top, baseName: baseName, onBase: onBase, compareTo: compareTo,
                                       files: files, omittedFiles: omitted))
        } catch {
            return Self.state(for: error)
        }
    }

    /// `git diff --numstat -z`: "added TAB removed TAB path NUL", and for a rename "added TAB removed TAB NUL old NUL new NUL".
    /// A binary file has "-" for both counts.
    static func parseNumstat(_ output: String) -> [GitChangeFile] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var files: [GitChangeFile] = []
        var index = 0
        while index < fields.count {
            let parts = fields[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else {
                index += 1
                continue
            }
            let binary = parts[0] == "-"
            let added = Int(parts[0]) ?? 0
            let removed = Int(parts[1]) ?? 0
            if parts[2].isEmpty {
                guard index + 2 < fields.count else { break }
                files.append(GitChangeFile(path: fields[index + 2], oldPath: fields[index + 1], status: .renamed,
                                           added: added, removed: removed, isBinary: binary))
                index += 3
            } else {
                files.append(GitChangeFile(path: String(parts[2]), status: .modified, added: added, removed: removed,
                                           isBinary: binary))
                index += 1
            }
        }
        return files
    }

    /// An untracked file counts as all added lines, read from the file itself (nothing past the diff bound is read).
    private func untrackedFile(_ path: String, root: URL) -> GitChangeFile {
        let url = root.appendingPathComponent(path)
        var file = GitChangeFile(path: path, status: .untracked, added: 0, removed: 0)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else {
            return file
        }
        if (values.fileSize ?? 0) > limits.diffBytes {
            file.isTooLarge = true
            return file
        }
        guard let data = try? Data(contentsOf: url) else { return file }
        if data.prefix(8_000).contains(0) {
            file.isBinary = true
        } else {
            file.added = Self.lineCount(of: data)
            if file.added > limits.diffLines { file.isTooLarge = true }
        }
        return file
    }

    private static func lineCount(of data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        let newlines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return newlines + (data.last == 0x0A ? 0 : 1)
    }

    // MARK: One file

    /// The diff of one file of `list`, within the byte and line bounds.
    public func diff(of file: GitChangeFile, in list: GitChangeList) async -> GitFileDiff {
        if file.isBinary { return .binary }
        if file.isTooLarge { return .tooLarge }
        if file.status == .untracked { return untrackedDiff(file, root: list.root) }
        let arguments = Self.safety + ["--literal-pathspecs", "-C", list.root,
                                       "diff", "--no-color", "--no-ext-diff", "--no-textconv", "-M", "-U3", list.compareTo, "--"]
            + [file.oldPath, file.path].compactMap { $0 }
        do {
            let output = try await scope.run { capture in try await capture(arguments, self.limits.fileTimeout, self.limits.diffBytes) }
            let parsed = UnifiedDiff.parse(output)
            if parsed.isBinary { return .binary }
            return Self.bounded(parsed.hunks, lines: limits.diffLines)
        } catch LoomError.outputTooLarge {
            return .tooLarge
        } catch {
            switch Self.state(for: error) {
            case .timedOut: return .timedOut
            case let .failed(message): return .failed(message)
            default: return .failed("Git did not answer")
            }
        }
    }

    private func untrackedDiff(_ file: GitChangeFile, root: String) -> GitFileDiff {
        let url = URL(fileURLWithPath: root).appendingPathComponent(file.path)
        // The file may have grown since the list was read.
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > limits.diffBytes { return .tooLarge }
        guard let data = try? Data(contentsOf: url) else {
            return .failed("The file could not be read")
        }
        if data.prefix(8_000).contains(0) { return .binary }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let endsWithNewline = lines.last == ""
        if endsWithNewline { lines.removeLast() }
        if lines.isEmpty { return .hunks([]) }
        var hunkLines = lines.map { "+" + $0 }
        if !endsWithNewline { hunkLines.append("\\ No newline at end of file") }
        return Self.bounded([DiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: lines.count, lines: hunkLines)],
                            lines: limits.diffLines)
    }

    /// Before every call: no optional locks, and no command a repository's own config could start while Loom only reads
    /// (`core.fsmonitor`; the diffs also pass `--no-ext-diff` and `--no-textconv`).
    static let safety = ["-c", "core.fsmonitor=false", "--no-optional-locks"]

    private static func bounded(_ hunks: [DiffHunk], lines limit: Int) -> GitFileDiff {
        hunks.reduce(0) { $0 + $1.lines.count } > limit ? .tooLarge : .hunks(hunks)
    }

    private static func state(for error: any Error) -> GitChangesState {
        switch error {
        case LoomError.environmentTimeout: .timedOut
        case LoomError.outputTooLarge: .failed("Git printed more than Loom reads")
        case let LoomError.helperExit(_, detail): .failed(detail.isEmpty ? "Git did not answer" : detail)
        default: .failed("Git did not answer")
        }
    }
}
