import Darwin
import Foundation
import Synchronization
import Testing
@testable import LoomCore

private final class RegistryCollector: Sendable {
    let values = Mutex<[ClaudeRegistryRead]>([])
    func append(_ value: ClaudeRegistryRead) { values.withLock { $0.append(value) } }
    var count: Int { values.withLock { $0.count } }
    var hasIdle: Bool { values.withLock { $0.contains { if case let .snapshot(s) = $0 { return s.status == "idle" }; return false } } }
}

@Suite(.serialized)
struct ClaudeRegistryTests {
    private func envelope(_ event: String, run: UUID, launch: UUID, at: Date, id: String = "native", fields: [String: Any] = [:]) throws -> ClaudeHookEnvelope {
        var json: [String: Any] = ["session_id": id, "hook_event_name": event]
        json.merge(fields) { _, new in new }
        return ClaudeHookEnvelope(sessionID: launch, managedRunID: run,
            payload: try JSONSerialization.data(withJSONObject: json), sentAt: at)
    }
    private func snapshot(_ status: String, at: Double, id: String = "native", birth: Double = 900_000) -> ClaudeRegistryRead {
        .snapshot(ClaudeRegistrySnapshot(sessionID: id, startedAt: birth, status: status, statusUpdatedAt: at))
    }
    private func tracker() async throws -> (ClaudeHookStateTracker, UUID, UUID, Date) {
        let run = UUID(), launch = UUID(), date = Date(timeIntervalSince1970: 1_000)
        let tracker = ClaudeHookStateTracker(sessionID: launch, managedRunID: run)
        _ = try await tracker.receive(envelope("SessionStart", run: run, launch: launch, at: date))
        _ = try await tracker.receive(envelope("Stop", run: run, launch: launch, at: date,
            fields: ["background_tasks": ["a", "b", "c"], "session_crons": ["a", "b"]]))
        _ = try await tracker.receive(envelope("PermissionRequest", run: run, launch: launch, at: date), receivedAt: date.addingTimeInterval(1))
        return (tracker, run, launch, date)
    }

    @Test func startupMissingMetadataIsNotAFault() async {
        let tracker = ClaudeHookStateTracker(sessionID: UUID(), managedRunID: UUID())
        #expect(await tracker.receiveRegistry(.missing, generation: nil, now: Date()) == nil)
        #expect(await tracker.receiveRegistry(.unavailable, generation: nil, now: Date()) == nil)
        #expect(await tracker.status().activity == .unknown)
    }

    @Test func taskIdleRequiresTheCurrentOwnedSessionDirectoryAndFreshPrompt() async throws {
        let run = UUID(), launch = UUID(), date = Date(timeIntervalSince1970: 1_000)
        let tracker = ClaudeHookStateTracker(sessionID: launch, managedRunID: run)
        _ = try await tracker.receive(envelope("SessionStart", run: run, launch: launch, at: date))
        func sample(_ status: String, _ updated: Double, session: String = "native", cwd: String = "/tmp/owned",
                    waiting: String? = nil) -> ClaudeRegistryRead {
            .snapshot(ClaudeRegistrySnapshot(sessionID: session, startedAt: 1_000_001, status: status,
                statusUpdatedAt: updated, workingDirectory: cwd, waitingFor: waiting))
        }
        _ = await tracker.receiveRegistry(sample("idle", 999_990), generation: nil, now: date.addingTimeInterval(2))
        #expect(await tracker.taskIdleProof(nativeSessionID: "native", workingDirectory: "/tmp/owned") != nil)
        #expect(await tracker.taskIdleProof(nativeSessionID: "other", workingDirectory: "/tmp/owned") == nil)
        #expect(await tracker.taskIdleProof(nativeSessionID: "native", workingDirectory: "/tmp/other") == nil)
        _ = try await tracker.receive(envelope("UserPromptSubmit", run: run, launch: launch,
                                               at: date.addingTimeInterval(0.1), fields: ["prompt_id": "prompt-1"]))
        #expect(await tracker.taskIdleProof(nativeSessionID: "native", workingDirectory: "/tmp/owned") == nil)
        let generation = await tracker.registryGeneration()
        _ = await tracker.receiveRegistry(sample("idle", 1_000_099), generation: generation, now: date.addingTimeInterval(2))
        #expect(await tracker.taskIdleProof(nativeSessionID: "native", workingDirectory: "/tmp/owned") == nil)
        _ = await tracker.receiveRegistry(sample("idle", 1_000_120, waiting: "permission prompt"), generation: generation, now: date.addingTimeInterval(2))
        #expect(await tracker.taskIdleProof(nativeSessionID: "native", workingDirectory: "/tmp/owned") == nil)
        _ = await tracker.receiveRegistry(sample("idle", 1_000_121), generation: generation, now: date.addingTimeInterval(2))
        #expect(await tracker.taskIdleProof(nativeSessionID: "native", workingDirectory: "/tmp/owned")?.promptGeneration != nil)
        _ = await tracker.receiveRegistry(sample("busy", 1_000_122), generation: generation, now: date.addingTimeInterval(2))
        #expect(await tracker.taskIdleProof(nativeSessionID: "native", workingDirectory: "/tmp/owned") == nil)
        _ = await tracker.receiveRegistry(.unavailable, generation: generation, now: date.addingTimeInterval(2))
        #expect(await tracker.taskIdleProof(nativeSessionID: "native", workingDirectory: "/tmp/owned") == nil)
    }

