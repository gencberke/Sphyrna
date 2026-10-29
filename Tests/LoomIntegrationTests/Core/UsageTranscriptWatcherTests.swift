import Darwin
import Foundation
import Synchronization
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

/// A real FSEvents stream over a temp folder; writes come from another process.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct UsageTranscriptWatcherTests {
    private final class Changes: Sendable {
        private let batches = Mutex<[UsageTranscriptChange]>([])
        func add(_ change: UsageTranscriptChange) { batches.withLock { $0.append(change) } }
        var all: [UsageTranscriptChange] { batches.withLock { $0 } }
        var paths: Set<String> { Set(all.flatMap(\.paths).map(\.path)) }
    }

    private func temporaryProjects() throws -> (root: URL, projects: URL) {
        let root = try makeRoot()
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        return (root, projects)
    }

    /// The real path: the stream reports `/private/var/...`, not `/var/...`.
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("loom-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return URL(fileURLWithPath: realPath(root), isDirectory: true)
    }

    /// `printf` from a separate process, like a Claude session writing its transcript.
    private func append(_ text: String, to file: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "mkdir -p \"$(dirname \"$2\")\" && printf '%s\\n' \"$1\" >> \"$2\"", "sh", text, file.path]
        try process.run()
        _ = await exitStatus(of: process)
    }

    private func wait(seconds: Double = 8, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }

    @Test func anAppendFromAnotherProcessIsReportedAndSilenceReportsNothing() async throws {
        let (root, projects) = try temporaryProjects()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = projects.appendingPathComponent("-tmp-proj/sess-1.jsonl")
        try await append("{}", to: file) // before the stream exists: history is not reported
        try await Task.sleep(for: .milliseconds(500))
        let changes = Changes()
        let watcher = UsageTranscriptWatcher(directory: projects, latency: 0.1) { changes.add($0) }
        #expect(watcher.start())
        defer { watcher.stop() }

        try await Task.sleep(for: .seconds(2)) // silence
        #expect(changes.all.isEmpty)

        try await append("{\"a\":1}", to: file)
        #expect(await wait { changes.paths.contains(file.path) })
        #expect(changes.all.allSatisfy { !$0.needsFullScan })

        try await Task.sleep(for: .seconds(1))
        let seen = changes.all.count
        try await Task.sleep(for: .seconds(2)) // silence again
        #expect(changes.all.count == seen)
    }

    @Test func newSubagentFilesAreReportedAndOtherFilesAreNot() async throws {
        let (root, projects) = try temporaryProjects()
        defer { try? FileManager.default.removeItem(at: root) }
        let changes = Changes()
        let watcher = UsageTranscriptWatcher(directory: projects, latency: 0.1) { changes.add($0) }
        #expect(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(500))

        try await append("x", to: projects.appendingPathComponent("-p/notes.txt"))
        try await append("x", to: projects.appendingPathComponent("-p/memory/note.jsonl"))
        try await append("x", to: projects.appendingPathComponent("-p/s1/tool-results/out.jsonl"))
        try await append("x", to: projects.appendingPathComponent("-p/old.jsonl.orphaned-1"))
        let subagent = projects.appendingPathComponent("-p/s1/subagents/agent-7.jsonl")
        try await append("{}", to: subagent)
        #expect(await wait { changes.paths.contains(subagent.path) })
        try await Task.sleep(for: .seconds(1))
        #expect(changes.paths == [subagent.path])
    }

    @Test func aFolderThatDoesNotExistYetIsSeenWhenItAppears() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let changes = Changes()
        let watcher = UsageTranscriptWatcher(directory: projects, latency: 0.1) { changes.add($0) }
        #expect(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(500))
        let file = projects.appendingPathComponent("-p/s.jsonl")
        try await append("{}", to: file)
        #expect(await wait { !changes.all.isEmpty })
        // Either the file itself or a full-scan request (the folder appeared): both lead to a read.
        #expect(changes.paths.contains(file.path) || changes.all.contains { $0.needsFullScan })
    }

    @Test func nothingIsDeliveredAfterStop() async throws {
        let (root, projects) = try temporaryProjects()
        defer { try? FileManager.default.removeItem(at: root) }
        let changes = Changes()
        let watcher = UsageTranscriptWatcher(directory: projects, latency: 0.1) { changes.add($0) }
        #expect(watcher.start())
        try await Task.sleep(for: .milliseconds(500))
        watcher.stop()
        try await append("{}", to: projects.appendingPathComponent("-p/s.jsonl"))
        try await Task.sleep(for: .seconds(1.5))
        #expect(changes.all.isEmpty)
    }

    @Test func onlyTranscriptsUnderTheWatchedFolderCount() {
        let base = "/p/projects"
        #expect(UsageTranscriptWatcher.isTranscript(base + "/a/s.jsonl", under: base))
        #expect(UsageTranscriptWatcher.isTranscript(base + "/a/s/subagents/x.jsonl", under: base))
        #expect(!UsageTranscriptWatcher.isTranscript(base + "/a/memory/s.jsonl", under: base))
        #expect(!UsageTranscriptWatcher.isTranscript(base + "/a/s.txt", under: base))
        #expect(!UsageTranscriptWatcher.isTranscript("/elsewhere/s.jsonl", under: base))
        #expect(!UsageTranscriptWatcher.isTranscript(base + "x/s.jsonl", under: base))
    }
}
