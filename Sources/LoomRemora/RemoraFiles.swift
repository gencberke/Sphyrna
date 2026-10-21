import Darwin
import Foundation

/// How Remora's stores touch the disk: directories 0700, files 0600, every write a temporary file and a rename. Nothing
/// here logs; a failure is a thrown error that names an operation, never a path's content.
enum RemoraFiles {
    struct Failure: Error, Equatable, CustomStringConvertible {
        var operation: String
        var code: Int32
        var description: String { "\(operation) failed (errno \(code))" }
    }

    /// The folder exists and is 0700 (made when missing; one level, the parent must exist or is made the same way).
    static func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            do {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw Failure(operation: "create folder", code: EIO)
            }
        }
        guard chmod(url.path, 0o700) == 0 else { throw Failure(operation: "protect folder", code: errno) }
    }

    /// Writes `data` to `url` through a temporary file in the same folder, then renames it over the target. The file
    /// ends up with `mode`. Writes through a symbolic link keep the link (the target is replaced).
    static func writeAtomically(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let target = url.resolvingSymlinksInPath()
        let folder = target.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard descriptor >= 0 else { throw Failure(operation: "create file", code: errno) }
        var failure: Failure?
        let written: Bool = data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    failure = Failure(operation: "write file", code: errno)
                    return false
                }
                offset += count
            }
            return true
        }
        if written, fchmod(descriptor, mode) != 0 { failure = Failure(operation: "protect file", code: errno) }
        if failure == nil, fsync(descriptor) != 0 { failure = Failure(operation: "flush file", code: errno) }
        close(descriptor)
        if failure == nil, rename(temporary.path, target.path) != 0 { failure = Failure(operation: "replace file", code: errno) }
        if let failure {
            unlink(temporary.path)
            throw failure
        }
    }

    /// The folder a file is in exists (made 0700 when missing).
    static func ensureParent(of url: URL) throws {
        let parent = url.resolvingSymlinksInPath().deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) { try ensureDirectory(parent) }
    }

    static func read(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    static func readText(_ url: URL) -> String? { read(url).flatMap { String(data: $0, encoding: .utf8) } }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    static func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// The text of a line-based file as its lines, without empty ones.
    static func lines(of text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