    @Test func malformedNativeWaitingFieldCannotEstablishIdle() throws {
        let identity = ProcessIdentity(pid: 97823, startSeconds: 1_790_762_096, startMicroseconds: 704705)
        let reader = ClaudeRegistryReader(config: URL(fileURLWithPath: "/tmp/owned"), leader: identity, directory: "/tmp/owned")
        for waiting in [NSNull(), NSNumber(value: 1)] as [Any] {
            let data = try JSONSerialization.data(withJSONObject: ["pidDomain": "darwin", "kind": "interactive",
                "cwd": "/tmp/owned", "sessionId": "native", "startedAt": 1_790_762_096_895,
                "procStart": "Wed Sep 30 09:54:56 2026", "status": "idle", "statusUpdatedAt": 1_790_762_099_289,
                "waitingFor": waiting])
            guard case .unavailable = reader.decode(data, now: Date(timeIntervalSince1970: 1_790_762_100)) else {
                Issue.record("Malformed native waiting state must not establish task readiness"); continue
            }
        }
    }

    @Test func delayedPermissionUsesEmissionWatermarkAndNeverInventsCompletion() async throws {
        let (tracker, _, _, date) = try await tracker()
        let generation = await tracker.registryGeneration()
        #expect(await tracker.receiveRegistry(snapshot("busy", at: 1_000_010), generation: generation, now: date.addingTimeInterval(2)) == nil)
        #expect(await tracker.status().activity == .working)
        #expect(await tracker.receiveRegistry(snapshot("idle", at: 1_000_020), generation: generation, now: date.addingTimeInterval(2)) == nil)
        let result = await tracker.status()
        #expect(result.activity == .waitingForInput)
        #expect(result.backgroundTaskCount == 3)
        #expect(result.scheduledTaskCount == 2)
    }

    @Test func oldIdleNewApprovalStaleGenerationAndChangedIdentityAreFenced() async throws {
        let (tracker, run, launch, date) = try await tracker()
        let old = await tracker.registryGeneration()
        #expect(await tracker.receiveRegistry(snapshot("idle", at: 999_990), generation: old, now: date.addingTimeInterval(2)) == nil)
        #expect(await tracker.status().activity == .waitingForApproval)
        _ = try await tracker.receive(envelope("PermissionRequest", run: run, launch: launch, at: date.addingTimeInterval(1)))
        let current = await tracker.registryGeneration()
        _ = await tracker.receiveRegistry(snapshot("idle", at: 1_001_020), generation: old, now: date.addingTimeInterval(2))
        _ = await tracker.receiveRegistry(snapshot("idle", at: 1_001_020, id: "different"), generation: current, now: date.addingTimeInterval(2))
        #expect(await tracker.status().activity == .waitingForApproval)
        _ = await tracker.receiveRegistry(snapshot("waiting", at: 1_001_001), generation: current, now: date.addingTimeInterval(2))
        _ = await tracker.receiveRegistry(snapshot("idle", at: 1_001_020, birth: 900_001), generation: current, now: date.addingTimeInterval(2))
        #expect(await tracker.status().activity == .waitingForApproval)
        _ = try await tracker.receive(envelope("SessionStart", run: run, launch: launch, at: date.addingTimeInterval(2), id: "new", fields: ["source": "clear"]))
        _ = await tracker.receiveRegistry(snapshot("idle", at: 1_001_020), generation: current, now: date.addingTimeInterval(3))
        #expect(await tracker.status().activity == .atPrompt)
        #expect(await tracker.status().providerSessionID == "new")
    }

