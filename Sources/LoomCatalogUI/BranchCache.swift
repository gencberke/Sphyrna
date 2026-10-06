import Foundation

/// Reads the Git branch of project folders away from the main thread and keeps the
/// last value per folder, so a list reload costs no file reads: the model asks for
/// folders it has not shown yet and refreshes the known ones at turn boundaries
/// and window activation. `GitBranch.read` is a handful of small synchronous
/// file reads that walk up the folder tree; this actor is where they run.
actor BranchCache {
    typealias Reader = @Sendable (String) -> GitBranch

    private let reader: Reader
    private var known: [String: GitBranch] = [:]

    init(reader: @escaping Reader = { GitBranch.read(directory: $0) }) {
        self.reader = reader
    }

    /// The branch of every path; only paths not read before touch the file system.
    func branches(for paths: Set<String>) -> [String: GitBranch] {
        var result: [String: GitBranch] = [:]
        for path in paths {
            if let cached = known[path] {
                result[path] = cached
            } else {
                let branch = reader(path)
                known[path] = branch
                result[path] = branch
            }
        }
        return result
    }

    /// Reads every path again and returns only those whose branch changed.
    func refresh(_ paths: Set<String>) -> [String: GitBranch] {
        var changed: [String: GitBranch] = [:]
        for path in paths {
            let branch = reader(path)
            if known.updateValue(branch, forKey: path) != branch { changed[path] = branch }
        }
        return changed
    }

    /// Forgets folders no card shows any more, so the cache never outgrows the lists.
    func retain(_ paths: Set<String>) {
        known = known.filter { paths.contains($0.key) }
    }
}
