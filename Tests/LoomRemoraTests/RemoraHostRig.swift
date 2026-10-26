import Darwin
import Foundation
import Testing
@testable import LoomCore
@testable import LoomRemora

private final class HostFakeAnchor: NSObject {}

final class HostClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

final class HostMaps: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RemoraCatalogMaps
    init(_ maps: RemoraCatalogMaps) { value = maps }
    var maps: RemoraCatalogMaps {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    private var reads = 0
    /// What the host's maps closure reads: the same maps, counted.
    func read() -> RemoraCatalogMaps { lock.withLock { reads += 1; return value } }
    /// How many times a host read the catalog's maps.
    var readCount: Int { lock.withLock { reads } }
}

/// The text a host's `onText` got, in order.
@MainActor
final class HostPieces {
    var items: [String] = []
    var starts = 0
}

/// A host over a temporary data root, the fake provider's Remora mode and a fixed clock and session list. Nothing here starts
/// a real Claude, reads a real profile or touches the user's vault.
@MainActor
final class RemoraHostRig {
    static var fake: String {
        Bundle(for: HostFakeAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("loom-fake-provider").path
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-remora-host-\(UUID().uuidString.prefix(8))")
    let supervisor: ProcessSupervisor
    /// 2027-01-15 11:00 in Istanbul.
    let clock = HostClock(Date(timeIntervalSince1970: 1_800_000_000))
    let zone = TimeZone(identifier: "Europe/Istanbul")!
    let project = UUID()
    let session: UUID
    let maps: HostMaps

    var remora: URL { root.appendingPathComponent("remora") }
    var log: URL { root.appendingPathComponent("fake-log.json") }
    var pids: URL { root.appendingPathComponent("fake-pid") }
    var lastBrief: URL { remora.appendingPathComponent("last-brief.json") }
    var noteFile: URL { remora.appendingPathComponent("Remora.md") }
    var keptBrief: URL { remora.appendingPathComponent(RemoraKeptBriefFile.fileName) }
    /// Where `captureExecutable()` leaves what its child was given.
    var captured: URL { root.appendingPathComponent("captured", isDirectory: true) }

    /// `session`: the id of the rig's one session (a test that deletes it through a real runtime gives that session's id).
    init(session: UUID = UUID()) throws {
        self.session = session
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let moved = Date(timeIntervalSince1970: 1_800_000_000 - 3_600)
        maps = HostMaps(RemoraCatalogMaps(sessionProjects: [session: project], projectNames: [project: "loom"],
                                          recency: [(project, moved)]))
    }

    /// A host over this rig's root. A second one on the same rig is a relaunch: nothing is shared but the folder.
    func makeHost(script: [String: String] = [:], settings: RemoraPreferences = RemoraPreferences(),
                  failToStart: RemoraFailure? = nil, withTranscript: Bool = false, executable: String? = nil) -> RemoraHost {
        let summary = SessionSummary(id: session, harness: .claude, title: "Billing", projectID: project, projectName: "loom",
                                     state: .idle, face: nil, lastActivityAt: clock.now.addingTimeInterval(-3_600))
        var extra = ["LOOM_FAKE_REMORA_LOG": log.path, "LOOM_FAKE_PIDFILE": pids.path]
        extra.merge(script) { _, new in new }
        let supervisor = supervisor
        let work = remora.appendingPathComponent("run")
        let fake = Self.fake
        let maps = maps
        let clock = clock
        let environment = extra
        let projects = withTranscript ? (try? writeTranscript()) : nil
        return RemoraHost(
            dataRoot: root, settings: settings,
            sessions: { _ in [summary] },
            transcript: { summary in
                guard let projects else { return nil }
                return ClaudeTranscriptLocator.locate(sessionID: summary.id.uuidString, projectsDirectory: projects)
            },
            maps: { maps.read() },
            makeCall: { usage in
                if let failToStart { throw failToStart }
                return RemoraCall(
                    supervisor: supervisor, executable: executable ?? fake,
                    environment: RemoraCall.environment(from: ["PATH": "/usr/bin:/bin"], configDirectory: nil),
                    workingDirectory: work, usage: usage, questionDeadline: 20, briefDeadline: 20, terminationGrace: 1,
                    additionalEnvironment: environment)
            },
            timeZone: zone, clock: { clock.now })
    }

    /// A note the rig's project already has. A brief writes a project's note once it read two of its sessions or the note exists
    /// (the gate of 1.7.1); the rig has one session, so a test that expects the note seeds this first.
    func seedNote() throws {
        let folder = remora.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "- 2027-01-14 · Earlier work. (sessions: \(UUID().uuidString))\n"
            .write(to: folder.appendingPathComponent(project.uuidString + ".md"), atomically: true, encoding: .utf8)
    }

    /// A stand-in for `claude` that answers nothing and keeps what it was given: its stdin as `captured/stdin.txt` and the file
    /// `--system-prompt-file` names, which the call removes when it ends, as `captured/system.txt`. Its call ends as a failure;
    /// a test of the pack only reads what was captured.
    func captureExecutable() throws -> String {
        try FileManager.default.createDirectory(at: captured, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("capture-claude.sh")
        let text = """
        #!/bin/sh
        cat > "\(captured.path)/stdin.txt"
        previous=""
        for argument in "$@"; do
          if [ "$previous" = "--system-prompt-file" ]; then cp "$argument" "\(captured.path)/system.txt"; fi
          previous="$argument"
        done
        exit 0
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    func capturedStdin() -> String { (try? String(contentsOf: captured.appendingPathComponent("stdin.txt"), encoding: .utf8)) ?? "" }
    func capturedSystemPrompt() -> String { (try? String(contentsOf: captured.appendingPathComponent("system.txt"), encoding: .utf8)) ?? "" }

    /// A transcript of the rig's session, so a brief reads it (a pack's `readSessionIDs` are the sessions with an excerpt, and
    /// only those make a project's note writable). Returns the `projects` folder it lives in.
    func writeTranscript() throws -> URL {
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let folder = projects.appendingPathComponent("-work-loom", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [RemoraPackWorld.user("Fix the billing importer"), RemoraPackWorld.assistant("The importer now skips empty rows.")]
        try (lines.joined(separator: "\n") + "\n").write(
            to: folder.appendingPathComponent("\(session.uuidString).jsonl"), atomically: true, encoding: .utf8)
        return projects
    }

    /// Whether a fake process ran since `forgetProcesses()` (it writes its pid and its log).
    var ranAProcess: Bool {
        FileManager.default.fileExists(atPath: pids.path) || FileManager.default.fileExists(atPath: log.path)
    }

    func forgetProcesses() {
        try? FileManager.default.removeItem(at: pids)
        try? FileManager.default.removeItem(at: log)
    }

    func pid() async -> Int32? {
        for _ in 0..<500 {
            if let text = try? String(contentsOf: pids, encoding: .utf8), let value = Int32(text) { return value }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func gone(_ pid: Int32, within seconds: TimeInterval = 8) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    func lastBriefRecorded() throws -> Double? {
        guard let data = try? Data(contentsOf: lastBrief) else { return nil }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["lastBrief"] as? Double
    }

    func finish() async {
        _ = await supervisor.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}
