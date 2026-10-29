import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

/// agy is coming later in 1.8.0 (D-120): its runtime cannot start a run, so the run-level cases of this suite left with
/// the freeze (they are in 0e4ff16 for the slice that lifts it); the discovery file's own safety stays tested.
@Suite(.timeLimit(.minutes(1)))
struct AgyDiscoverySafetyTests {
    @Test func cleanupPreservesAModifiedDiscoveryFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agy-cleanup-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try AgySessionDiscovery.install(in: root, helper: URL(fileURLWithPath: "/usr/bin/true"))
        let witness = try #require(AgyDiscoveryWitness.capture(root: root))
        let hook = root.appendingPathComponent(".agents/hooks.json")
        let original = try Data(contentsOf: hook)
        let changed = Data("synthetic modification".utf8)
        try changed.write(to: hook)
        #expect(!witness.remove())
        #expect(try Data(contentsOf: hook) == changed)
        try original.write(to: hook)
        #expect(witness.remove())
    }
}
