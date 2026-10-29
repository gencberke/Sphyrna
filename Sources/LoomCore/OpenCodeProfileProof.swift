import CryptoKit
import Darwin
import Foundation

/// A caller-supplied profile layout. The DB path is compared to native
/// `debug paths`; it is never inferred from an env override.
public struct OpenCodeProfileRoots: Equatable, Sendable {
    public let home: String
    public let data: String
    public let cache: String
    public let config: String
    public let state: String
    public let tmp: String
    public let bin: String
    public let log: String
    public let repos: String
    public let db: String

    public init(home: String, data: String, cache: String, config: String, state: String,
                tmp: String, bin: String, log: String, repos: String, db: String) {
        self.home = home; self.data = data; self.cache = cache; self.config = config; self.state = state
        self.tmp = tmp; self.bin = bin; self.log = log; self.repos = repos; self.db = db
    }

    fileprivate var directories: [String] { [home, data, cache, config, state, tmp, bin, log, repos] }
}

public enum OpenCodeProfileError: Error, Equatable, Sendable {
    case invalidOutput, unexpectedRoots, changed, unowned, unavailable
}

/// A short-lived in-memory proof for one resolved toolchain/environment. The
/// native helper is supervised, produces no model request, and is not cached.
public struct OpenCodeProfileProof: Sendable {
    public let roots: OpenCodeProfileRoots
    private let executable: String
    private let directory: String
    private let environmentHash: Data
    private let executableWitness: ExecutableWitness
    private let workingDirectoryWitness: PathWitness
    private let rootWitnesses: [PathWitness]
    private let databaseWitness: DatabaseWitness

