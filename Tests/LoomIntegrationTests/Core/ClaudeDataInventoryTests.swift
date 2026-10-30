import CryptoKit
import Darwin
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

/// Every tree lives under a temp directory; the real ~/.claude is never read.
@Suite(.serialized)
struct ClaudeDataInventoryTests {
    static let a = "aaaaaaaa-1111-4111-8111-000000000001"
    static let b = "bbbbbbbb-2222-4222-8222-000000000002"

    private final class Fixture {
        let root: URL
        let config: URL
        let outside: URL
        let temporary: URL
        init() throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("loom-cp4a-\(UUID().uuidString)")
            // realpath: /var is a symlink to /private/var on macOS (Foundation keeps /var).
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let resolved = realpath(base.path, nil)!
            root = URL(fileURLWithPath: String(cString: resolved))
            free(resolved)
            config = root.appendingPathComponent("config")
            outside = root.appendingPathComponent("outside")
            temporary = root.appendingPathComponent("tmp/claude-test")
            for url in [config, outside, temporary] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
        }
        deinit {
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                ofItemAtPath: config.appendingPathComponent("projects/ro").path)
            try? FileManager.default.removeItem(at: root)
        }
        func path(_ relative: String) -> URL { config.appendingPathComponent(relative) }
        func write(_ relative: String, _ text: String = "data", under base: URL? = nil) throws {
            let url = (base ?? config).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func link(_ relative: String, to target: URL) throws {
            let url = path(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        }
        func exists(_ relative: String) -> Bool {
            var info = stat()
            return lstat(path(relative).path, &info) == 0
        }

        /// Conversations A and B plus every claimed kind, and everything that must survive.
        func populate() throws {
            let a = ClaudeDataInventoryTests.a, b = ClaudeDataInventoryTests.b
            for id in [a, b] {
                try write("projects/p/\(id).jsonl", "transcript \(id)")
                try write("projects/p/\(id)/subagents/x", "sub \(id)")
                try write("projects/p/\(id)/tool-results/y.txt", "result \(id)")
                try write("session-env/\(id)/env", "env \(id)")
                try write("debug/\(id).txt", "debug \(id)")
                try write("tasks/\(id)/1.json", "task \(id)")
                try write("image-cache/\(id)/1.png", "png \(id)")
                try write("uploads/\(id)/f", "upload \(id)")
                try write("todos/\(id)-agent-\(id).json", "todo \(id)")
            }
            // A only: set-aside variants, a mixed-case name in another project folder.
            try write("projects/p/\(a).orphaned-170.jsonl", "orphan")
            try write("projects/p/\(a).jsonl.superseded-1", "superseded")
            try write("projects/q/\(a.uppercased()).jsonl", "upper")
            // Names that merely contain or extend A's id are not candidates.
            try write("projects/p/backup-\(a).jsonl", "contains")
            try write("projects/p/\(a)x.jsonl", "extends")
            try write("tasks/\(a)-notes/1.json", "tasks only by exact name")
            try write("todos/\(a).json", "not an agent todo")
            // Symlinks: one points out of the config dir, one at B's data, one project folder is a link.
            try write("secret.txt", "outside secret", under: outside)
            try write("dir/kept.txt", "outside dir", under: outside)
            try link("projects/r/\(a).jsonl", to: outside.appendingPathComponent("secret.txt"))
            try link("projects/t/\(a)", to: outside.appendingPathComponent("dir"))
            try link("file-history/\(a)", to: path("file-history/\(b)"))
            try write("file-history/\(b)/v1", "b history")
            try link("projects/s", to: outside.appendingPathComponent("dir"))
            try write("\(a).jsonl", "linked project folder target", under: outside.appendingPathComponent("dir"))
            // Shared files that are never touched.
            try write("history.jsonl", "{\"display\":\"hi\"}")
            try write(".claude.json", "{}")
            try write("paste-cache/p1", "paste")
            try write("plans/x.md", "plan")
            try write("shell-snapshots/s", "snap")
            try write("backups/b", "backup")
            try write("jobs/j", "job")
            try write("daemon/d", "daemon")
            // Stale (its recorded start is not pid 1's): never blocks a deletion.
            try write("sessions/1.json", "{\"pid\":1,\"sessionId\":\"\(b)\",\"procStart\":\"Thu Jan  1 00:00:00 1970\"}")
            try write("projects/p/memory/note.md", "memory")
            // Tier 2 (outside the config dir).
            try write("hash1/\(a)/out.txt", "tmp a", under: temporary)
            try write("hash1/\(b)/out.txt", "tmp b", under: temporary)
        }

        /// Path -> fingerprint of every entry under the config dir; symlinks are not followed.
        func snapshot() throws -> [String: String] {
            var result: [String: String] = [:]
            func walk(_ url: URL, _ relative: String) throws {
                for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                    let child = url.appendingPathComponent(name)
                    let rel = relative.isEmpty ? name : "\(relative)/\(name)"
                    var info = stat()
                    guard lstat(child.path, &info) == 0 else { continue }
                    switch info.st_mode & S_IFMT {
                    case S_IFLNK:
                        result[rel] = "link->" + (try FileManager.default.destinationOfSymbolicLink(atPath: child.path))
                    case S_IFDIR:
                        result[rel] = "dir"
                        try walk(child, rel)
                    default:
                        let digest = SHA256.hash(data: try Data(contentsOf: child))
                        result[rel] = digest.map { String(format: "%02x", $0) }.joined()
                    }
                }
            }
            try walk(config, "")
            return result
        }
    }

    private func plan(_ fixture: Fixture, _ ids: [String] = [a], tmp: Bool = true) throws -> DeletionPlan {
        try ClaudeDataInventory.plan(sessionIDs: ids, configDirectory: fixture.config,
                                     temporaryRoot: tmp ? fixture.temporary : nil)
    }

    private static let claimedForA: Set<String> = [
        "projects/p/\(a).jsonl", "projects/p/\(a)", "projects/p/\(a).orphaned-170.jsonl",
        "projects/p/\(a).jsonl.superseded-1", "projects/q/\(a.uppercased()).jsonl",
        "projects/r/\(a).jsonl", "projects/t/\(a)", "file-history/\(a)", "session-env/\(a)",
        "debug/\(a).txt", "tasks/\(a)", "image-cache/\(a)", "uploads/\(a)", "todos/\(a)-agent-\(a).json",
    ]

    @Test func plansExactlyTheClaimedItemsWithSizesAndResiduals() throws {
        let fixture = try Fixture()
        try fixture.populate()
        let plan = try plan(fixture)
        #expect(Set(plan.items.map(\.relativePath)) == Self.claimedForA)
        #expect(plan.items.count == Self.claimedForA.count)
        let byPath = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.relativePath, $0) })
        #expect(byPath["projects/p/\(Self.a).jsonl"]?.byteSize == Int64("transcript \(Self.a)".utf8.count))
        #expect(byPath["projects/p/\(Self.a).jsonl"]?.kind == .transcript)
        #expect(byPath["projects/p/\(Self.a).orphaned-170.jsonl"]?.kind == .transcriptVariant)
        // A conversation folder is measured by its content (two files), not by its entry.
        #expect(byPath["projects/p/\(Self.a)"]?.byteSize == Int64("sub \(Self.a)".utf8.count + "result \(Self.a)".utf8.count))
        #expect(byPath["projects/p/\(Self.a)"]?.kind == .conversationFolder)
        #expect(byPath["projects/r/\(Self.a).jsonl"]?.isSymbolicLink == true)
        #expect(byPath["file-history/\(Self.a)"]?.isSymbolicLink == true)
        #expect(plan.items.allSatisfy { $0.sessionID == Self.a })
        #expect(plan.totalBytes > 0)
        for kept in ["history.jsonl", ".claude.json", "paste-cache", "plans", "shell-snapshots", "backups",
                     "sessions", "jobs", "daemon", "projects/p/memory"] {
            #expect(plan.residual.contains(kept), "residual lists \(kept)")
        }
        #expect(plan.temporaryItems.map(\.relativePath) == ["hash1/\(Self.a)"])
        #expect(plan.temporaryItems.first?.kind == .temporaryOutput)
        #expect(plan.temporaryItems.first?.byteSize == 5)
        // Planning never touches anything.
        #expect(fixture.exists("projects/p/\(Self.a).jsonl"))
    }

    @Test func deletingOneConversationLeavesEverythingElseByteIdentical() throws {
        let fixture = try Fixture()
        try fixture.populate()
        let before = try fixture.snapshot()
        let secret = try Data(contentsOf: fixture.outside.appendingPathComponent("secret.txt"))
        let result = ClaudeDataDeleter.execute(try plan(fixture))
        #expect(result.isComplete)
        #expect(result.refusal == nil)
        #expect(result.entries.allSatisfy { $0.outcome == .removed })
        let after = try fixture.snapshot()
        func isClaimed(_ path: String) -> Bool {
            Self.claimedForA.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        // Everything except A's items is identical; A's items are gone.
        #expect(after == before.filter { !isClaimed($0.key) })
        for gone in Self.claimedForA { #expect(!fixture.exists(gone), "\(gone) removed") }
        // B and the shared files, named explicitly.
        for kept in ["projects/p/\(Self.b).jsonl", "projects/p/\(Self.b)/subagents/x", "file-history/\(Self.b)/v1",
                     "session-env/\(Self.b)/env", "debug/\(Self.b).txt", "tasks/\(Self.b)/1.json",
                     "image-cache/\(Self.b)/1.png", "uploads/\(Self.b)/f", "todos/\(Self.b)-agent-\(Self.b).json",
                     "history.jsonl", ".claude.json", "projects/p/memory/note.md", "paste-cache/p1", "plans/x.md",
                     "projects/p/backup-\(Self.a).jsonl", "projects/p/\(Self.a)x.jsonl",
                     "tasks/\(Self.a)-notes/1.json", "todos/\(Self.a).json", "projects/s"] {
            #expect(fixture.exists(kept), "\(kept) kept")
        }
        // Symlink targets are intact: links were removed as links, never followed.
        #expect(try Data(contentsOf: fixture.outside.appendingPathComponent("secret.txt")) == secret)
        #expect(FileManager.default.fileExists(atPath: fixture.outside.appendingPathComponent("dir/kept.txt").path))
        #expect(FileManager.default.fileExists(atPath: fixture.outside.appendingPathComponent("dir/\(Self.a).jsonl").path))
        // Tier 2: A's output is gone, B's is not.
        #expect(!FileManager.default.fileExists(atPath: fixture.temporary.appendingPathComponent("hash1/\(Self.a)").path))
        #expect(FileManager.default.fileExists(atPath: fixture.temporary.appendingPathComponent("hash1/\(Self.b)/out.txt").path))
        #expect(try ClaudeDataDeleter.verify(sessionIDs: [Self.a], configDirectory: fixture.config,
                                             temporaryRoot: fixture.temporary).isEmpty)
    }

    @Test func verifyReportsLeftovers() throws {
        let fixture = try Fixture()
        try fixture.populate()
        let leftovers = try ClaudeDataDeleter.verify(sessionIDs: [Self.a], configDirectory: fixture.config,
                                                     temporaryRoot: fixture.temporary)
        #expect(Set(leftovers.map(\.relativePath)) == Self.claimedForA.union(["hash1/\(Self.a)"]))
    }

    @Test func deletingTwoConversationsTakesBoth() throws {
        let fixture = try Fixture()
        try fixture.populate()
        let result = ClaudeDataDeleter.execute(try plan(fixture, [Self.a, Self.b.uppercased()]))
        #expect(result.isComplete)
        #expect(!fixture.exists("projects/p/\(Self.b).jsonl"))
        #expect(!fixture.exists("file-history/\(Self.b)"))
        #expect(fixture.exists("history.jsonl"))
    }

    @Test func nonUUIDIdentifiersAreRefused() throws {
        let fixture = try Fixture()
        try fixture.populate()
        for bad in ["", "*", "..", "../etc", "not-a-uuid", String(repeating: "a", count: 36),
                    "aaaaaaaa1111411181110000000000010001", "gggggggg-1111-4111-8111-000000000001",
                    Self.a + "x", " " + Self.a] {
            #expect(throws: ClaudeDataError.invalidSessionID(bad)) { try plan(fixture, [Self.a, bad]) }
        }
        #expect(throws: ClaudeDataError.self) {
            try ClaudeDataDeleter.verify(sessionIDs: ["x"], configDirectory: fixture.config, temporaryRoot: nil)
        }
        #expect(fixture.exists("projects/p/\(Self.a).jsonl"))
    }

    @Test func unsafeConfigDirectoriesAreRefused() throws {
        let fixture = try Fixture()
        try fixture.populate()
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: fixture.config.path)
        #expect(throws: ClaudeDataError.self) { try plan(fixture) }
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.config.path)
        #expect(throws: ClaudeDataError.self) {
            try ClaudeDataInventory.plan(sessionIDs: [Self.a], configDirectory: fixture.root.appendingPathComponent("missing"),
                                         temporaryRoot: nil)
        }
        // A symlinked config path resolves to the real directory.
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.config)
        let resolved = try ClaudeDataInventory.plan(sessionIDs: [Self.a], configDirectory: alias, temporaryRoot: nil)
        #expect(resolved.configDirectory == fixture.config.path)
    }

    private func sessionFile(_ fixture: Fixture, pid: Int32, id: String, procStart: String? = nil) throws {
        var object: [String: Any] = ["pid": Int(pid), "sessionId": id, "kind": "interactive"]
        if let procStart { object["procStart"] = procStart }
        let data = try JSONSerialization.data(withJSONObject: object)
        try fixture.write("sessions/\(pid).json", String(decoding: data, as: UTF8.self))
    }

    @Test func aLiveSessionRefusesTheWholeDeletion() throws {
        let fixture = try Fixture()
        try fixture.populate()
        let before = try fixture.snapshot()
        let planned = try plan(fixture)
        try sessionFile(fixture, pid: getpid(), id: Self.a.uppercased())
        #expect(throws: ClaudeDataError.liveSession(Self.a)) { try plan(fixture) }
        // A plan made before the session appeared is refused again at execution.
        let result = ClaudeDataDeleter.execute(planned)
        #expect(result.refusal == .liveSession(Self.a))
        #expect(!result.isComplete)
        #expect(result.entries.allSatisfy { $0.outcome != .removed })
        var expected = before
        expected["sessions/\(getpid()).json"] = try fixture.snapshot()["sessions/\(getpid()).json"]
        #expect(try fixture.snapshot() == expected)
        // A live session of another conversation does not block this one.
        try FileManager.default.removeItem(at: fixture.path("sessions/\(getpid()).json"))
        try sessionFile(fixture, pid: getpid(), id: Self.b)
        #expect(ClaudeDataDeleter.execute(try plan(fixture)).isComplete)
    }

    /// `procStart` exactly as Claude writes it (UTC `ps lstart`) for this very process.
    private func ownProcStart() throws -> String {
        let started = try #require(ProcessTable.record(pid: getpid())).identity.startSeconds
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return format.string(from: Date(timeIntervalSince1970: TimeInterval(started)))
    }

    @Test func aSessionFileWhoseProcStartMatchesTheRunningProcessIsLive() throws {
        let fixture = try Fixture()
        try fixture.populate()
        try sessionFile(fixture, pid: getpid(), id: Self.a, procStart: try ownProcStart())
        #expect(throws: ClaudeDataError.liveSession(Self.a)) { try plan(fixture) }
        // The dry run for the confirm dialog may look at a conversation that is still running.
        let preview = try ClaudeDataInventory.plan(sessionIDs: [Self.a], configDirectory: fixture.config,
                                                   temporaryRoot: nil, ignoringLiveSessions: true)
        #expect(!preview.items.isEmpty)
        // Execution still refuses, and nothing is removed.
        let result = ClaudeDataDeleter.execute(preview)
        #expect(result.refusal == .liveSession(Self.a))
        #expect(fixture.exists("projects/p/\(Self.a).jsonl"))
    }

    @Test func aBooleanPidIsNotPidOneAndTheFileNameDecides() async throws {
        let fixture = try Fixture()
        try fixture.populate()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        _ = await exitStatus(of: child)
        // `"pid": true` read as an NSNumber is 1 (launchd, always alive); the name is a dead pid.
        try fixture.write("sessions/\(child.processIdentifier).json",
                          "{\"pid\":true,\"sessionId\":\"\(Self.a)\",\"kind\":\"interactive\"}")
        #expect(try plan(fixture).items.contains { $0.relativePath == "projects/p/\(Self.a).jsonl" })
        // The same boolean in a file named after a live pid still counts as live.
        try fixture.write("sessions/\(getpid()).json",
                          "{\"pid\":true,\"sessionId\":\"\(Self.a)\",\"kind\":\"interactive\"}")
        #expect(throws: ClaudeDataError.liveSession(Self.a)) { try plan(fixture) }
    }

    @Test func foldersTheScanCannotEnterAreListedNotSkipped() throws {
        let fixture = try Fixture()
        try fixture.populate()
        // populate() has `projects/s` as a link to a folder elsewhere.
        #expect(try plan(fixture).unreachable == ["projects/s"])
        // A whole data folder moved elsewhere and linked back, a typical way to save disk space.
        try FileManager.default.removeItem(at: fixture.path("debug"))
        try fixture.write("debug/\(Self.a).txt", "moved debug", under: fixture.outside)
        try FileManager.default.createSymbolicLink(at: fixture.path("debug"),
                                                   withDestinationURL: fixture.outside.appendingPathComponent("debug"))
        let planned = try plan(fixture)
        #expect(planned.unreachable == ["debug", "projects/s"])
        #expect(!planned.items.contains { $0.relativePath.hasPrefix("debug/") })
        // Nothing outside the config directory is touched by deleting what is reachable.
        #expect(ClaudeDataDeleter.execute(planned).isComplete)
        #expect(FileManager.default.fileExists(atPath: fixture.outside.appendingPathComponent("debug/\(Self.a).txt").path))
        // A folder that is simply absent is not reported.
        try FileManager.default.removeItem(at: fixture.path("uploads"))
        #expect(try plan(fixture).unreachable == ["debug", "projects/s"])
    }

    @Test func onlyTheWorkingDirectorysProjectFolderOrADataFolderBlocks() throws {
        let fixture = try Fixture()
        try fixture.populate()
        func planned(_ directory: String?) throws -> DeletionPlan {
            try ClaudeDataInventory.plan(sessionIDs: [Self.a], configDirectory: fixture.config,
                                         temporaryRoot: nil, workingDirectory: directory)
        }
        // Without a working directory every unreachable project folder blocks (the plan for a record that names none).
        #expect(try planned(nil).unreachable == ["projects/s"])
        // Another project's linked folder cannot hold this session's transcript: it is reported, not blocking.
        let other = try planned("/work/app")
        #expect(other.unreachable.isEmpty)
        #expect(other.unrelatedUnreachable == ["projects/s"])
        // The folder Claude names after the working directory does block, however it is spelled.
        try fixture.link("projects/-work-app", to: fixture.outside.appendingPathComponent("dir"))
        let own = try planned("/work/app")
        #expect(own.unreachable == ["projects/-work-app"])
        #expect(own.unrelatedUnreachable == ["projects/s"])
        try FileManager.default.removeItem(at: fixture.path("projects/-work-app"))
        try fixture.link("projects/-Work-App", to: fixture.outside.appendingPathComponent("dir"))
        #expect(try planned("/work/app").unreachable == ["projects/-Work-App"])
        // A top-level data folder moved away blocks whatever the working directory is.
        try FileManager.default.removeItem(at: fixture.path("debug"))
        try fixture.link("debug", to: fixture.outside.appendingPathComponent("dir"))
        #expect(try planned("/work/app").unreachable == ["debug", "projects/-Work-App"])
        // So does the projects folder itself.
        try FileManager.default.removeItem(at: fixture.path("projects"))
        try fixture.link("projects", to: fixture.outside)
        #expect(try planned("/work/app").unreachable == ["debug", "projects"])
    }

    @Test func aLongWorkingDirectorysProjectFolderIsMatchedByItsPrefix() throws {
        let fixture = try Fixture()
        let directory = "/" + String(repeating: "deep/", count: 60) + "app"
        let expected = ClaudeTranscriptLocator.folderName(forWorkingDirectory: directory)
        #expect(expected.count > 200)
        // Claude cuts a long name and appends a hash.
        try fixture.link("projects/\(expected.prefix(200))-1a2b3c", to: fixture.outside)
        try fixture.link("projects/-elsewhere", to: fixture.outside)
        let planned = try ClaudeDataInventory.plan(sessionIDs: [Self.a], configDirectory: fixture.config,
                                                   temporaryRoot: nil, workingDirectory: directory)
        #expect(planned.unreachable == ["projects/\(expected.prefix(200))-1a2b3c"])
        #expect(planned.unrelatedUnreachable == ["projects/-elsewhere"])
    }

    @Test func staleSessionFilesDoNotBlock() async throws {
        let fixture = try Fixture()
        try fixture.populate()
        // A dead process: spawn and reap one.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        _ = await exitStatus(of: child)
        try sessionFile(fixture, pid: child.processIdentifier, id: Self.a)
        // A live pid reused since: the recorded start time is not the process's.
        try sessionFile(fixture, pid: getpid(), id: Self.a, procStart: "Thu Jan  1 00:00:00 1970")
        let planned = try plan(fixture)
        #expect(ClaudeDataDeleter.execute(planned).isComplete)
        #expect(!fixture.exists("projects/p/\(Self.a).jsonl"))
    }

    @Test func rerunningAfterACrashFinishesTheRest() throws {
        let fixture = try Fixture()
        try fixture.populate()
        let planned = try plan(fixture)
        // Simulate a crash half way: some items are already gone.
        try FileManager.default.removeItem(at: fixture.path("projects/p/\(Self.a).jsonl"))
        try FileManager.default.removeItem(at: fixture.path("session-env/\(Self.a)"))
        let first = ClaudeDataDeleter.execute(planned)
        #expect(first.isComplete)
        #expect(first.entries.filter { $0.outcome == .alreadyAbsent }.count == 2)
        let second = ClaudeDataDeleter.execute(planned)
        #expect(second.isComplete)
        #expect(second.entries.allSatisfy { $0.outcome == .alreadyAbsent })
        #expect(try plan(fixture).items.isEmpty)
        #expect(fixture.exists("projects/p/\(Self.b).jsonl"))
    }

    @Test func aPermissionFailureLeavesAPartialResult() throws {
        let fixture = try Fixture()
        try fixture.populate()
        try fixture.write("projects/ro/\(Self.a).jsonl", "locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.path("projects/ro").path)
        let planned = try plan(fixture)
        #expect(planned.items.contains { $0.relativePath == "projects/ro/\(Self.a).jsonl" })
        let result = ClaudeDataDeleter.execute(planned)
        #expect(!result.isComplete)
        let failed = result.entries.filter { if case .failed = $0.outcome { return true }; return false }
        #expect(failed.map(\.item.relativePath) == ["projects/ro/\(Self.a).jsonl"])
        if case let .failed(code, _) = failed.first?.outcome { #expect(code == EACCES) }
        #expect(fixture.exists("projects/ro/\(Self.a).jsonl"))
        #expect(!fixture.exists("projects/p/\(Self.a).jsonl"))
        #expect(!fixture.exists("file-history/\(Self.a)"))
        #expect(fixture.exists("projects/p/\(Self.b).jsonl"))
        // After the permission is fixed a re-run finishes the rest.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path("projects/ro").path)
        #expect(ClaudeDataDeleter.execute(planned).isComplete)
        #expect(!fixture.exists("projects/ro/\(Self.a).jsonl"))
    }

    @Test func aTamperedPlanCannotReachOtherFiles() throws {
        let fixture = try Fixture()
        try fixture.populate()
        let real = try plan(fixture)
        func item(_ path: String, _ kind: DeletionPlan.Kind = .transcript, id: String = Self.a) -> DeletionPlan.Item {
            DeletionPlan.Item(sessionID: id, kind: kind, relativePath: path, byteSize: 0, isSymbolicLink: false)
        }
        let forged = [
            item("history.jsonl"), item("projects/p/\(Self.b).jsonl"), item("../outside/secret.txt"),
            item("projects/p/../../history.jsonl"), item("/etc/hosts"), item("projects/p/memory", .conversationFolder),
            item("projects/s/\(Self.a).jsonl"), item("projects/p/\(Self.b).jsonl", id: Self.b),
            item("projects/p/backup-\(Self.a).jsonl"),
        ]
        let tampered = DeletionPlan(sessionIDs: real.sessionIDs, configDirectory: real.configDirectory,
                                    temporaryRoot: real.temporaryRoot, items: forged, temporaryItems: [], residual: [],
                                    unreachable: [])
        let before = try fixture.snapshot()
        let result = ClaudeDataDeleter.execute(tampered)
        #expect(result.entries.count == forged.count)
        #expect(result.entries.allSatisfy { if case .failed = $0.outcome { return true }; return false })
        #expect(try fixture.snapshot() == before)
        #expect(FileManager.default.fileExists(atPath: fixture.outside.appendingPathComponent("secret.txt").path))
        // A plan whose config directory was swapped for a symlink is refused outright.
        let moved = fixture.root.appendingPathComponent("config-moved")
        try FileManager.default.moveItem(at: fixture.config, to: moved)
        try FileManager.default.createSymbolicLink(at: fixture.config, withDestinationURL: moved)
        let swapped = ClaudeDataDeleter.execute(real)
        #expect(!swapped.isComplete)
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("projects/p/\(Self.a).jsonl").path))
    }

    @Test func deletingAFolderNeverFollowsSymlinksInside() throws {
        let fixture = try Fixture()
        try fixture.populate()
        // Links inside a claimed folder point at B's data and at an outside file.
        try fixture.link("projects/p/\(Self.a)/subagents/to-b", to: fixture.path("projects/p/\(Self.b)"))
        try fixture.link("projects/p/\(Self.a)/subagents/to-secret", to: fixture.outside.appendingPathComponent("secret.txt"))
        #expect(ClaudeDataDeleter.execute(try plan(fixture)).isComplete)
        #expect(!fixture.exists("projects/p/\(Self.a)"))
        #expect(fixture.exists("projects/p/\(Self.b)/subagents/x"))
        #expect(FileManager.default.fileExists(atPath: fixture.outside.appendingPathComponent("secret.txt").path))
    }

    @Test func aMissingTemporaryRootIsNotAnError() throws {
        let fixture = try Fixture()
        try fixture.populate()
        let planned = try ClaudeDataInventory.plan(sessionIDs: [Self.a], configDirectory: fixture.config,
                                                   temporaryRoot: fixture.root.appendingPathComponent("no-such"))
        #expect(planned.temporaryItems.isEmpty)
        #expect(ClaudeDataDeleter.execute(planned).isComplete)
    }
}