    @Test func futureClockIsVisibleUnknown() async throws {
        let (tracker, _, _, date) = try await tracker()
        let issue = await tracker.receiveRegistry(snapshot("idle", at: 1_100_000), generation: await tracker.registryGeneration(), now: date.addingTimeInterval(2))
        #expect(issue?.contains("clock is ambiguous") == true)
        #expect(await tracker.status().activity == .unknown)
    }

    @Test func equalMillisecondSampleIsIgnoredNotAProblem() async throws {
        let (tracker, _, _, date) = try await tracker()
        let before = await tracker.status().activity
        let issue = await tracker.receiveRegistry(snapshot("idle", at: 1_000_000), generation: await tracker.registryGeneration(), now: date.addingTimeInterval(2))
        #expect(issue == nil)
        #expect(await tracker.status().activity == before)
    }

    /// REAL-2: concurrent hook helpers delivered a few ms out of emission
    /// order in a real Claude 2.1.287 run, turning a normal flow into
    /// "clock is ambiguous". Small reordering and stale or backwards registry
    /// samples are ignored; a sample newer than every hook still applies.
    @Test func concurrentHookReorderAndStaleSamplesAreNotAProblem() async throws {
        let (tracker, run, launch, date) = try await tracker()
        _ = try await tracker.receive(envelope("Notification", run: run, launch: launch, at: date.addingTimeInterval(0.050),
            fields: ["notification_type": "permission_prompt"]))
        _ = try await tracker.receive(envelope("PermissionRequest", run: run, launch: launch, at: date.addingTimeInterval(0.020)))
        let generation = await tracker.registryGeneration()
        #expect(await tracker.receiveRegistry(snapshot("waiting", at: 1_000_030), generation: generation, now: date.addingTimeInterval(2)) == nil)
        #expect(await tracker.status().activity == .waitingForApproval)
        #expect(await tracker.receiveRegistry(snapshot("idle", at: 1_000_400), generation: generation, now: date.addingTimeInterval(2)) == nil)
        #expect(await tracker.receiveRegistry(snapshot("waiting", at: 1_000_300), generation: generation, now: date.addingTimeInterval(2)) == nil)
        #expect(await tracker.status().activity == .waitingForInput)
    }

    @Test func backwardsSampleIsStaleAndMalformedOrMissingAreUnknownDuringActiveApproval() async throws {
        let (tracker, _, _, date) = try await tracker()
        let generation = await tracker.registryGeneration()
        _ = await tracker.receiveRegistry(snapshot("busy", at: 1_000_100), generation: generation, now: date.addingTimeInterval(2))
        // An older sample after a newer one is a stale read (REAL-2): ignored,
        // and it can never move the state toward idle or completion.
        #expect(await tracker.receiveRegistry(snapshot("idle", at: 1_000_099), generation: generation, now: date.addingTimeInterval(2)) == nil)
        #expect(await tracker.status().activity == .working)
        #expect(await tracker.receiveRegistry(.unavailable, generation: generation, now: date) != nil)
        #expect(await tracker.receiveRegistry(.missing, generation: generation, now: date) != nil)
        _ = await tracker.receiveRegistry(.missing, generation: nil, now: date)
        #expect(await tracker.status().activity == .unknown)
    }

