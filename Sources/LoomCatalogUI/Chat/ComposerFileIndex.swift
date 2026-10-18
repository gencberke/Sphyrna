import Foundation

/// A file or folder below the session's folder, for the `@` menu.
struct ComposerFileEntry: Equatable, Sendable {
    /// Relative to the session's folder, `/`-separated.
    let path: String
    let isDirectory: Bool
    /// The path and the last component, folded for matching (done once, when the folder is scanned).
    let foldedPath: String
    let foldedName: String

    init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
        foldedPath = PaletteRanking.fold(path)
        foldedName = PaletteRanking.fold((path as NSString).lastPathComponent)
    }
}

/// The files and folders of a session's folder (CHAT-SPEC → Menus): a breadth-first walk that is capped in entries, depth
/// and time, skips what is never wanted in a mention (hidden items, build output, dependency folders) and stops at once
/// when it is cancelled. Shallow items come first, so a cap keeps the ones a person is likely to mean.
enum ComposerFileIndex {
    static let maximumEntries = 20_000
    static let maximumDepth = 8
    static let timeLimit: TimeInterval = 0.5
    /// At most this many entries of one folder are listed (a folder of thousands of files is not worth a mention).
    static let maximumPerFolder = 2_000
    static let skippedFolders: Set<String> = [
        "node_modules", ".git", ".build", "build", "DerivedData", "dist", "target", "Pods", "venv", ".venv", "__pycache__",
    ]

    /// The folders no scan reads: the home folder and every folder above it (`/Users`), the root and every volume root
    /// (`/Volumes`, `/Volumes/X`). Every folder of the user is under them, and reading the protected ones (Desktop,
    /// Documents, Downloads) would ask for permissions; a session there mentions sessions only.
    static func isTooBroad(_ root: URL, home: String = NSHomeDirectory()) -> Bool {
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        let homePath = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
        if path == "/" || path == homePath || homePath.hasPrefix(path + "/") { return true }
        let parts = path.split(separator: "/")
        return parts.first == "Volumes" && parts.count <= 2
    }

    /// Walks `root`. A folder is read as a stream, never listed whole: at most `maximumPerFolder` of its entries are
    /// taken, and the cancel and the deadline are asked inside that loop, so one huge folder cannot hold the scan. Only the
    /// entries kept are sorted.
    static func scan(root: URL, isCancelled: () -> Bool = { false }, home: String = NSHomeDirectory()) -> [ComposerFileEntry] {
        if isTooBroad(root, home: home) { return [] }
        let deadline = Date().addingTimeInterval(timeLimit)
        let fileManager = FileManager.default
        var result: [ComposerFileEntry] = []
        var queue: [(url: URL, prefix: String, depth: Int)] = [(root, "", 0)]
        var head = 0
        var stopped = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        while head < queue.count, result.count < maximumEntries, !stopped {
            if isCancelled() || Date() >= deadline { break }
            let (folder, prefix, depth) = queue[head]
            head += 1
            guard let stream = fileManager.enumerator(
                at: folder, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]) else { continue }
            var kept: [URL] = []
            var seen = 0
            while let url = stream.nextObject() as? URL {
                seen += 1
                if seen % 32 == 0, isCancelled() || Date() >= deadline {
                    stopped = true
                    break
                }
                kept.append(url)
                if kept.count >= maximumPerFolder { break }
            }
            kept.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for url in kept {
                guard result.count < maximumEntries else { break }
                let values = try? url.resourceValues(forKeys: Set(keys))
                let name = url.lastPathComponent
                let isFolder = values?.isDirectory == true && values?.isSymbolicLink != true && values?.isPackage != true
                let path = prefix + name
                result.append(ComposerFileEntry(path: path, isDirectory: isFolder))
                if isFolder, depth + 1 < maximumDepth, !skippedFolders.contains(name) {
                    queue.append((url, path + "/", depth + 1))
                }
            }
        }
        return result
    }

    /// The menu rows for `query` over `entries`: the best `limit`, files and folders in one list. With no query the
    /// shallowest entries show (the walk's own order).
    static func rank(_ entries: [ComposerFileEntry], query: String, limit: Int = 80,
                     isCancelled: () -> Bool = { false }) -> [ComposerMenuItem] {
        let word = PaletteRanking.fold(query)
        var picked: [(entry: ComposerFileEntry, score: Double, order: Int)] = []
        if word.isEmpty {
            picked = entries.prefix(limit).enumerated().map { ($1, 0, $0) }
        } else {
            for (order, entry) in entries.enumerated() {
                if order % 512 == 0, isCancelled() { return [] }
                let name = PaletteRanking.tier(of: word, in: entry.foldedName, fuzzy: true)
                let path = PaletteRanking.tier(of: word, in: entry.foldedPath, fuzzy: true)
                // A match on the name beats the same match deeper in the path; a short path beats a long one.
                let best = max(name + (name > 0 ? 5 : 0), path)
                guard best > 0 else { continue }
                let depth = Double(entry.path.reduce(0) { $1 == "/" ? $0 + 1 : $0 })
                picked.append((entry, best - min(ComposerRanking.maximumPenalty, depth * 1.5 + Double(entry.path.count) * 0.02), order))
            }
            picked.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            picked = Array(picked.prefix(limit))
        }
        return picked.map { entry, _, _ in
            let display = entry.isDirectory ? entry.path + "/" : entry.path
            return ComposerMenuItem(
                id: "file:" + entry.path, kind: entry.isDirectory ? .folder : .file, title: display,
                detail: nil, trailing: nil, insertion: Self.insertion(for: entry.path, isDirectory: entry.isDirectory))
        }
    }

    /// `@path ` for a file. A folder keeps its trailing slash and no space, so the menu goes on into it; a path with a
    /// space is quoted as `@"path"` and closed.
    static func insertion(for path: String, isDirectory: Bool) -> String {
        let shown = isDirectory ? path + "/" : path
        if shown.contains(where: \.isWhitespace) { return "@\"\(shown)\" " }
        return isDirectory ? "@\(shown)" : "@\(shown) "
    }
}
