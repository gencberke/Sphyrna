import Darwin
import Foundation

/// What a crashed or force-quit Loom leaves behind outside the catalog and the run directories:
/// hook and control sockets in the socket directory. Run directories are `PreviousRunRecovery`'s,
/// open runs in the catalog are `SessionCatalog.closeAbandonedRuns`'.
enum StaleSocketSweep {
    /// `h-<8 hex>.sock` (hook) and `c-<8 hex>.sock` (control), the names `SessionRuntime.ensureHooks` gives.
    static func isLoomSocketName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == 15, bytes[0] == UInt8(ascii: "h") || bytes[0] == UInt8(ascii: "c"),
              bytes[1] == UInt8(ascii: "-"), name.hasSuffix(".sock") else { return false }
        return bytes[2..<10].allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    struct Result: Equatable {
        var removed = 0
        /// Sockets that answered a connection (another live Loom's) or that could not be judged.
        var kept = 0
    }

    /// Unlinks the sockets in `directory` whose `connect()` is refused: nothing listens there any
    /// more. A socket something still listens on (another Loom instance), one that cannot be judged
    /// (any other error) and this run's own (`ownRunPrefix`) stay.
    static func sweep(directory: URL, ownRunPrefix: String) -> Result {
        var result = Result()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return result }
        let own = ownRunPrefix.lowercased()
        for name in names where isLoomSocketName(name) {
            if name.dropFirst(2).prefix(8).lowercased() == own { continue }
            let path = directory.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
                result.kept += 1
                continue
            }
            do {
                let descriptor = try LocalSocket.connect(path: path, timeout: 0.2)
                Darwin.close(descriptor)
                result.kept += 1
            } catch ClaudeHookTransportError.system(_, let code) where code == ECONNREFUSED {
                if unlink(path) == 0 { result.removed += 1 } else { result.kept += 1 }
            } catch {
                result.kept += 1
            }
        }
        return result
    }
}
