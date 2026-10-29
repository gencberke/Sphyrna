import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

/// Settings → Sessions → Storage (RESCUE C1): a session's size is what the deletion allowlist would remove, measured without
/// following links; the profile's `projects` folder is measured the same way; Claude's retention is read and written as one
/// key of `settings.json`. Everything runs on a temporary profile, never `~/.claude`.
@Suite(.timeLimit(.minutes(1)))
struct SessionStorageTests {
    private static let id = "aaaaaaaa-1111-4222-8333-444444444444"
    private static let other = "bbbbbbbb-1111-4222-8333-444444444444"

    private struct Profile {
        let root: URL
        var config: URL { root.appendingPathComponent("config", isDirectory: true) }
        var project: URL { config.appendingPathComponent("projects/-tmp-proj", isDirectory: true) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func profile() throws -> Profile {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("loom-storage-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        let profile = Profile(root: root)
        try FileManager.default.createDirectory(at: profile.project, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(profile.config.path, 0o700)
        chmod(profile.config.appendingPathComponent("projects").path, 0o700)
        chmod(profile.project.path, 0o700)
        return profile
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: url)
    }

    @Test func aSessionsSizeIsEverythingItsDeletionRemovesAndALinkIsNotFollowed() throws {
        let profile = try profile()
        defer { profile.cleanup() }
        let folder = profile.project.appendingPathComponent(Self.id, isDirectory: true)
        try write(1_000, to: profile.project.appendingPathComponent("\(Self.id).jsonl"))
        try write(200, to: folder.appendingPathComponent("subagents/agent-a1.jsonl"))
        try write(300, to: folder.appendingPathComponent("tool-results/result-1.txt"))
        try write(40, to: profile.config.appendingPathComponent("file-history/\(Self.id)/snapshot-1"))
        // Another session's files are not this one's.
        try write(5_000, to: profile.project.appendingPathComponent("\(Self.other).jsonl"))
        // A link inside the conversation folder to a large file outside the profile: counted as the link, never its target.
        let outside = profile.root.appendingPathComponent("outside.bin")
        try write(1_000_000, to: outside)
        let link = folder.appendingPathComponent("tool-results/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        var info = stat()
        #expect(lstat(link.path, &info) == 0)
        let linkBytes = Int64(info.st_size)

        let plans = try ClaudeDataInventory.dryRunPlans(
            [ClaudeDataInventory.DryRunRequest(sessionIDs: [Self.id], workingDirectory: "/tmp/proj")],
            configDirectory: profile.config, temporaryRoot: nil)
        let plan = try #require(plans.first)
        #expect(Set(plan.items.map(\.kind)) == [.transcript, .conversationFolder, .fileHistory])
        #expect(plan.totalBytes == 1_000 + 200 + 300 + 40 + linkBytes, "the link counts its own size: \(plan.totalBytes)")

        // The whole projects folder: both sessions, the link by its own size.
        #expect(ClaudeDataInventory.projectsFolderBytes(configDirectory: profile.config) == 1_000 + 200 + 300 + 5_000 + linkBytes)
        // A projects folder that is itself a link is not measured.
        let elsewhere = try self.profile()
        defer { elsewhere.cleanup() }
        try FileManager.default.removeItem(at: elsewhere.config.appendingPathComponent("projects"))
        try FileManager.default.createSymbolicLink(at: elsewhere.config.appendingPathComponent("projects"),
                                                   withDestinationURL: profile.config.appendingPathComponent("projects"))
        #expect(ClaudeDataInventory.projectsFolderBytes(configDirectory: elsewhere.config) == nil)
    }

    @Test func theReportListsTheLargestFirstAndARunningSessionIsNeverDeletedFromIt() async throws {
        let profile = try profile()
        defer { profile.cleanup() }
        let catalog = try SessionCatalog(url: profile.root.appendingPathComponent("catalog.sqlite3"))
        let small = ManagedSession(provider: .claude, workingDirectory: "/tmp")
        let large = ManagedSession(provider: .claude, workingDirectory: "/tmp")
        let running = ManagedSession(provider: .claude, workingDirectory: "/tmp")
        for session in [small, large, running] {
            try await catalog.insertSession(session, title: "S", lifecycle: .active)
        }
        let sizes: [UUID: Int64] = [small.id: 10, large.id: 9_000, running.id: 500]
        let deleted = Locked<[UUID]>([])
        let coordinator = CleanupCoordinator(catalog: catalog, host: CleanupCoordinator.Host(
            isRunning: { $0 == running.id },
            worktree: { _ in .clear },
            previews: { ids in
                Dictionary(uniqueKeysWithValues: ids.map { id in
                    (id, ConversationDeletionPreview(sessionID: id, fileCount: 1, byteCount: sizes[id] ?? 0,
                                                     configDirectory: profile.config.path, isRunning: false, notRemoved: [],
                                                     unreachable: []))
                })
            },
            delete: { id in deleted.mutate { $0.append(id) }; return .deleted },
            configDirectory: { profile.config }))
        let report = try await coordinator.storage(now: Date())
        #expect(report.rows.map(\.id) == [large.id, running.id, small.id])
        #expect(report.totalBytes == 9_510)
        #expect(report.rows.first { $0.id == running.id }?.isRunning == true)

        let results = await coordinator.deleteFromStorage(ids: [running.id, small.id]) { _, _ in }
        #expect(results[running.id] == .skipped(.running), "a running session is refused with its reason")
        #expect(results[small.id] == .deleted)
        #expect(deleted.value == [small.id], "only through the host's verified deletion, and only the one not running")
    }

    // MARK: Claude's retention

    @Test func retentionIsReadAsThirtyWhenAbsentAndWrittenAsOneKeyKeepingTheRest() throws {
        let profile = try profile()
        defer { profile.cleanup() }
        let url = ClaudeRetentionFile.url(configDirectory: profile.config)
        #expect(ClaudeRetentionFile.read(url) == .days(30, stated: false), "no file: Claude's default")

        let original = """
            {
              "model": "opus",
              "permissions": {"allow": ["Bash(git status)"], "cleanupPeriodDays": 2},
              "env": {"NOTE": "a \\"quoted\\" value, with a comma"}
            }

            """
        try Data(original.utf8).write(to: url)
        chmod(url.path, 0o600)
        #expect(ClaudeRetentionFile.read(url) == .days(30, stated: false), "a nested key of the same name is not the setting")

        try ClaudeRetentionFile.write(days: 14, to: url)
        #expect(ClaudeRetentionFile.read(url) == .days(14, stated: true))
        let added = try String(contentsOf: url, encoding: .utf8)
        #expect(added.replacingOccurrences(of: "\n  \"cleanupPeriodDays\": 14,", with: "") == original,
                "only the key was added, every other byte kept:\n\(added)")
        var info = stat()
        #expect(stat(url.path, &info) == 0 && info.st_mode & 0o777 == 0o600, "the file keeps its mode")

        try ClaudeRetentionFile.write(days: 90, to: url)
        let replaced = try String(contentsOf: url, encoding: .utf8)
        #expect(replaced == added.replacingOccurrences(of: "\"cleanupPeriodDays\": 14", with: "\"cleanupPeriodDays\": 90"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(replaced.utf8)) as? [String: Any])
        #expect(object["model"] as? String == "opus" && (object["permissions"] as? [String: Any])?["cleanupPeriodDays"] as? Int == 2)
    }

    @Test func aFileThatIsNotAJSONObjectIsNeverWritten() throws {
        let profile = try profile()
        defer { profile.cleanup() }
        let url = ClaudeRetentionFile.url(configDirectory: profile.config)
        for text in ["[1, 2, 3]", "{\"model\": \"opus\",", "not json"] {
            try Data(text.utf8).write(to: url)
            if case .unreadable = ClaudeRetentionFile.read(url) {} else { Issue.record("\(text) reads as unreadable") }
            #expect(throws: ClaudeRetentionError.self) { try ClaudeRetentionFile.write(days: 7, to: url) }
            #expect(try String(contentsOf: url, encoding: .utf8) == text, "left exactly as it was")
        }
        // A value that is not a whole number is shown as unreadable, not guessed.
        try Data(#"{"cleanupPeriodDays": "soon"}"#.utf8).write(to: url)
        if case .unreadable = ClaudeRetentionFile.read(url) {} else { Issue.record("a string value reads as unreadable") }
        #expect(throws: ClaudeRetentionError.self) { try ClaudeRetentionFile.write(days: 0, to: url) }
    }
}

/// A value shared with `@Sendable` closures in a test.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
