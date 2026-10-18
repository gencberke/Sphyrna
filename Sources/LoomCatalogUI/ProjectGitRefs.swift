import Foundation

/// One local branch of a project's repository.
struct ProjectBranch: Equatable, Identifiable, Sendable {
    let name: String
    /// The branch the project's own folder has checked out.
    let isCurrent: Bool
    /// When the branch's ref file last changed. Nil for a branch that only lives in `packed-refs`.
    let updated: Date?
    /// The folder of another worktree that has this branch checked out (never the project's own folder).
    let worktree: String?

    var id: String { name }
}

/// The local branches and worktrees of a project's repository, read from its `.git` files when the project
/// page opens. No process runs; every read is capped (`ProjectGitRefs`).
struct ProjectBranches: Equatable, Sendable {
    let current: GitBranch
    let branches: [ProjectBranch]
    /// More branches or worktrees exist than were read.
    let truncated: Bool
}

/// Reads a repository's refs from files: `HEAD`, the loose files under `refs/heads`, `packed-refs` and the
/// linked worktrees' `HEAD` and `gitdir` files. It never launches Git and follows no link out of the
/// repository except the `gitdir` and `commondir` pointers a worktree itself carries.
enum ProjectGitRefs {
    /// The most branches listed.
    static let maxBranches = 300
    /// The most directory entries `refs/heads` is walked through.
    static let maxEntries = 2_000
    static let maxDepth = 8
    /// The most `packed-refs` bytes read.
    static let maxPackedBytes = 1_048_576
    /// The most linked worktrees read.
    static let maxWorktrees = 50
    private static let smallBytes = 4_096

    /// The branches of the repository that holds `directory` (the folder itself or a parent), or nil when
    /// it is in no repository or its `HEAD` cannot be read.
    static func read(directory: String) -> ProjectBranches? {
        guard let location = locate(directory: directory),
              let head = smallText(location.gitDirectory.appendingPathComponent("HEAD"))?.trimmed else { return nil }
        let current: GitBranch
        if head.hasPrefix("ref: refs/heads/"), head.count > 16 {
            current = .named(String(head.dropFirst(16)))
        } else if [40, 64].contains(head.count), head.allSatisfy(\.isHexDigit) {
            current = .detached
        } else {
            return nil
        }
        let common = commonDirectory(of: location.gitDirectory)
        var truncated = false

        // Names, with the file time of a loose ref.
        var found: [String: Date?] = [:]
        var visited = 0
        walk(common.appendingPathComponent("refs/heads", isDirectory: true), prefix: "", depth: 0,
             visited: &visited, found: &found, truncated: &truncated)
        for name in packedBranchNames(common.appendingPathComponent("packed-refs"), truncated: &truncated)
        where found[name] == nil {
            found[name] = .some(nil)
        }
        if case .named(let name) = current, found[name] == nil { found[name] = .some(nil) }

        let others = otherWorktrees(common: common, own: location.gitDirectory, truncated: &truncated)
        var branches = found.map { name, updated in
            ProjectBranch(name: name, isCurrent: current == .named(name), updated: updated, worktree: others[name])
        }
        branches.sort(by: order)
        if branches.count > maxBranches {
            branches = Array(branches.prefix(maxBranches))
            truncated = true
        }
        return ProjectBranches(current: current, branches: branches, truncated: truncated)
    }

