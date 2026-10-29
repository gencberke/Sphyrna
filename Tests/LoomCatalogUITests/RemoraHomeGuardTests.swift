import Foundation
import Testing
@testable import LoomCatalogUI

/// L3b's guard that needs no view: the evidence command may write the fake provider's Remora script only inside the run's own
/// data root and only with fake providers. That Home's Remora code starts nothing by itself is `scripts/check-source-guards.py`
/// (remora-home).
struct RemoraHomeGuardTests {
    // MARK: The script file

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loom-remora-evidence-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // The system's own spelling (Foundation drops "/private" from /private/var; the guard resolves with realpath).
        return URL(fileURLWithPath: String(cString: realpath(url.path, nil)!))
    }

    @Test func theScriptIsWrittenInsideTheDataRootOfAFakeProviderRun() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("claude-config", isDirectory: true)
        let target = try #require(RemoraEvidenceFixture.target(dataRoot: root, claudeConfig: config, usesFakeProviders: true))
        #expect(target == config.appendingPathComponent("remora-fixture.json"))
        #expect(RemoraEvidenceFixture.write(#"{"answer":"Hello","mode":"slow","delayMs":200,"chips":["a"],"drafts":["b"],"facts":[]}"#,
                                            dataRoot: root, claudeConfig: config, usesFakeProviders: true))
        let written = try #require(try? Data(contentsOf: target))
        let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(object["answer"] as? String == "Hello" && object["mode"] as? String == "slow")
    }

    @Test func aRealProviderRunWritesNothing() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("claude-config", isDirectory: true)
        #expect(RemoraEvidenceFixture.target(dataRoot: root, claudeConfig: config, usesFakeProviders: false) == nil)
        #expect(!RemoraEvidenceFixture.write(#"{"answer":"x"}"#, dataRoot: root, claudeConfig: config, usesFakeProviders: false))
        #expect(!FileManager.default.fileExists(atPath: config.path), "not even the folder")
    }

    @Test func aFolderOutsideTheDataRootIsRefused() throws {
        let root = try folder()
        let outside = try folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        #expect(RemoraEvidenceFixture.target(dataRoot: root, claudeConfig: outside, usesFakeProviders: true) == nil, "a sibling")
        #expect(RemoraEvidenceFixture.target(dataRoot: root, claudeConfig: root, usesFakeProviders: true) == nil, "the root itself")
        #expect(RemoraEvidenceFixture.target(dataRoot: root, claudeConfig: root.deletingLastPathComponent(), usesFakeProviders: true) == nil, "its parent")
        let prefix = URL(fileURLWithPath: root.path + "-other/claude-config")
        #expect(RemoraEvidenceFixture.target(dataRoot: root, claudeConfig: prefix, usesFakeProviders: true) == nil, "a name that only starts like the root")
        // The real profile is never inside an evidence root.
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        #expect(RemoraEvidenceFixture.target(dataRoot: root, claudeConfig: real, usesFakeProviders: true) == nil)
        #expect(!RemoraEvidenceFixture.write(#"{"answer":"x"}"#, dataRoot: root, claudeConfig: outside, usesFakeProviders: true))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("remora-fixture.json").path))
    }

    @Test func aDotDotPathThatEscapesTheRootIsRefusedAndOneThatStaysInsideIsNot() throws {
        let root = try folder()
        let outside = try folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let escaping = URL(fileURLWithPath: root.path + "/claude-config/../../" + outside.lastPathComponent)
        #expect(RemoraEvidenceFixture.target(dataRoot: root, claudeConfig: escaping, usesFakeProviders: true) == nil)
        #expect(!RemoraEvidenceFixture.write(#"{"answer":"x"}"#, dataRoot: root, claudeConfig: escaping, usesFakeProviders: true))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        let staying = URL(fileURLWithPath: root.path + "/a/../claude-config")
        #expect(RemoraEvidenceFixture.target(dataRoot: root, claudeConfig: staying, usesFakeProviders: true) != nil)
    }

    @Test func aSymbolicLinkThatLeavesTheRootIsRefused() throws {
        let root = try folder()
        let outside = try folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        // The config folder is a link to a folder outside.
        let link = root.appendingPathComponent("claude-config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(RemoraEvidenceFixture.target(dataRoot: root, claudeConfig: link, usesFakeProviders: true) == nil)
        #expect(!RemoraEvidenceFixture.write(#"{"answer":"x"}"#, dataRoot: root, claudeConfig: link, usesFakeProviders: true))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("remora-fixture.json").path))
        // A link in the middle of the path.
        let through = root.appendingPathComponent("claude-config", isDirectory: true).appendingPathComponent("profile")
        #expect(RemoraEvidenceFixture.target(dataRoot: root, claudeConfig: through, usesFakeProviders: true) == nil)
        // The data root itself behind a link is fine: both sides resolve.
        let alias = outside.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let inside = alias.appendingPathComponent("config", isDirectory: true)
        #expect(RemoraEvidenceFixture.target(dataRoot: root, claudeConfig: inside, usesFakeProviders: true) != nil)
        // The script file itself a link: nothing is written through it.
        try FileManager.default.removeItem(at: link)
        let config = root.appendingPathComponent("claude-config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent("victim.json")
        try FileManager.default.createSymbolicLink(at: config.appendingPathComponent("remora-fixture.json"), withDestinationURL: victim)
        #expect(RemoraEvidenceFixture.target(dataRoot: root, claudeConfig: config, usesFakeProviders: true) == nil)
        #expect(!FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func onlyAScriptTheFixtureReadsIsWritten() {
        #expect(RemoraEvidenceFixture.validated(#"{"answer":"a","chips":["why"],"facts":[]}"#) != nil)
        #expect(RemoraEvidenceFixture.validated("not json") == nil)
        #expect(RemoraEvidenceFixture.validated("[]") == nil)
        #expect(RemoraEvidenceFixture.validated("{}") == nil)
        #expect(RemoraEvidenceFixture.validated(#"{"answer":"a","path":"/etc/passwd"}"#) == nil, "a key the fixture does not read")
    }
}