    /// `expected` names the approved native path spellings. `expectedResolved`
    /// must come from the caller's independently authorized resolved layout,
    /// not from this helper's output.
    public static func acquire(supervisor: ProcessSupervisor, executable: String, environment: [String: String],
                               workingDirectory: String, expected: OpenCodeProfileRoots,
                               expectedResolved: OpenCodeProfileRoots, timeout: TimeInterval = 5) async throws -> Self {
        try Task.checkCancellation()
        guard supervisor.runScopesEnabled else { throw OpenCodeProfileError.unowned }
        guard timeout.isFinite, timeout > 0, timeout <= 10 else { throw OpenCodeProfileError.unavailable }
        let before = try await Task.detached {
            (try ExecutableWitness.read(executable), try PathWitness.directory(workingDirectory, owned: false),
             try Self.fingerprint(environment))
        }.value
        try Task.checkCancellation()
        let cancelled = OpenCodeProfileCancellation()
        let output: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let worker = Task.detached {
                try await supervisor.runOwnedJob(scope: .perCall) { _, job, spawner -> Result<Data, OpenCodeProfileCaptureError> in
                    do {
                        try cancelled.check()
                        let result = try LaunchEnvironment.capture(
                            executable, ["debug", "paths"], environment: environment, directory: workingDirectory,
                            timeout: timeout, outputLimit: 64 * 1024, spawner: spawner,
                            onSpawn: { pid in try cancelled.check(); try job.register(pid: pid) },
                            onPoll: { try cancelled.check(); try job.sample() }
                        )
                        defer { spawner.abort(result.pid) }
                        try cancelled.check()
                        guard result.status == 0 else { return .failure(.unavailable) }
                        return .success(result.stdout)
                    } catch {
                        if cancelled.isCancelled { return .failure(.cancelled) }
                        if let error = error as? LoomError, case .outputTooLarge = error { return .failure(.invalidOutput) }
                        return .failure(.unavailable)
                    }
                }
            }
            let result: Result<Data, OpenCodeProfileCaptureError>
            do { result = try await worker.value }
            catch {
                try Task.checkCancellation()
                throw OpenCodeProfileError.unavailable
            }
            try Task.checkCancellation()
            switch result {
            case let .success(data): return data
            case .failure(.cancelled): throw CancellationError()
            case .failure(.invalidOutput): throw OpenCodeProfileError.invalidOutput
            case .failure(.unavailable): throw OpenCodeProfileError.unavailable
            }
        } onCancel: { cancelled.cancel() }
        try Task.checkCancellation()
        let after = try await Task.detached {
            let actual = try Self.parse(output)
            guard actual == expected else { throw OpenCodeProfileError.unexpectedRoots }
            let executableNow = try ExecutableWitness.read(executable)
            let workingDirectoryNow = try PathWitness.directory(workingDirectory, owned: false)
            guard executableNow == before.0, workingDirectoryNow == before.1 else { throw OpenCodeProfileError.changed }
            let directories = try expected.directories.map { try PathWitness.directory($0, owned: true) }
            let database = try DatabaseWitness.read(expected.db)
            guard directories.map(\.resolved) == expectedResolved.directories,
                  database.resolved == expectedResolved.db else { throw OpenCodeProfileError.unexpectedRoots }
            return (executableNow, workingDirectoryNow, directories, database)
        }.value
        try Task.checkCancellation()
        return Self(roots: expected, executable: executable, directory: workingDirectory, environmentHash: before.2,
                    executableWitness: after.0, workingDirectoryWitness: after.1,
                    rootWitnesses: after.2, databaseWitness: after.3)
    }

    /// Revalidate at each attachment boundary, without printing any environment
    /// values. Ordinary stable symlinks are allowed but their targets are bound.
    public func validate(executable: String, environment: [String: String], workingDirectory: String) async throws {
        try Task.checkCancellation()
        guard self.executable == executable, directory == workingDirectory else { throw OpenCodeProfileError.changed }
        let current = try await Task.detached {
            (try Self.fingerprint(environment), try ExecutableWitness.read(executable),
             try PathWitness.directory(workingDirectory, owned: false),
             try roots.directories.map { try PathWitness.directory($0, owned: true) },
             try DatabaseWitness.read(roots.db))
        }.value
        try Task.checkCancellation()
        guard current.0 == environmentHash, current.1 == executableWitness,
              current.2 == workingDirectoryWitness, current.3 == rootWitnesses,
              databaseWitness.permits(current.4) else { throw OpenCodeProfileError.changed }
    }

    private static func parse(_ data: Data) throws -> OpenCodeProfileRoots {
        guard data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8),
              text.hasSuffix("\n"), !text.contains("\r"), !text.contains("\0") else {
            throw OpenCodeProfileError.invalidOutput
        }
        let lines = text.dropLast().split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 10 else { throw OpenCodeProfileError.invalidOutput }
        var fields: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                throw OpenCodeProfileError.invalidOutput
            }
            let key = String(line[..<separator])
            let path = String(line[separator...].drop(while: { $0 == " " || $0 == "\t" }))
            guard ["home", "data", "cache", "config", "state", "tmp", "bin", "log", "repos", "db"].contains(key),
                  fields[key] == nil, path.hasPrefix("/"), path.utf8.count <= 4096 else {
                throw OpenCodeProfileError.invalidOutput
            }
            fields[key] = path
        }
        guard fields.count == 10, let home = fields["home"], let data = fields["data"], let cache = fields["cache"],
              let config = fields["config"], let state = fields["state"], let tmp = fields["tmp"],
              let bin = fields["bin"], let log = fields["log"], let repos = fields["repos"], let db = fields["db"] else {
            throw OpenCodeProfileError.invalidOutput
        }
        return OpenCodeProfileRoots(home: home, data: data, cache: cache, config: config, state: state,
                                    tmp: tmp, bin: bin, log: log, repos: repos, db: db)
    }

    private static func fingerprint(_ environment: [String: String]) throws -> Data {
        guard environment.count <= 4096 else { throw OpenCodeProfileError.unavailable }
        var bytes = 0
        var hasher = SHA256()
        for key in environment.keys.sorted() {
            guard let value = environment[key], !key.isEmpty, !key.contains("="), !key.contains("\0"),
                  !value.contains("\0") else { throw OpenCodeProfileError.unavailable }
            bytes += key.utf8.count + value.utf8.count
            guard bytes <= 1024 * 1024 else { throw OpenCodeProfileError.unavailable }
            hasher.update(data: Data("\(key.utf8.count):".utf8))
            hasher.update(data: Data(key.utf8))
            hasher.update(data: Data("\(value.utf8.count):".utf8))
            hasher.update(data: Data(value.utf8))
        }
        return Data(hasher.finalize())
    }
}

