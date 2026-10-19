import Foundation
import Synchronization
import Testing
@testable import LoomCore

/// CP4-G: worktree protection on real temp git repositories, and the coordinator that feeds the
/// planner and runs only confirmed manual deletions. Temp trees only; the deletion itself is a
/// recording fake here (CP4-C covers the real deletion).
@Suite(.serialized, .timeLimit(.minutes(3)))
struct CleanupCoordinatorTests {
    // MARK: Fixture

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-cp4g-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Loom Test", "-c", "user.email=loom@example.invalid",
                             "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main",
                             "-C", directory.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestFailure("git \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ text: String) { description = text }
    }

    /// A pushed repository (`main` checkout) and a linked worktree on its own branch, both clean.
    private struct Repository {
        let root: URL
        let main: URL
        let worktree: URL
    }

    private func makeRepository(in root: URL) throws -> Repository {
        let remote = root.appendingPathComponent("remote.git")
        let main = root.appendingPathComponent("main")
        let worktree = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try git(["init", "--bare"], in: remote)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try git(["init"], in: main)
        try Data("one\n".utf8).write(to: main.appendingPathComponent("file.txt"))
        try git(["add", "."], in: main)
        try git(["commit", "-m", "first"], in: main)
        try git(["remote", "add", "origin", remote.path], in: main)
        try git(["push", "origin", "main"], in: main)
        try git(["worktree", "add", "-b", "feature", worktree.path], in: main)
        try git(["push", "origin", "feature"], in: main)
        return Repository(root: root, main: main, worktree: worktree)
    }

    private func protection() throws -> CleanupWorktreeProtection {
        .live(supervisor: try ProcessSupervisor(ledger: OwnershipLedger()))
    }

    private func isProtected(_ verdict: CleanupWorktreeVerdict) -> Bool {
        if case .protected = verdict { return true }
        return false
    }

    // MARK: Worktree protection

