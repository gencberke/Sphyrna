import Foundation
import Synchronization
@testable import LoomCore

/// One run-host bundle for the whole test process, as the app has one: assembled and signed on first use, launched for
/// every scope a test opens (`open -n` starts a new instance, in a fresh coalition, each time), and unregistered and removed
/// when the process exits.
///
/// A freshly assembled bundle is a new ad-hoc signed app to macOS: its first launch took about 4 s to connect, a launch of
/// the same bundle about 2 s (`launchtime.py`, 30 Oct; five launches each, under a parallel build). A bundle per test paid
/// that first launch in every scoped test. Tests that need a host of their own (a missing executable, another owner, a host
/// that never connects) still assemble one with `RunScopeLauncher.assembleOwnedBundle`.
public enum SharedRunHost {
    private static let bundles = Mutex<[String: URL]>([:])

    /// The process's bundle around `executable` (the built `loom-run-host`), assembled on first use.
    public static func bundle(for executable: URL) throws -> URL {
        try bundles.withLock { bundles in
            if let bundle = bundles[executable.path] { return bundle }
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("loom-shared-host-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let bundle = try RunScopeLauncher.assembleOwnedBundle(executable: executable, in: root)
            if bundles.isEmpty { atexit { SharedRunHost.removeAll() } }
            bundles[executable.path] = bundle
            return bundle
        }
    }

    private static func removeAll() {
        for bundle in bundles.withLock({ $0.values }) {
            RunScopeLauncher.removeOwnedBundle(in: bundle.deletingLastPathComponent())
        }
    }
}