    private static func order(_ a: ProjectBranch, _ b: ProjectBranch) -> Bool {
        if a.isCurrent != b.isCurrent { return a.isCurrent }
        switch (a.updated, b.updated) {
        case let (x?, y?) where x != y: return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: Locating

    private struct Location {
        let root: URL
        let gitDirectory: URL
    }

    /// The folder's own `.git` or the nearest parent's. A `.git` file points at the real directory (a worktree).
    private static func locate(directory: String) -> Location? {
        var root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        while true {
            let metadata = root.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: metadata.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return Location(root: root, gitDirectory: metadata) }
                guard let pointer = smallText(metadata)?.trimmed, pointer.hasPrefix("gitdir: ") else { return nil }
                let path = String(pointer.dropFirst(8)).trimmed
                guard !path.isEmpty else { return nil }
                let target = path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true)
                    : root.appendingPathComponent(path, isDirectory: true).standardizedFileURL
                return Location(root: root, gitDirectory: target)
            }
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { return nil }
            root = parent
        }
    }

    /// A linked worktree keeps its branches in the main repository: its `commondir` file names that directory.
    private static func commonDirectory(of gitDirectory: URL) -> URL {
        guard let pointer = smallText(gitDirectory.appendingPathComponent("commondir"))?.trimmed, !pointer.isEmpty else {
            return gitDirectory
        }
        return (pointer.hasPrefix("/") ? URL(fileURLWithPath: pointer, isDirectory: true)
            : gitDirectory.appendingPathComponent(pointer, isDirectory: true)).standardizedFileURL
    }

    // MARK: Loose and packed refs

    private static func walk(_ directory: URL, prefix: String, depth: Int, visited: inout Int,
                             found: inout [String: Date?], truncated: inout Bool) {
        guard depth <= maxDepth,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            visited += 1
            guard visited <= maxEntries, found.count < maxBranches else {
                truncated = true
                return
            }
            let name = prefix + entry.lastPathComponent
            guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey])
            else { continue }
            if values.isDirectory == true {
                walk(entry, prefix: name + "/", depth: depth + 1, visited: &visited, found: &found, truncated: &truncated)
            } else if values.isRegularFile == true, !name.hasSuffix(".lock") {
                found[name] = .some(values.contentModificationDate)
            }
        }
    }

    private static func packedBranchNames(_ file: URL, truncated: inout Bool) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxPackedBytes + 1) else { return [] }
        var bytes = data
        if bytes.count > maxPackedBytes {
            // Cut at the cap: the last line is whole only when a line end follows it; a partial one could read
            // as a shorter branch that does not exist, so it is dropped.
            let endsOnLine = data[data.startIndex + maxPackedBytes] == UInt8(ascii: "\n")
            bytes = bytes.prefix(maxPackedBytes)
            if !endsOnLine {
                bytes = bytes.lastIndex(of: UInt8(ascii: "\n")).map { bytes.prefix(through: $0) } ?? Data()
            }
            truncated = true
        }
        var names: [String] = []
        for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
            // "<sha> refs/heads/<name>"; comments start with "#", peeled tags with "^".
            guard let space = line.firstIndex(of: " "), line.first != "#", line.first != "^" else { continue }
            let ref = line[line.index(after: space)...]
            guard ref.hasPrefix("refs/heads/") else { continue }
            let name = String(ref.dropFirst(11))
            if !name.isEmpty { names.append(name) }
            if names.count >= maxBranches {
                truncated = true
                break
            }
        }
        return names
    }

    // MARK: Worktrees

    /// Branch name to the folder of another worktree that has it checked out: the main checkout and the
    /// linked ones under `worktrees/`, except the project's own.
    private static func otherWorktrees(common: URL, own: URL, truncated: inout Bool) -> [String: String] {
        var result: [String: String] = [:]
        func note(head: URL, folder: String?) {
            guard let folder, let text = smallText(head)?.trimmed, text.hasPrefix("ref: refs/heads/") else { return }
            result[String(text.dropFirst(16))] = folder
        }
        if common.lastPathComponent == ".git", common.standardizedFileURL.path != own.standardizedFileURL.path {
            note(head: common.appendingPathComponent("HEAD"), folder: common.deletingLastPathComponent().path)
        }
        let linked = common.appendingPathComponent("worktrees", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: linked.path) else { return result }
        for (index, name) in names.sorted().enumerated() {
            if index >= maxWorktrees {
                truncated = true
                break
            }
            let directory = linked.appendingPathComponent(name, isDirectory: true)
            if directory.standardizedFileURL.path == own.standardizedFileURL.path { continue }
            guard let pointer = smallText(directory.appendingPathComponent("gitdir"))?.trimmed, pointer.hasPrefix("/") else { continue }
            note(head: directory.appendingPathComponent("HEAD"),
                 folder: URL(fileURLWithPath: pointer).deletingLastPathComponent().path)
        }
        return result
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