    @Test func aCleanPushedLinkedWorktreeIsNotProtected() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try makeRepository(in: root)
        let protection = try protection()
        #expect(CleanupWorktreeProtection.isLinkedWorktree(directory: repository.worktree.path))
        #expect(await protection.verdict(workingDirectory: repository.worktree.path) == .clear)
    }

    @Test func aMainCheckoutAndAFolderOutsideGitAreNotWorktrees() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try makeRepository(in: root)
        // Dirty on purpose: only linked worktrees are protected by this rule.
        try Data("dirty\n".utf8).write(to: repository.main.appendingPathComponent("new.txt"))
        let plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let protection = try protection()
        #expect(await protection.verdict(workingDirectory: repository.main.path) == .clear)
        #expect(await protection.verdict(workingDirectory: plain.path) == .clear)
        #expect(await protection.verdict(workingDirectory: root.appendingPathComponent("gone").path) == .clear)
    }

    @Test func uncommittedChangesProtectAWorktree() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try makeRepository(in: root)
        let protection = try protection()
        try Data("untracked\n".utf8).write(to: repository.worktree.appendingPathComponent("new.txt"))
        #expect(isProtected(await protection.verdict(workingDirectory: repository.worktree.path)))
        try FileManager.default.removeItem(at: repository.worktree.appendingPathComponent("new.txt"))
        #expect(await protection.verdict(workingDirectory: repository.worktree.path) == .clear)
        try Data("edited\n".utf8).write(to: repository.worktree.appendingPathComponent("file.txt"))
        #expect(isProtected(await protection.verdict(workingDirectory: repository.worktree.path)))
    }

    @Test func anUnpushedCommitProtectsAWorktree() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try makeRepository(in: root)
        try Data("two\n".utf8).write(to: repository.worktree.appendingPathComponent("file.txt"))
        try git(["commit", "-am", "local only"], in: repository.worktree)
        let protection = try protection()
        #expect(isProtected(await protection.verdict(workingDirectory: repository.worktree.path)))
        try git(["push", "origin", "feature"], in: repository.worktree)
        #expect(await protection.verdict(workingDirectory: repository.worktree.path) == .clear)
    }

    @Test func aStashProtectsAWorktree() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try makeRepository(in: root)
        try Data("stashed\n".utf8).write(to: repository.worktree.appendingPathComponent("file.txt"))
        try git(["stash", "push"], in: repository.worktree)
        let protection = try protection()
        #expect(isProtected(await protection.verdict(workingDirectory: repository.worktree.path)))
    }

    @Test func aGitErrorOrTimeoutProtectsTheWorktree() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A `.git` file that points nowhere: git itself fails.
        let broken = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("gitdir: /nonexistent/loom-cp4g\n".utf8).write(to: broken.appendingPathComponent(".git"))
        let protection = try protection()
        #expect(isProtected(await protection.verdict(workingDirectory: broken.path)))

        // A capture that fails (a timeout reaches the verdict as a throw) protects too.
        let repository = try makeRepository(in: root)
        let failing = CleanupWorktreeProtection { _ in throw TestFailure("timed out") }
        #expect(isProtected(await failing.verdict(workingDirectory: repository.worktree.path)))
        // Unparsable output is not "zero unpushed commits".
        let garbled = CleanupWorktreeProtection { arguments in arguments.contains("rev-list") ? "many" : "" }
        #expect(isProtected(await garbled.verdict(workingDirectory: repository.worktree.path)))
    }

    @Test func protectionReadsGitOnlyReadOnlyWithoutOptionalLocks() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try makeRepository(in: root)
        let seen = Mutex<[[String]]>([])
        let recording = CleanupWorktreeProtection { arguments in
            seen.withLock { $0.append(arguments) }
            return arguments.contains("rev-list") ? "0\n" : ""
        }
        #expect(await recording.verdict(workingDirectory: repository.worktree.path) == .clear)
        let commands = seen.withLock { $0 }
        #expect(commands.count == 3)
        #expect(commands.allSatisfy { $0.first == "--no-optional-locks" })
        #expect(commands.map { $0[3] } == ["status", "rev-list", "stash"])
    }

    // MARK: Coordinator

    private let now = Date(timeIntervalSince1970: 200 * 86_400)
    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var deleted: [UUID] = []
        var failing: Set<UUID> = []
        var beforeDelete: (@Sendable (UUID) async -> Void)?
        var worktreeCalls = 0

        var deletedIDs: [UUID] { lock.withLock { deleted } }
        func record(_ id: UUID) { lock.withLock { deleted.append(id) } }
        func countWorktreeCall() { lock.withLock { worktreeCalls += 1 } }
    }

    private struct Fixture {
        let root: URL
        let catalog: SessionCatalog
        let recorder: Recorder
        let coordinator: CleanupCoordinator
    }

    private func makeFixture(
        policy: CleanupPolicy = CleanupPolicy(),
        worktree: @escaping @Sendable (String) async -> CleanupWorktreeVerdict = { _ in .clear }
    ) throws -> Fixture {
        let root = try temporaryRoot()
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let recorder = Recorder()
        let host = CleanupCoordinator.Host(
            isRunning: { _ in false },
            worktree: { directory in
                recorder.countWorktreeCall()
                return await worktree(directory)
            },
            preview: { id in
                ConversationDeletionPreview(
                    sessionID: id, fileCount: 3, byteCount: 4_096, configDirectory: "/unused",
                    isRunning: false, notRemoved: [], unreachable: [])
            },
            delete: { id in
                await recorder.beforeDelete?(id)
                if recorder.failing.contains(id) { throw SessionRuntimeError.deletionRefused("shared provider data") }
                recorder.record(id)
                return .deleted
            }
        )
        return Fixture(root: root, catalog: catalog, recorder: recorder,
                       coordinator: CleanupCoordinator(catalog: catalog, host: host, policy: policy))
    }

    /// A stale row eligible long ago (stale 45 days, wait 15).
    @discardableResult
    private func insertStale(
        _ catalog: SessionCatalog, title: String, pinned: Bool = false,
        directory: String = "/tmp", staleDaysAgo: Double = 45
    ) async throws -> UUID {
        let session = ManagedSession(provider: .claude, workingDirectory: directory)
        try await catalog.insertSession(
            session, title: title, createdAt: ago(90), lastUsedAt: ago(staleDaysAgo + 15),
            lifecycle: .stale, pinned: pinned, staleSince: ago(staleDaysAgo))
        return session.id
    }

    @Test func pinPersistsAndExcludesFromTheReview() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let kept = try await insertStale(fixture.catalog, title: "kept")
        let other = try await insertStale(fixture.catalog, title: "other")
        try await fixture.catalog.setPinned(true, for: kept)

        let reopened = try SessionCatalog(url: fixture.root.appendingPathComponent("catalog.sqlite3"))
        #expect(try await reopened.session(id: kept)?.pinned == true)

        let review = try await fixture.coordinator.review(now: now)
        #expect(review.eligible.map(\.id) == [other])
        #expect(review.excluded.map(\.id) == [kept])
        #expect(review.excluded.first?.reason == .pinned)

        try await fixture.catalog.setPinned(false, for: kept)
        #expect(Set(try await fixture.coordinator.review(now: now).eligible.map(\.id)) == [kept, other])
    }

    @Test func theReviewListsEligibleRowsWithSizesAndExcludedRowsWithReasons() async throws {
        let fixture = try makeFixture { directory in
            directory == "/work/dirty" ? .protected("The worktree has uncommitted changes.") : .clear
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let eligible = try await insertStale(fixture.catalog, title: "old")
        let waiting = try await insertStale(fixture.catalog, title: "recent", staleDaysAgo: 5)
        let protected = try await insertStale(fixture.catalog, title: "dirty", directory: "/work/dirty")
        // Not stale: never listed.
        try await fixture.catalog.insertSession(
            ManagedSession(provider: .claude, workingDirectory: "/tmp"), title: "idle",
            createdAt: ago(10), lastUsedAt: ago(1), lifecycle: .idle)

        let review = try await fixture.coordinator.review(now: now)
        #expect(review.eligible.map(\.id) == [eligible])
        #expect(review.eligible.first?.byteCount == 4_096)
        #expect(review.eligible.first?.fileCount == 3)
        let reasons = Dictionary(uniqueKeysWithValues: review.excluded.map { ($0.id, $0.reason) })
        #expect(reasons[protected] == .worktree("The worktree has uncommitted changes."))
        if case .waitUntil = reasons[waiting] {} else { Issue.record("A recent stale row was not told to wait") }
        #expect(reasons.count == 2)
    }

    @Test func confirmReplansAndNeverDeletesWhatIsNoLongerEligible() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await insertStale(fixture.catalog, title: "a")
        let second = try await insertStale(fixture.catalog, title: "b")
        let shown = try await fixture.coordinator.review(now: now)
        #expect(Set(shown.eligible.map(\.id)) == [first, second])
        // The user pins one after the list was shown and before confirming.
        try await fixture.catalog.setPinned(true, for: second)

        let confirmation = try await fixture.coordinator.confirm(ids: [first, second], now: now) { _, _ in }
        #expect(fixture.recorder.deletedIDs == [first])
        #expect(confirmation.results[first] == .deleted)
        #expect(confirmation.results[second] == .skipped(.pinned))
    }

    @Test func onlyConfirmedRowsAreDeleted() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ids = [
            try await insertStale(fixture.catalog, title: "a", staleDaysAgo: 60),
            try await insertStale(fixture.catalog, title: "b", staleDaysAgo: 50),
            try await insertStale(fixture.catalog, title: "c", staleDaysAgo: 40),
        ]
        let confirmation = try await fixture.coordinator.confirm(ids: [ids[0], ids[2]], now: now) { _, _ in }
        #expect(fixture.recorder.deletedIDs == [ids[0], ids[2]])
        #expect(confirmation.results[ids[1]] == nil)
        // A confirmed id the catalog never listed is skipped, not deleted.
        let stranger = UUID()
        let again = try await fixture.coordinator.confirm(ids: [stranger], now: now) { _, _ in }
        #expect(again.results[stranger] == .skipped(.notStale))
        #expect(fixture.recorder.deletedIDs == [ids[0], ids[2]])
    }

    @Test func aFailedRowIsReportedAndTheRestStillRun() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await insertStale(fixture.catalog, title: "a", staleDaysAgo: 60)
        let second = try await insertStale(fixture.catalog, title: "b", staleDaysAgo: 50)
        fixture.recorder.failing = [first]
        let progress = Mutex<[UUID]>([])
        let confirmation = try await fixture.coordinator.confirm(ids: [first, second], now: now) { id, _ in
            progress.withLock { $0.append(id) }
        }
        #expect(confirmation.results[first] == .failed(SessionRuntimeError.deletionRefused("shared provider data").description))
        #expect(confirmation.results[second] == .deleted)
        #expect(fixture.recorder.deletedIDs == [second])
        #expect(progress.withLock { $0 } == [first, second])
    }

    @Test func aDueReviewIsRecordedWhenConfirmedOrDismissedAndNotBefore() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = try await insertStale(fixture.catalog, title: "a")
        let shown = try await fixture.coordinator.review(now: now)
        #expect(shown.due == .due)
        // Looking at the review records nothing.
        #expect(try await fixture.catalog.appState(CleanupCoordinator.lastCleanupKey) == nil)

        _ = try await fixture.coordinator.confirm(ids: [id], now: now) { _, _ in }
        #expect(try await fixture.catalog.appState(CleanupCoordinator.lastCleanupKey) == String(now.timeIntervalSince1970))
        let later = try await fixture.coordinator.review(now: now.addingTimeInterval(86_400))
        #expect(later.due == .notDue(until: now.addingTimeInterval(30 * 86_400)))

        // Dismiss: records the run once it is due, and leaves a not-due record alone.
        let dismissed = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dismissed.root) }
        try await dismissed.coordinator.dismiss(now: now)
        #expect(try await dismissed.catalog.appState(CleanupCoordinator.lastCleanupKey) == String(now.timeIntervalSince1970))
        try await dismissed.coordinator.dismiss(now: now.addingTimeInterval(86_400))
        #expect(try await dismissed.catalog.appState(CleanupCoordinator.lastCleanupKey) == String(now.timeIntervalSince1970))
    }

    @Test func launchIsRecordedAndALongAbsenceForcesReview() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.catalog.setAppState(CleanupCoordinator.lastLaunchKey, to: String(ago(60).timeIntervalSince1970))
        await fixture.coordinator.recordLaunch(now: now)
        #expect(try await fixture.catalog.appState(CleanupCoordinator.lastLaunchKey) == String(now.timeIntervalSince1970))
        #expect(try await fixture.coordinator.review(now: now).mode == .reviewRequired(.longAbsence))
    }

    @Test func onlyClaudeConversationsAreOffered() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let claude = try await insertStale(fixture.catalog, title: "claude")
        let codex = ManagedSession(provider: .codex, workingDirectory: "/tmp")
        try await fixture.catalog.insertSession(
            codex, title: "codex", createdAt: ago(90), lastUsedAt: ago(60), lifecycle: .stale, staleSince: ago(45))
        let review = try await fixture.coordinator.review(now: now)
        #expect(review.eligible.map(\.id) == [claude])
        #expect(review.excluded.isEmpty)
    }

    @Test func gitOnlyRunsForRowsNotAlreadyExcluded() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await insertStale(fixture.catalog, title: "pinned", pinned: true)
        try await insertStale(fixture.catalog, title: "open")
        _ = try await fixture.coordinator.review(now: now)
        #expect(fixture.recorder.worktreeCalls == 1)
    }

    // MARK: The user's numbers (D-69)

    @Test func theDefaultsAreThePlansNumbersAndEveryValueStaysInsideItsRange() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(try await fixture.coordinator.settings() == .standard)
        #expect(CleanupSettings.standard == CleanupSettings(reviewIntervalDays: 30, deletionWaitDays: 15))
        #expect(CleanupSettings(policy: CleanupPolicy()) == .standard)
        // Two numbers, stored under these two keys, and no more: the absence and bulk thresholds are not settings.
        #expect(CleanupSettings.Key.all == ["cleanup_review_interval_days", "cleanup_deletion_wait_days"])
        #expect(CleanupSettings.reviewIntervalDaysRange == 7...365)
        #expect(CleanupSettings.deletionWaitDaysRange == 1...180)
        try await fixture.coordinator.setSettings(CleanupSettings(reviewIntervalDays: 0, deletionWaitDays: 9_999))
        let kept = try await fixture.coordinator.settings()
        #expect(kept.reviewIntervalDays == CleanupSettings.reviewIntervalDaysRange.lowerBound)
        #expect(kept.deletionWaitDays == CleanupSettings.deletionWaitDaysRange.upperBound)
        for key in CleanupSettings.Key.all { #expect(try await fixture.catalog.appState(key) != nil) }
        #expect(try await fixture.catalog.appState("cleanup_absence_days") == nil)
        #expect(try await fixture.catalog.appState("cleanup_bulk_limit") == nil)
        // A value written by hand that is not a number, or is out of range, is not trusted.
        try await fixture.catalog.setAppState(CleanupSettings.Key.reviewIntervalDays, to: "often")
        try await fixture.catalog.setAppState(CleanupSettings.Key.deletionWaitDays, to: "100000")
        let read = try await fixture.coordinator.settings()
        #expect(read.reviewIntervalDays == CleanupSettings.standard.reviewIntervalDays)
        #expect(read.deletionWaitDays == CleanupSettings.deletionWaitDaysRange.upperBound)
    }

    @Test func theReviewIntervalComesFromTheUsersNumberAndSurvivesARestart() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = try await insertStale(fixture.catalog, title: "a")
        _ = try await fixture.coordinator.confirm(ids: [id], now: now) { _, _ in }
        let eightDaysOn = now.addingTimeInterval(8 * 86_400)
        // 30 days by default: eight days after a cleanup nothing is due.
        #expect(try await fixture.coordinator.review(now: eightDaysOn).due == .notDue(until: now.addingTimeInterval(30 * 86_400)))
        try await fixture.coordinator.setSettings(CleanupSettings(reviewIntervalDays: 7, deletionWaitDays: 15))
        #expect(try await fixture.coordinator.review(now: eightDaysOn).due == .due)
        // A new coordinator over the reopened catalog reads the same number.
        let reopened = try SessionCatalog(url: fixture.root.appendingPathComponent("catalog.sqlite3"))
        let again = CleanupCoordinator(catalog: reopened, host: CleanupCoordinator.Host(
            isRunning: { _ in false }, worktree: { _ in .clear },
            preview: { id in throw SessionRuntimeError.sessionNotFound(id) },
            delete: { id in throw SessionRuntimeError.sessionNotFound(id) }))
        #expect(try await again.settings().reviewIntervalDays == 7)
        #expect(try await again.review(now: eightDaysOn).due == .due)
        // Back to the defaults.
        #expect(try await fixture.coordinator.resetSettings() == .standard)
        #expect(try await fixture.coordinator.review(now: eightDaysOn).due == .notDue(until: now.addingTimeInterval(30 * 86_400)))
    }

    @Test func theDeletionWaitComesFromTheUsersNumberForEveryStaleSession() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Stale for 20 days and not opened since it went stale: with the default 15-day wait it is eligible.
        let id = try await insertStale(fixture.catalog, title: "a", staleDaysAgo: 20)
        #expect(try await fixture.coordinator.review(now: now).eligible.map(\.id) == [id])
        try await fixture.coordinator.setSettings(CleanupSettings(reviewIntervalDays: 30, deletionWaitDays: 30))
        let waiting = try await fixture.coordinator.review(now: now)
        #expect(waiting.eligible.isEmpty)
        #expect(waiting.excluded.first?.reason == .waitUntil(ago(20).addingTimeInterval(30 * 86_400)))
        // Opened five days ago: the wait counts from then.
        let opened = ManagedSession(provider: .claude, workingDirectory: "/tmp")
        try await fixture.catalog.insertSession(
            opened, title: "opened", createdAt: ago(90), lastUsedAt: ago(5),
            lifecycle: .stale, pinned: false, staleSince: ago(20))
        try await fixture.coordinator.setSettings(CleanupSettings(reviewIntervalDays: 30, deletionWaitDays: 10))
        let review = try await fixture.coordinator.review(now: now)
        #expect(review.eligible.map(\.id) == [id])
        #expect(review.excluded.first { $0.id == opened.id }?.reason == .waitUntil(ago(5).addingTimeInterval(10 * 86_400)))
    }

    @Test func theAbsenceAndBulkThresholdsStayThePolicysWhateverTheUserSets() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for index in 0..<12 { try await insertStale(fixture.catalog, title: "s\(index)") }
        try await fixture.catalog.setAppState(CleanupCoordinator.lastLaunchKey, to: String(ago(60).timeIntervalSince1970))
        await fixture.coordinator.recordLaunch(now: now)
        try await fixture.coordinator.setSettings(CleanupSettings(reviewIntervalDays: 365, deletionWaitDays: 1))
        // 60 days away is past 45, whatever was set.
        #expect(try await fixture.coordinator.review(now: now).mode == .reviewRequired(.longAbsence))
        try await fixture.catalog.setAppState(CleanupCoordinator.lastLaunchKey, to: String(ago(1).timeIntervalSince1970))
        await fixture.coordinator.recordLaunch(now: now)
        #expect(try await fixture.coordinator.review(now: now).mode == .reviewRequired(.bulk))
    }

    @Test func theUsersNumbersNeverSwitchOnAutomaticDeletion() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = try await insertStale(fixture.catalog, title: "a")
        try await fixture.coordinator.setSettings(CleanupSettings(reviewIntervalDays: 7, deletionWaitDays: 1))
        let review = try await fixture.coordinator.review(now: now)
        #expect(review.mode == .reviewRequired(.automaticDisabled))
        #expect(review.eligible.map(\.id) == [id])
        #expect(fixture.recorder.deletedIDs.isEmpty)
    }
}
