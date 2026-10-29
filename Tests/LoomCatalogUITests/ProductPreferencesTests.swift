import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

@MainActor
struct ProductPreferencesTests {
    @Test func fontPersistsClampsAndNotifiesExistingSurfaceOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-font-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences.json")
        let model = CatalogModel(catalog: nil, events: SessionEventHub(), preferences: UIPreferencesStore(url: url))
        var applied: [Double] = []
        model.onTerminalFontSizeChange = { applied.append($0) }
        model.setTerminalFontSize(18)
        #expect(model.terminalFontSize == 18)
        #expect(UIPreferencesStore(url: url).current.terminalFontSize == 18)
        model.setTerminalFontSize(99)
        model.setTerminalFontSize(1)
        model.setTerminalFontSize(.nan)
        #expect(applied == [18, 20, 11, 14])
        let old = try JSONDecoder().decode(UIPreferences.self, from: Data("{}".utf8))
        #expect(old.terminalFontSize == 14)
    }

    @Test func gitMetadataSupportsNormalNestedWorktreeDetachedAndUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-branch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        let git = repo.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("ref: refs/heads/feature/örgü\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        #expect(GitBranch.read(directory: repo.appendingPathComponent("nested/source").path) == .named("feature/örgü"))
        let tree = root.appendingPathComponent("worktree")
        let metadata = git.appendingPathComponent("worktrees/test")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data("gitdir: ../repo/.git/worktrees/test\n".utf8).write(to: tree.appendingPathComponent(".git"))
        try Data("ref: refs/heads/worktree-branch\n".utf8).write(to: metadata.appendingPathComponent("HEAD"))
        #expect(GitBranch.read(directory: tree.path) == .named("worktree-branch"))
        try Data(String(repeating: "a", count: 40).utf8).write(to: metadata.appendingPathComponent("HEAD"))
        #expect(GitBranch.read(directory: tree.path) == .detached)
        try Data("broken".utf8).write(to: metadata.appendingPathComponent("HEAD"))
        #expect(GitBranch.read(directory: tree.path) == .unavailable)
        #expect(GitBranch.read(directory: root.path) == .unavailable)
    }
}