    @Test func interruptedWorkingReturnsToInputWhileRealStopRemainsAuthoritative() async throws {
        let (tracker, run, launch, date) = try await tracker()
        _ = try await tracker.receive(envelope("UserPromptSubmit", run: run, launch: launch, at: date.addingTimeInterval(1)))
        let generation = await tracker.registryGeneration()
        _ = await tracker.receiveRegistry(snapshot("idle", at: 1_000_999), generation: generation, now: date.addingTimeInterval(2))
        #expect(await tracker.status().activity == .working)
        _ = await tracker.receiveRegistry(snapshot("idle", at: 1_001_001), generation: generation, now: date.addingTimeInterval(2))
        #expect(await tracker.status().activity == .waitingForInput)
        _ = try await tracker.receive(envelope("Stop", run: run, launch: launch, at: date.addingTimeInterval(2), fields: ["background_tasks": ["a"], "session_crons": ["b"]]))
        _ = await tracker.receiveRegistry(snapshot("idle", at: 1_002_010), generation: generation, now: date.addingTimeInterval(3))
        #expect(await tracker.status().activity == .turnComplete)
        #expect(await tracker.status().backgroundTaskCount == 1)
        #expect(await tracker.status().scheduledTaskCount == 1)
        _ = try await tracker.receive(envelope("StopFailure", run: run, launch: launch, at: date.addingTimeInterval(3), fields: ["error": "failed"]))
        _ = await tracker.receiveRegistry(snapshot("busy", at: 1_003_010), generation: generation, now: date.addingTimeInterval(4))
        #expect(await tracker.status().activity == .failed("failed"))
    }

    /// REAL-1: the exact sequence recorded from Claude Code 2.1.287. The
    /// registry's initial idle record is stamped about 50 ms BEFORE its own
    /// `startedAt`, and every registry write lands a few ms before the hook
    /// that reports the same change. Those reads are stale (older than the
    /// input watermark), not an inconsistent clock: no issue, no unknown.
    @Test func realClaudePermissionFlowNeverReportsAnAmbiguousClock() async throws {
        let run = UUID(), launch = UUID()
        let started = 1_790_950_107_580.0
        func at(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1_000) }
        func read(_ status: String, _ updated: Double) -> ClaudeRegistryRead {
            .snapshot(ClaudeRegistrySnapshot(sessionID: "native", startedAt: started, status: status, statusUpdatedAt: updated))
        }
        let now = at(1_790_950_200_000)
        let tracker = ClaudeHookStateTracker(sessionID: launch, managedRunID: run)
        _ = try await tracker.receive(envelope("SessionStart", run: run, launch: launch, at: at(1_790_950_107_600)))
        _ = try await tracker.receive(envelope("UserPromptSubmit", run: run, launch: launch, at: at(1_790_950_165_935)))
        let prompt = await tracker.registryGeneration()
        #expect(await tracker.receiveRegistry(read("idle", 1_790_950_107_529), generation: prompt, now: now) == nil)
        #expect(await tracker.status().activity == .working)
        #expect(await tracker.receiveRegistry(read("busy", 1_790_950_165_917), generation: prompt, now: now) == nil)
        #expect(await tracker.status().activity == .working)

        _ = try await tracker.receive(envelope("PermissionRequest", run: run, launch: launch, at: at(1_790_950_168_911)))
        let permission = await tracker.registryGeneration()
        #expect(await tracker.receiveRegistry(read("waiting", 1_790_950_168_892), generation: permission, now: now) == nil)
        #expect(await tracker.status().activity == .waitingForApproval)
        _ = try await tracker.receive(envelope("Notification", run: run, launch: launch, at: at(1_790_950_174_934),
            fields: ["notification_type": "permission_prompt"]))
        #expect(await tracker.status().activity == .waitingForApproval)

