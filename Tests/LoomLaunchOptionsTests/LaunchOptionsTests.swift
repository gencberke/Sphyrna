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
        let a = base.appendingPathComponent("a"), b = base.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let nameA = LaunchOptions.commandChannel(evidenceDirectory: a.path)
        #expect(nameA != LaunchOptions.commandChannel(evidenceDirectory: b.path))
        #expect(nameA == LaunchOptions.commandChannel(evidenceDirectory: a.path + "/"))
        #expect(nameA != "local.loom.desktop.dev.command")
        #expect(nameA.hasPrefix(LaunchOptions.commandChannelPrefix))
    }
}
