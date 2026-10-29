import Foundation
import Testing
@testable import LoomLaunchOptions

private let defaultRoot = URL(fileURLWithPath: "/default/Loom-Dev", isDirectory: true)

@Suite struct LaunchOptionsTests {
    @Test func normalLaunchUsesDefaultRoot() {
        #expect(LaunchOptions(arguments: []).resolveDataRoot(defaultRoot: defaultRoot) == .root(defaultRoot))
    }

    @Test func evidenceWithoutDataRootIsIsolated() {
        let options = LaunchOptions(arguments: ["--evidence", "/tmp/run", "--fixture", "interactive"])
        #expect(options.resolveDataRoot(defaultRoot: defaultRoot)
            == .root(URL(fileURLWithPath: "/tmp/run/data", isDirectory: true)))
    }

    @Test func evidenceWithDataRootUsesIt() {
        let options = LaunchOptions(arguments: ["--evidence", "/tmp/run", "--data-root", "/tmp/elsewhere"])
        #expect(options.resolveDataRoot(defaultRoot: defaultRoot)
            == .root(URL(fileURLWithPath: "/tmp/elsewhere", isDirectory: true)))
    }

    @Test func dataRootWithoutEvidenceIsRefused() {
        for arguments in [["--data-root", "/tmp/x"], ["--data-root"], ["--evidence"], ["--evidence", "/tmp/r", "--data-root"]] {
            guard case .refused = LaunchOptions(arguments: arguments).resolveDataRoot(defaultRoot: defaultRoot) else {
                Issue.record("expected refusal for \(arguments)")
                continue
            }
        }
    }

    @Test func commandChannelIsPerEvidenceDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("loom-lo-\(UUID().uuidString)")
        let identity = BuildIdentity(bundleIdentifier: "local.loom.desktop.dev")
        let a = base.appendingPathComponent("a"), b = base.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let nameA = LaunchOptions.commandChannel(evidenceDirectory: a.path, identity: identity)
        #expect(nameA != LaunchOptions.commandChannel(evidenceDirectory: b.path, identity: identity))
        #expect(nameA == LaunchOptions.commandChannel(evidenceDirectory: a.path + "/", identity: identity))
        #expect(nameA != "local.loom.desktop.dev.command")
        #expect(nameA.hasPrefix(BuildIdentity(bundleIdentifier: nil).commandChannelPrefix))
    }

    @Test func productionIdentityStartsCodexAndPinsEveryName() {
        let production = BuildIdentity(bundleIdentifier: "local.loom.desktop")
        #expect(production.isProduction)
        #expect(production.dataDirectoryName == "Loom")
        #expect(production.socketDirectoryName == ".loom")
        #expect(production.startableProviders == ["claude", "codex", "agy"])
    }

    @Test func developmentIdentityKeepsEveryNameAndBothProviders() {
        for bundle in ["local.loom.desktop.dev", nil, "", "com.example.other"] {
            let development = BuildIdentity(bundleIdentifier: bundle)
            #expect(!development.isProduction)
            #expect(development.dataDirectoryName == "Loom-Dev")
            #expect(development.socketDirectoryName == ".loom-dev")
            #expect(development.startableProviders == ["claude", "codex", "agy"])
        }
    }

    @Test func commandChannelNameIsPinnedForBothIdentities() {
        // Scripts (`loom_command_channel`) compute this exact name; it must not move.
        let path = "/nonexistent-loom-pin/run"
        let expected = "local.loom.desktop.dev.command.0ae57374db467e4c"
        for bundle in ["local.loom.desktop", "local.loom.desktop.dev"] {
            let name = LaunchOptions.commandChannel(evidenceDirectory: path, identity: BuildIdentity(bundleIdentifier: bundle))
            #expect(name == expected)
        }
    }
}