        let after = await tracker.registryGeneration()
        #expect(await tracker.receiveRegistry(read("idle", 1_790_950_179_998), generation: after, now: now) == nil)
        #expect(await tracker.status().activity == .waitingForInput)
        // Stale reads never invent completion: Stop is still the only turnComplete.
        #expect(await tracker.status().activity != .turnComplete)
    }

    @Test func rollbackInHookEmissionIsNotResolvedByAnApparentlyNewIdle() async throws {
        let (tracker, run, launch, date) = try await tracker()
        _ = try await tracker.receive(envelope("PermissionRequest", run: run, launch: launch, at: date.addingTimeInterval(-1)))
        let issue = await tracker.receiveRegistry(snapshot("idle", at: 1_000_020), generation: await tracker.registryGeneration(), now: date.addingTimeInterval(2))
        #expect(issue?.contains("clock is ambiguous") == true)
        #expect(await tracker.status().activity == .unknown)
    }

    @Test func realUTCRegistryBirthLiteralIsIndependentOfHostTimezone() throws {
        // Captured from the real CLI on an Istanbul host, not produced by the
        // formatter under test: UTC09:54:56 is local12:54:56 at this epoch.
        let data = Data(#"{"pidDomain":"darwin","kind":"interactive","cwd":"/tmp/own-claude","sessionId":"36abf9da-6b92-4eac-86e4-0b0e2f972606","startedAt":1790762096895,"procStart":"Wed Sep 30 09:54:56 2026","status":"idle","statusUpdatedAt":1790762099289}"#.utf8)
        let identity = ProcessIdentity(pid: 97823, startSeconds: 1790762096, startMicroseconds: 704705)
        let reader = ClaudeRegistryReader(config: URL(fileURLWithPath: "/tmp/own-claude"), leader: identity, directory: "/tmp/own-claude")
        guard case let .snapshot(snapshot) = reader.decode(data, now: Date(timeIntervalSince1970: 1790762100)) else {
            Issue.record("Captured UTC procStart rejected on host timezone \(TimeZone.current.identifier)"); return
        }
        #expect(snapshot.sessionID == "36abf9da-6b92-4eac-86e4-0b0e2f972606")
        let wrong = ClaudeRegistryReader(config: reader.config,
            leader: ProcessIdentity(pid: 97823, startSeconds: 1790762095, startMicroseconds: 704705), directory: reader.directory)
        guard case .unavailable = wrong.decode(data, now: Date(timeIntervalSince1970: 1790762100)) else {
            Issue.record("Captured record accepted with wrong OS birth"); return
        }
    }

    private func reader(_ root: URL) throws -> ClaudeRegistryReader {
        let identity = try #require(try ProcessTable.snapshot().first { $0.identity.pid == getpid() }?.identity)
        return ClaudeRegistryReader(config: root, leader: identity, directory: root.resolvingSymlinksInPath().path)
    }
    private func bytes(_ reader: ClaudeRegistryReader) throws -> Data {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return try JSONSerialization.data(withJSONObject: ["pidDomain": "darwin", "kind": "interactive", "cwd": reader.directory,
            "sessionId": "native", "startedAt": floor(Date().timeIntervalSince1970 * 1_000),
            "procStart": format.string(from: Date(timeIntervalSince1970: Double(reader.leader.startSeconds))),
            "status": "idle", "statusUpdatedAt": floor(Date().timeIntervalSince1970 * 1_000)])
    }
    private func write(_ data: Data, to path: String) {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        defer { if fd >= 0 { close(fd) } }
        data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    @Test func boundedSecureReaderRejectsPartialSymlinkWrongBirthAndWritableFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-registry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let reader = try reader(root), path = sessions.appendingPathComponent("\(getpid()).json").path
        write(try bytes(reader), to: path)
        guard case .snapshot = reader.read() else { Issue.record("Valid own record rejected"); return }
        var mismatched = try #require(try JSONSerialization.jsonObject(with: bytes(reader)) as? [String: Any])
        mismatched["pid"] = getpid() + 1
        write(try JSONSerialization.data(withJSONObject: mismatched), to: path)
        guard case .unavailable = reader.read() else { Issue.record("Wrong declared PID accepted"); return }
        // The working directory is not part of the identity (pid, process birth, start time and
        // session id are): a Claude that changed folders (a worktree) is still this process.
        mismatched["pid"] = getpid(); mismatched["cwd"] = "/different"
        write(try JSONSerialization.data(withJSONObject: mismatched), to: path)
        guard case .snapshot = reader.read() else { Issue.record("A changed working directory made the record unavailable"); return }
        mismatched["cwd"] = "relative/path"
        write(try JSONSerialization.data(withJSONObject: mismatched), to: path)
        guard case .unavailable = reader.read() else { Issue.record("A cwd that is not absolute accepted"); return }
        write(try bytes(reader), to: path)
        let wrong = ClaudeRegistryReader(config: root, leader: ProcessIdentity(pid: getpid(), startSeconds: reader.leader.startSeconds - 1, startMicroseconds: reader.leader.startMicroseconds), directory: reader.directory)
        guard case .unavailable = wrong.read() else { Issue.record("Wrong OS birth accepted"); return }
        write(Data("{".utf8), to: path)
        guard case .unavailable = reader.read() else { Issue.record("Torn JSON accepted"); return }
        write(Data(repeating: 0x20, count: ClaudeRegistryReader.maximumBytes + 1), to: path)
        guard case .unavailable = reader.read() else { Issue.record("Oversize accepted"); return }
        write(try bytes(reader), to: path); chmod(path, 0o666)
        guard case .unavailable = reader.read() else { Issue.record("Writable file accepted"); return }
        unlink(path); symlink("/etc/passwd", path)
        guard case .unavailable = reader.read() else { Issue.record("Symlink accepted"); return }
    }

    @Test func vnodeCreationPartialWriteRetryAndCleanupHaveNoIdlePolling() async throws {
        // The watch includes config's parent. Keep that parent private so other
        // suites creating temporary directories are not registry-change events.
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("loom-watch-\(UUID())")
        let root = container.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: container) }
        let reader = try reader(root), collector = RegistryCollector()
        var watch: ClaudeRegistryWatch? = ClaudeRegistryWatch(reader: reader) { _, _, result, _ in collector.append(result) }
        for _ in 0..<100 where collector.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(collector.count > 0)
        let initial = collector.count
        let unrelatedChurn = Task {
            for _ in 0..<20 {
                let sibling = FileManager.default.temporaryDirectory.appendingPathComponent("loom-watch-unrelated-\(UUID())")
                try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
                try FileManager.default.removeItem(at: sibling)
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        try await unrelatedChurn.value
        #expect(collector.count == initial)
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("\(getpid()).json").path
        write(Data("{".utf8), to: path)
        try await Task.sleep(for: .milliseconds(30))
        write(try bytes(reader), to: path)
        for _ in 0..<100 where !collector.hasIdle { try await Task.sleep(for: .milliseconds(5)) }
        try #require(collector.hasIdle)
        weak var releasedWatch = watch
        watch?.stop(); watch = nil
        try await Task.sleep(for: .milliseconds(50))
        #expect(releasedWatch == nil)
        let ended = collector.count
        write(Data("{".utf8), to: path)
        try await Task.sleep(for: .milliseconds(150))
        #expect(collector.count == ended)
    }

    // MARK: O-2 F3: vnode noise costs nothing

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func singlePIDLookupMatchesTheSnapshotRecord() throws {
        let one = try #require(ProcessTable.record(pid: getpid()))
        let all = try #require(try ProcessTable.snapshot().first { $0.identity.pid == getpid() })
        #expect(one.identity == all.identity)
        #expect(one.userID == getuid() && !one.zombie)
        #expect(ProcessTable.record(pid: Int32.max) == nil)
    }

    @Test func unrelatedFilesInTheWatchedParentCauseNoReadsOrPublishes() async throws {
        // The config directory does not exist yet, so its parent is watched.
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("loom-watch-\(UUID())")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("config")
        let reader = try reader(root), collector = RegistryCollector()
        let watch = ClaudeRegistryWatch(reader: reader) { _, _, result, _ in collector.append(result) }
        defer { watch.stop() }
        try await waitUntil { collector.count > 0 }
        try await Task.sleep(for: .milliseconds(300)) // retries of the initial missing read
        let reads = watch.readCount, delivered = collector.count
        for index in 0..<10 {
            write(Data("x".utf8), to: container.appendingPathComponent("unrelated-\(index)").path)
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(watch.readCount == reads)
        #expect(collector.count == delivered)
        // Once the config directory exists the parent is no longer watched.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try await Task.sleep(for: .milliseconds(150))
        let afterCreate = watch.readCount
        for index in 0..<10 {
            write(Data("x".utf8), to: container.appendingPathComponent("later-\(index)").path)
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(watch.readCount == afterCreate)
    }

    @Test func unchangedRegistryFileIsNotReReadOnVnodeEventsButHookRequestsAlwaysRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-watch-\(UUID())")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try reader(root), collector = RegistryCollector()
        write(try bytes(reader), to: sessions.appendingPathComponent("\(getpid()).json").path)
        let watch = ClaudeRegistryWatch(reader: reader) { _, _, result, _ in collector.append(result) }
        defer { watch.stop() }
        try await waitUntil { collector.hasIdle }
        try #require(collector.hasIdle)
        try await Task.sleep(for: .milliseconds(100))
        let reads = watch.readCount, delivered = collector.count
        // Directory events (a sibling session's file) leave this file unchanged.
        for index in 0..<10 {
            write(Data("{}".utf8), to: sessions.appendingPathComponent("99\(index).json").path)
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(watch.readCount == reads)
        #expect(collector.count == delivered)
        // A hook-driven request reads even though the file is unchanged.
        watch.request(generation: UUID())
        try await waitUntil { watch.readCount > reads }
        #expect(watch.readCount > reads)
        // A real change of our own file is read.
        let before = watch.readCount
        write(try bytes(reader), to: sessions.appendingPathComponent("\(getpid()).json").path)
        try await waitUntil { watch.readCount > before }
        #expect(watch.readCount > before)
    }

    @Test func pendingRegistryReadsFenceAdmissionUntilTheNewestSnapshotIsApplied() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-registry-fence-\(UUID())")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try reader(root), lease = SessionTaskRunLease(), revisions = Mutex<[UInt64]>([])
        write(try bytes(reader), to: sessions.appendingPathComponent("\(getpid()).json").path)
        let watch = ClaudeRegistryWatch(reader: reader, taskPending: { lease.beginHook() }, taskSettled: { lease.finishHook() }) {
            _, _, _, revision in revisions.withLock { $0.append(revision) }
        }
        defer { watch.stop() }
        try await waitUntil { !revisions.withLock { $0.isEmpty } }
        let first = try #require(revisions.withLock { $0.last })
        #expect(lease.admit { $0 } == nil)
        // A sibling vnode change with the same owned-file fingerprint must
        // not release the still-unapplied first snapshot.
        write(Data("{}".utf8), to: sessions.appendingPathComponent("unrelated.json").path)
        try await waitUntil { revisions.withLock { ($0.last ?? first) > first } }
        let afterVnode = try #require(revisions.withLock { $0.last })
        watch.acknowledgeTaskObservation(first)
        #expect(lease.admit { $0 } == nil)
        watch.acknowledgeTaskObservation(afterVnode)
        #expect(lease.admit { $0 } != nil)
        watch.request(generation: nil)
        try await waitUntil { revisions.withLock { ($0.last ?? afterVnode) > afterVnode } }
        let latest = try #require(revisions.withLock { $0.last })
        watch.acknowledgeTaskObservation(afterVnode)
        #expect(lease.admit { $0 } == nil)
        watch.acknowledgeTaskObservation(latest)
        #expect(lease.admit { $0 } != nil)
    }

    // MARK: H1-B: tolerance and clock

    private func decoded(status: String?) throws -> ClaudeRegistryRead {
        let identity = ProcessIdentity(pid: 97823, startSeconds: 1790762096, startMicroseconds: 704705)
        let reader = ClaudeRegistryReader(config: URL(fileURLWithPath: "/tmp/own-claude"), leader: identity, directory: "/tmp/own-claude")
        var object: [String: Any] = ["pidDomain": "darwin", "kind": "interactive", "cwd": "/tmp/own-claude",
            "sessionId": "36abf9da-6b92-4eac-86e4-0b0e2f972606", "startedAt": 1790762096895,
            "procStart": "Wed Sep 30 09:54:56 2026", "statusUpdatedAt": 1790762099289]
        if let status { object["status"] = status }
        return reader.decode(try JSONSerialization.data(withJSONObject: object), now: Date(timeIntervalSince1970: 1790762100))
    }

    @Test func anUnknownStatusIsASnapshotTheTrackerIgnoresNotAnUnavailableRead() async throws {
        ClaudeRegistryDiagnostics.resetForTesting()
        guard case let .snapshot(snapshot) = try decoded(status: "thinking") else {
            Issue.record("A status this build does not know made the read unavailable"); return
        }
        #expect(snapshot.status == "thinking" && snapshot.hasUnknownStatus)
        // Known values are unaffected, and a malformed status is still unavailable.
        guard case let .snapshot(known) = try decoded(status: "busy") else { Issue.record("busy"); return }
        #expect(!known.hasUnknownStatus)
        // `shell` (a background shell is running) is known: it is not reported as drift.
        guard case let .snapshot(shell) = try decoded(status: "shell") else { Issue.record("shell"); return }
        #expect(shell.status == "shell" && !shell.hasUnknownStatus)
        let identity = ProcessIdentity(pid: 97823, startSeconds: 1790762096, startMicroseconds: 704705)
        let reader = ClaudeRegistryReader(config: URL(fileURLWithPath: "/tmp/own-claude"), leader: identity, directory: "/tmp/own-claude")
        let wrongType = try JSONSerialization.data(withJSONObject: ["pidDomain": "darwin", "kind": "interactive", "cwd": "/tmp/own-claude",
            "sessionId": "s", "startedAt": 1790762096895, "procStart": "Wed Sep 30 09:54:56 2026", "status": 7, "statusUpdatedAt": 1790762099289])
        guard case .unavailable = reader.decode(wrongType, now: Date(timeIntervalSince1970: 1790762100)) else {
            Issue.record("A status of the wrong type accepted"); return
        }

        // The tracker keeps the hook state and reports no problem.
        let (tracker, _, _, date) = try await tracker()
        let before = await tracker.status().activity
        let issue = await tracker.receiveRegistry(
            .snapshot(ClaudeRegistrySnapshot(sessionID: "native", startedAt: 900_000, status: "thinking", statusUpdatedAt: 1_000_500)),
            generation: await tracker.registryGeneration(), now: date.addingTimeInterval(2))
        #expect(issue == nil)
        #expect(await tracker.status().activity == before)
    }

    @Test func eachUnknownStatusIsReportedOncePerProcess() {
        ClaudeRegistryDiagnostics.resetForTesting()
        #expect(ClaudeRegistryDiagnostics.noteUnknownStatus("thinking"))
        #expect(!ClaudeRegistryDiagnostics.noteUnknownStatus("thinking"))
        #expect(ClaudeRegistryDiagnostics.noteUnknownStatus("compacting"))
        #expect(ClaudeRegistryDiagnostics.token("a b\nc") == "(not a plain token)")
    }

    @Test func aWallClockThatSteppedBackIsAmbiguousOnceAndTheNextHookOnTheNewClockIsSaneAgain() async throws {
        let (tracker, run, launch, date) = try await tracker()
        // The clock jumps back 100 s between two hooks.
        _ = try await tracker.receive(envelope("UserPromptSubmit", run: run, launch: launch, at: date.addingTimeInterval(-100)))
        let generation = await tracker.registryGeneration()
        let ambiguous = await tracker.receiveRegistry(snapshot("idle", at: 900_500), generation: generation, now: date.addingTimeInterval(2))
        #expect(ambiguous?.contains("clock is ambiguous") == true)
        #expect(await tracker.status().activity == .unknown)

        // The next hook, on the new clock, is in order again: the flag clears and samples apply.
        _ = try await tracker.receive(envelope("UserPromptSubmit", run: run, launch: launch, at: date.addingTimeInterval(-99)))
        let again = await tracker.registryGeneration()
        #expect(await tracker.receiveRegistry(snapshot("idle", at: 901_500), generation: again, now: date.addingTimeInterval(2)) == nil)
        #expect(await tracker.status().activity == .waitingForInput)
    }
}
