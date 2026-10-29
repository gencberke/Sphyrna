import Foundation
import Testing
@testable import LoomCore

@Suite struct CodexTranscriptConfigTests {
    actor Count {
        private(set) var value = 0
        func add() { value += 1 }
    }

    @Test func cachedHomeGetterDoesNotResolveOrGuessAProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codex-config-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("isolated-codex", isDirectory: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let supervisor = try await ProcessSupervisor.restoring(ledger: OwnershipLedger(), catalog: catalog)
        let count = Count()
        let runtime = SessionRuntime(supervisor: supervisor, catalog: catalog, configuration: SessionRuntimeConfiguration(
            toolchains: { provider in
                await count.add()
                return ProviderToolchain(provider: provider, executable: "/fixture/not-executed", capabilities:
                    ProviderCapabilities(version: "0.0.0", help: ""), environment: [:], profileDirectory: home)
            }, hookHelperPath: "/fixture/not-executed", socketDirectory: root, homeDirectory: root.path,
            claudeTemporaryRoot: nil, claudeEnvironment: [:], catalogBackupDelay: nil))
        #expect(await runtime.cachedCodexTranscriptHome() == nil)
        #expect(await count.value == 0)
        _ = try await runtime.toolchain(for: .codex)
        #expect(await runtime.cachedCodexTranscriptHome() == home)
        #expect(await count.value == 1, "the getter does not resolve again or spawn anything")
    }
}
