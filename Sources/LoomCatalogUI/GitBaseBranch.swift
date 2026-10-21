import Foundation

/// The branch a session's branch is measured against, for the Overview's "branch → base". It reads files only, as
/// `GitBranch` does: no Git process runs. The answer is the repository's own default: `refs/remotes/origin/HEAD` (a symbolic
/// ref that `git clone` and `git remote set-head` write), else a local `main` or `master`. A folder in no repository, and a
/// repository that has neither, have no base.
enum GitBaseBranch {
    private static let originPrefix = "ref: refs/remotes/origin/"
    private static let smallBytes = 4_096
    private static let packedBytes = 1_048_576

    /// The base branch's name ("main") for the repository that holds `directory`, or nil when it is unknown.
    static func read(directory: String) -> String? {
        guard !directory.isEmpty, let gitDirectory = locate(directory: directory) else { return nil }
        // A linked worktree keeps its refs in the main repository: its `commondir` file names it.
        let common = commonDirectory(of: gitDirectory)
        if let origin = smallText(common.appendingPathComponent("refs/remotes/origin/HEAD"))?.trimmed,
           origin.hasPrefix(originPrefix) {
            let name = String(origin.dropFirst(originPrefix.count))
            if !name.isEmpty { return name }
        }
        let packed = packedBranches(common.appendingPathComponent("packed-refs"))
        for name in ["main", "master"] {
            let loose = common.appendingPathComponent("refs/heads/\(name)")
            if FileManager.default.fileExists(atPath: loose.path) || packed.contains(name) { return name }
        }
        return nil
    }

    /// The text of "→ base" for a session on `branch`: the base, unless it is unknown or is the branch itself.
    static func shown(base: String?, branch: String?) -> String? {
        guard let base, !base.isEmpty, base != branch else { return nil }
        return base
    }

    // MARK: Files

    /// The folder's own `.git` or the nearest parent's; a `.git` file points at the real directory (a worktree).
    private static func locate(directory: String) -> URL? {
        var root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        while true {
            let metadata = root.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: metadata.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return metadata }
                guard let pointer = smallText(metadata)?.trimmed, pointer.hasPrefix("gitdir: ") else { return nil }
                let path = String(pointer.dropFirst(8)).trimmed
                guard !path.isEmpty else { return nil }
                return path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true)
                    : root.appendingPathComponent(path, isDirectory: true).standardizedFileURL
            }
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { return nil }
            root = parent
        }
    }

    private static func commonDirectory(of gitDirectory: URL) -> URL {
        guard let pointer = smallText(gitDirectory.appendingPathComponent("commondir"))?.trimmed, !pointer.isEmpty else {
            return gitDirectory
        }
        return (pointer.hasPrefix("/") ? URL(fileURLWithPath: pointer, isDirectory: true)
            : gitDirectory.appendingPathComponent(pointer, isDirectory: true)).standardizedFileURL
    }

    /// The local branches `packed-refs` lists (a branch that was packed has no loose file).
    private static func packedBranches(_ file: URL) -> Set<String> {
        guard let handle = try? FileHandle(forReadingFrom: file), let data = try? handle.read(upToCount: packedBytes) else { return [] }
        try? handle.close()
        let prefix = "refs/heads/"
        var names: Set<String> = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let ref = line[line.index(after: space)...]
            if ref.hasPrefix(prefix) { names.insert(String(ref.dropFirst(prefix.count))) }
        }
        return names
    }

    private static func smallText(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: smallBytes + 1), data.count <= smallBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