private enum OpenCodeProfileCaptureError: Error, Sendable { case cancelled, invalidOutput, unavailable }
private final class OpenCodeProfileCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if isCancelled { throw CancellationError() } }
}

private struct FileNode: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let uid: uid_t
    let mode: mode_t
    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; uid = info.st_uid; mode = info.st_mode
    }
}

/// Both the named node and its followed target are held; a stable symlink is
/// legitimate, while replacing or retargeting it invalidates the witness.
private struct PathWitness: Equatable, Sendable {
    let node: FileNode
    let target: FileNode
    let resolved: String

    static func directory(_ path: String, owned: Bool) throws -> Self {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0") else { throw OpenCodeProfileError.invalidOutput }
        var node = stat(), target = stat()
        guard lstat(path, &node) == 0, stat(path, &target) == 0,
              target.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              node.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) || node.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
              !owned || (node.st_uid == geteuid() && target.st_uid == geteuid()) else { throw OpenCodeProfileError.unowned }
        return Self(node: FileNode(node), target: FileNode(target), resolved: try resolvedPath(path))
    }
}

private struct ExecutableWitness: Equatable, Sendable {
    let node: FileNode
    let target: FileNode
    let stamp: ExecutableStamp
    let resolved: String

    static func read(_ path: String) throws -> Self {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0") else { throw OpenCodeProfileError.unavailable }
        var node = stat(), target = stat()
        guard lstat(path, &node) == 0, stat(path, &target) == 0,
              target.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              node.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) || node.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
              (node.st_uid == geteuid() || node.st_uid == 0), (target.st_uid == geteuid() || target.st_uid == 0),
              access(path, X_OK) == 0, let stamp = ExecutableStamp.read(path) else { throw OpenCodeProfileError.unowned }
        return Self(node: FileNode(node), target: FileNode(target), stamp: stamp, resolved: try resolvedPath(path))
    }
}

private struct DatabaseWitness: Sendable {
    private enum Kind: Equatable, Sendable { case absent, regular, symlink(PathWitness) }
    let parent: PathWitness
    let resolved: String
    private let kind: Kind

    static func read(_ path: String) throws -> Self {
        guard path.hasPrefix("/"), !path.hasSuffix("/"), path.utf8.count <= 4096, !path.contains("\0") else {
            throw OpenCodeProfileError.invalidOutput
        }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw OpenCodeProfileError.invalidOutput }
        let parent = try PathWitness.directory(url.deletingLastPathComponent().path, owned: true)
        var node = stat(), target = stat()
        if lstat(path, &node) != 0 {
            guard errno == ENOENT else { throw OpenCodeProfileError.unowned }
            let resolved = URL(fileURLWithPath: parent.resolved, isDirectory: true).appendingPathComponent(name).path
            return Self(parent: parent, resolved: resolved, kind: .absent)
        }
        guard node.st_uid == geteuid(), stat(path, &target) == 0, target.st_uid == geteuid(),
              target.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw OpenCodeProfileError.unowned }
        switch node.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): return Self(parent: parent, resolved: try resolvedPath(path), kind: .regular)
        case mode_t(S_IFLNK):
            let resolved = try resolvedPath(path)
            return Self(parent: parent, resolved: resolved,
                        kind: .symlink(PathWitness(node: FileNode(node), target: FileNode(target), resolved: resolved)))
        default: throw OpenCodeProfileError.unowned
        }
    }

    func permits(_ current: Self) -> Bool {
        guard parent == current.parent, resolved == current.resolved else { return false }
        switch (kind, current.kind) {
        case (.absent, .absent), (.absent, .regular), (.regular, .absent), (.regular, .regular): return true
        case let (.symlink(previous), .symlink(next)): return previous == next
        default: return false
        }
    }
}

private func resolvedPath(_ path: String) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(path, &buffer) != nil else { throw OpenCodeProfileError.unowned }
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}
