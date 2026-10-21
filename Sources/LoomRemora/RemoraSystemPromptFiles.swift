import Foundation

extension RemoraCall {
    /// Removes the `system-*.txt` files in `directory` (`<data root>/remora/`, where `writeSystemPrompt` puts them). A call
    /// removes its own file when it ends; one that was cut short (a crash, a kill) leaves it. The app calls this when
    /// Remora starts, before any call. Only regular files with that name pattern go; returns how many.
    @discardableResult
    public static func removeStaleSystemPrompts(in directory: URL) -> Int {
        var removed = 0
        for name in RemoraFiles.names(in: directory) where name.hasPrefix("system-") && name.hasSuffix(".txt") {
            let file = directory.appendingPathComponent(name)
            var info = stat()
            guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, unlink(file.path) == 0 else { continue }
            removed += 1
        }
        return removed
    }
}
