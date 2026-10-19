import AppKit
import Foundation
import LoomCore
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

private final class DeletionBundleAnchor: NSObject {}

/// What the model asked of the runtime, and what the runtime answers.
@MainActor
final class DeletionIntents: ConversationIntents {
    var calls: [String] = []
    var preview = ConversationDeletionPreview(
        sessionID: UUID(), fileCount: 3, byteCount: 2_000_000, configDirectory: "/tmp/claude-config",
        isRunning: false, notRemoved: [], unreachable: []
    )
    var previewError: Error?
    var deleteOutcome: ConversationDeletionOutcome = .deleted
    var retryOutcome: ConversationDeletionOutcome = .deleted
    var pending: [PendingConversationDeletion] = []
    var recoveryFailure: String?
    var removeError: Error?

    func start(provider: ManagedSession.Provider, projectID: UUID?) {}
    func resume(sessionID: UUID) {}
    func stop(sessionID: UUID) {}
    func answer(sessionID: UUID, requestID: String, accept: Bool) {}
    func viewed(sessionID: UUID) {}
    func terminalView(sessionID: UUID) -> NSView? { nil }

    func deletionPreview(sessionID: UUID) async throws -> ConversationDeletionPreview {
        calls.append("preview:\(sessionID)")
        if let previewError { throw previewError }
        return ConversationDeletionPreview(
            sessionID: sessionID, fileCount: preview.fileCount, byteCount: preview.byteCount,
            configDirectory: preview.configDirectory, isRunning: preview.isRunning,
            notRemoved: preview.notRemoved, unreachable: preview.unreachable
        )
    }
    func deleteConversation(sessionID: UUID) async throws -> ConversationDeletionOutcome {
        calls.append("delete:\(sessionID)")
        return deleteOutcome
    }
    func retryDeletion(sessionID: UUID) async throws -> ConversationDeletionOutcome {
        calls.append("retry:\(sessionID)")
        return retryOutcome
    }
    func pendingDeletions() async throws -> [PendingConversationDeletion] { pending }
    func removeFromLoomOnly(sessionID: UUID) async throws {
        calls.append("remove:\(sessionID)")
        if let removeError { throw removeError }
    }
    func deletionRecoveryFailure() async -> String? { recoveryFailure }
}

private func pendingRecord(
    _ id: UUID, state: CatalogDeletionState = .providerData, failure: String? = "partial_failure: a.jsonl",
    running: Bool = false
) -> PendingConversationDeletion {
    PendingConversationDeletion(
        id: id, state: state, attempts: 1, lastFailure: failure,
        requestedAt: Date(), updatedAt: Date(), isRunning: running
    )
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct DeletionModelTests {
    // MARK: Stub-runtime fixture (model logic)

    struct Fixture {
        let root: URL
        let catalog: SessionCatalog
        let hub: SessionEventHub
        let model: CatalogModel
        let intents: DeletionIntents
        let claude: ManagedSession
        let other: ManagedSession
        let codex: ManagedSession
        let preferencesURL: URL

        func cleanup() async {
            await model.stopAndWait()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture(startableProviders: Set<ManagedSession.Provider> = [.claude, .codex]) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-delui-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let claude = ManagedSession(provider: .claude, workingDirectory: root.path)
        let other = ManagedSession(provider: .claude, workingDirectory: root.path)
        let codex = ManagedSession(provider: .codex, workingDirectory: root.path)
        for (index, session) in [claude, other, codex].enumerated() {
            try await catalog.insertSession(
                session, title: "Conversation \(index)", createdAt: Date(timeIntervalSince1970: 1_000 + Double(index)),
                lastUsedAt: Date(timeIntervalSince1970: 10_000 + Double(index)), lifecycle: .idle
            )
        }
        let hub = SessionEventHub()
        let preferencesURL = root.appendingPathComponent("prefs.json")
        let model = CatalogModel(
            catalog: catalog, events: hub, preferences: UIPreferencesStore(url: preferencesURL),
            startableProviders: startableProviders
        )
        let intents = DeletionIntents()
        model.intents = intents
        await model.start()
        return Fixture(root: root, catalog: catalog, hub: hub, model: model, intents: intents,
                       claude: claude, other: other, codex: codex, preferencesURL: preferencesURL)
    }

    private func waitUntil(_ seconds: TimeInterval = 6, _ condition: () async throws -> Bool) async rethrows -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func row(_ fixture: Fixture, _ session: ManagedSession) throws -> SessionRowModel {
        try #require(fixture.model.list(for: .activity).rows.first { $0.id == session.id })
    }

    @Test func confirmingCallsTheRuntimeAndCancelDoesNot() async throws {
        let fixture = try await makeFixture()
        defer { Task { await fixture.cleanup() } }
        let id = fixture.claude.id
        fixture.model.requestDeletion(id)
        #expect(fixture.model.deletions.confirmation?.id == id)
        #expect(await waitUntil { fixture.model.deletions.confirmation?.canConfirm == true })
        // Asking for the numbers is not deleting.
        #expect(fixture.intents.calls == ["preview:\(id)"])
        fixture.model.cancelDeletion()
        #expect(fixture.model.deletions.confirmation == nil)
        await fixture.model.confirmDeletion()
        #expect(fixture.intents.calls == ["preview:\(id)"], "nothing is open to confirm")

        fixture.model.requestDeletion(id)
        #expect(await waitUntil { fixture.model.deletions.confirmation?.canConfirm == true })
        await fixture.model.confirmDeletion()
        #expect(fixture.intents.calls.last == "delete:\(id)")
        #expect(fixture.model.deletions.confirmation == nil)
        #expect(fixture.model.errorMessage == nil)
    }

    @Test func deletingTheSelectedConversationClearsTheSelectionOnDiskAndClosesItsTab() async throws {
        let fixture = try await makeFixture()
        defer { Task { await fixture.cleanup() } }
        let id = fixture.claude.id
        fixture.model.openTab(id)
        fixture.model.openTab(fixture.other.id)
        fixture.model.select(id)
        #expect(fixture.model.selectedSessionID == id)
        #expect(fixture.model.tabs.isPinned(id))

        fixture.model.requestDeletion(id)
        #expect(await waitUntil { fixture.model.deletions.confirmation?.canConfirm == true })
        await fixture.model.confirmDeletion()
        // The selection moved away at once and is persisted.
        #expect(fixture.model.selectedSessionID == nil)
        fixture.model.flushPreferences()
        #expect(UIPreferencesStore(url: fixture.preferencesURL).current.selectedSessionID == nil)

        // The runtime's announcement (a frame) closes the tab; the other tab stays.
        await fixture.hub.publishDeletion(sessionID: id, change: .conversationDeleted)
        #expect(await waitUntil { !fixture.model.tabs.isPinned(id) })
        #expect(fixture.model.tabs.isPinned(fixture.other.id))
        fixture.model.flushPreferences()
        #expect(!UIPreferencesStore(url: fixture.preferencesURL).current.openTabs.contains(id))
    }

    @Test func theSelectionMovesAwayWhileTheDeletionRuns() async throws {
        let fixture = try await makeFixture()
        defer { Task { await fixture.cleanup() } }
        let id = fixture.claude.id
        fixture.model.openTab(fixture.other.id)
        fixture.model.openTab(id)
        fixture.model.deletions.pauseBeforeRuntimeCall = .milliseconds(400)
        fixture.model.requestDeletion(id)
        #expect(await waitUntil { fixture.model.deletions.confirmation?.canConfirm == true })
        let running = Task { await fixture.model.confirmDeletion() }
        #expect(await waitUntil { fixture.model.isDeleting(id) })
        // Still inside the runtime call: nothing has been announced, yet the pane has left it.
        #expect(!fixture.intents.calls.contains("delete:\(id)"))
        #expect(fixture.model.selectedSessionID == nil)
        fixture.model.flushPreferences()
        #expect(UIPreferencesStore(url: fixture.preferencesURL).current.selectedSessionID == nil)
        let row = try row(fixture, fixture.claude)
        #expect(!fixture.model.canResume(row) && !fixture.model.canStop(row) && !fixture.model.canDelete(row))
        // Looking at it again while it is deleted does not leave a neighboring tab selected afterwards.
        fixture.model.select(id)
        await running.value
        #expect(fixture.model.selectedSessionID == nil)
        #expect(!fixture.model.tabs.isPinned(id) && fixture.model.tabs.isPinned(fixture.other.id))
        #expect(!fixture.model.isDeleting(id))
        #expect(fixture.intents.calls.last == "delete:\(id)")
    }

    @Test func aFailedDeletionStaysVisibleAndRetryFinishesIt() async throws {
        let fixture = try await makeFixture()
        defer { Task { await fixture.cleanup() } }
        let id = fixture.claude.id
        fixture.intents.deleteOutcome = .incomplete(pendingRecord(id))
        fixture.model.requestDeletion(id)
        #expect(await waitUntil { fixture.model.deletions.confirmation?.canConfirm == true })
        await fixture.model.confirmDeletion()
        let pending = try #require(fixture.model.deletions.pending[id])
        #expect(pending.lastFailure == "partial_failure: a.jsonl")
        #expect(!fixture.model.isDeleting(id))
        #expect(fixture.model.canRetryDeletion(id))
        // The failure is the banner's; the error banner stays quiet.
        #expect(fixture.model.errorMessage == nil)
        let text = DeletionCopy.bannerText(lastFailure: pending.lastFailure)
        #expect(text.contains("Deleting this session isn't finished."))
        #expect(text.contains("a.jsonl"))
        #expect(text.contains("Nothing else was touched."))

        await fixture.model.retryDeletion(id)
        #expect(fixture.intents.calls.last == "retry:\(id)")
        #expect(fixture.model.deletions.pending[id] == nil)
        #expect(!fixture.model.canRetryDeletion(id))
        // A late, stale pending list does not bring the finished one back.
        fixture.intents.pending = [pendingRecord(id)]
        await fixture.model.refreshPendingDeletions()
        #expect(fixture.model.deletions.pending[id] == nil)
    }

    @Test func aRetryThatFailsAgainKeepsTheBannerWithTheNewReason() async throws {
        let fixture = try await makeFixture()
        defer { Task { await fixture.cleanup() } }
        let id = fixture.claude.id
        fixture.intents.pending = [pendingRecord(id)]
        await fixture.model.refreshPendingDeletions()
        #expect(fixture.model.deletions.pending[id] != nil)
        fixture.intents.retryOutcome = .incomplete(pendingRecord(id, failure: "live_session"))
        await fixture.model.retryDeletion(id)
        #expect(fixture.model.deletions.pending[id]?.lastFailure == "live_session")
        #expect(DeletionCopy.bannerText(lastFailure: "live_session").contains("Claude process"))
    }

    // MARK: Production offers manual delete (the cleanup review is installed by the app, in every build)

    @Test func theProductionConfiguredModelCanRequestConfirmAndRunAManualDelete() async throws {
        // The production app starts Claude only and passes nothing else to the model: no gate remains.
        let production = try await makeFixture(startableProviders: [.claude])
        defer { Task { await production.cleanup() } }
        let id = production.claude.id
        let claudeRow = try row(production, production.claude)
        #expect(production.model.canDelete(claudeRow))
        #expect(production.model.deletionDisabledReason(for: claudeRow) == nil)
        production.model.requestDeletion(id)
        let confirmation = try #require(production.model.deletions.confirmation)
        #expect(await waitUntil { confirmation.canConfirm })
        await production.model.confirmDeletion()
        #expect(production.intents.calls.contains("delete:\(id)"))
        // The cleanup review is the app's to install (every build, D-69): the model never installs it by itself.
        #expect(production.model.cleanupReview == nil)
        // Codex stays refused for its own reason, not for a build gate.
        #expect(production.model.deletionDisabledReason(for: try row(production, production.codex))?.contains("Codex") == true)
    }

    @Test func theDeleteMenuEntryIsNamedDeletePermanently() {
        #expect(DeletionMenuItems.deleteTitle == "Delete Permanently…")
    }

    @Test func aDeletionRecoveredAtLaunchShowsItsFailureAndRetriesInAnyFlavor() async throws {
        for providers in [Set<ManagedSession.Provider>([.claude]), [.claude, .codex]] {
            let fixture = try await makeFixture(startableProviders: providers)
            defer { Task { await fixture.cleanup() } }
            let id = fixture.claude.id
            fixture.intents.pending = [pendingRecord(id, failure: "unreachable_folder: shared")]
            fixture.intents.recoveryFailure = "Interrupted deletions could not be read: x"
            await fixture.model.refreshPendingDeletions()
            #expect(fixture.model.deletions.pending[id]?.lastFailure == "unreachable_folder: shared")
            #expect(fixture.model.deletions.recoveryFailure != nil)
            #expect(fixture.model.canRetryDeletion(id))
            await fixture.model.retryDeletion(id)
            #expect(fixture.intents.calls.contains("retry:\(id)"))
            #expect(fixture.model.deletions.pending[id] == nil)
        }
    }

    @Test func aBlockedConfirmSheetOffersRemovingFromLoomOnlyAndNeverDeletes() async throws {
        let fixture = try await makeFixture()
        defer { Task { await fixture.cleanup() } }
        let id = fixture.claude.id
        // A clear preview offers only the delete.
        fixture.model.requestDeletion(id)
        #expect(await waitUntil { fixture.model.deletions.confirmation?.canConfirm == true })
        #expect(fixture.model.deletions.confirmation?.offersRemoveFromLoomOnly == false)
        fixture.model.requestRemoveFromLoomOnly(id)
        #expect(fixture.model.deletions.removalRequest == nil, "not offered, so no alert")
        await fixture.model.removeFromLoomOnly(id)?.value
        #expect(!fixture.intents.calls.contains("remove:\(id)"), "not offered, so not done")
        fixture.model.cancelDeletion()

        fixture.intents.preview = ConversationDeletionPreview(
            sessionID: UUID(), fileCount: 1, byteCount: 10, configDirectory: "/tmp/claude-config",
            isRunning: false, notRemoved: [], unreachable: ["projects/-work-app"])
        fixture.model.requestDeletion(id)
        #expect(await waitUntil { fixture.model.deletions.confirmation.map { $0.phase != .loading } == true })
        #expect(fixture.model.deletions.confirmation?.offersRemoveFromLoomOnly == true)
        #expect(DeletionCopy.unreachableNote(["projects/-work-app"]).contains("remove the session from Loom only"))
        // The button asks for the alert; only the alert's Remove removes.
        fixture.model.requestRemoveFromLoomOnly(id)
        #expect(fixture.model.deletions.removalRequest == id)
        #expect(!fixture.intents.calls.contains("remove:\(id)"))
        #expect(fixture.model.deletions.confirmation != nil, "the sheet stays under the alert")
        fixture.model.cancelRemoveFromLoomOnly()
        #expect(fixture.model.removeFromLoomOnly(id) == nil, "Cancel took the request away")
        #expect(!fixture.intents.calls.contains("remove:\(id)"))
        fixture.model.requestRemoveFromLoomOnly(id)
        await fixture.model.removeFromLoomOnly(id)?.value
        #expect(fixture.intents.calls.last == "remove:\(id)")
        #expect(!fixture.intents.calls.contains { $0.hasPrefix("delete:") })
        #expect(fixture.model.deletions.confirmation == nil)
        #expect(fixture.model.deletions.removalRequest == nil)
        #expect(fixture.model.deletions.inProgress.isEmpty)
    }

    @Test func bothRemoveFromLoomOnlyPathsAskTheSameQuestion() {
        #expect(DeletionCopy.removeTitle == "Remove this session from Loom?")
        #expect(DeletionCopy.removeButton == "Remove")
        #expect(DeletionCopy.removeMessage.contains("Claude's files stay where they are"))
    }

    @Test func aFailedDeletionOffersRemovingFromLoomOnlyOnceTheFailureIsKnown() async throws {
        let fixture = try await makeFixture()
        defer { Task { await fixture.cleanup() } }
        let id = fixture.claude.id
        // Nothing failed yet, or something is still working on it: not offered.
        #expect(!fixture.model.canRemoveFromLoomOnly(id))
        fixture.intents.pending = [pendingRecord(id, failure: nil, running: true)]
        await fixture.model.refreshPendingDeletions()
        #expect(!fixture.model.canRemoveFromLoomOnly(id))
        fixture.intents.pending = [pendingRecord(id, failure: "unreachable_folder: projects")]
        await fixture.model.refreshPendingDeletions()
        #expect(fixture.model.canRemoveFromLoomOnly(id))
        // Same alert as the sheet's: without its Remove nothing is removed.
        #expect(fixture.model.removeFromLoomOnly(id) == nil)
        #expect(!fixture.intents.calls.contains("remove:\(id)"))
        fixture.model.requestRemoveFromLoomOnly(id)
        #expect(fixture.model.deletions.removalRequest == id)
        await fixture.model.removeFromLoomOnly(id)?.value
        #expect(fixture.intents.calls.contains("remove:\(id)"))
        #expect(fixture.model.deletions.pending[id] == nil)
        // A refusal is reported and the session stays as it was.
        let other = fixture.other.id
        fixture.intents.pending = [pendingRecord(other, failure: "unreachable_folder: projects")]
        fixture.intents.removeError = SessionRuntimeError.deletionRefused("The running session could not be stopped")
        await fixture.model.refreshPendingDeletions()
        fixture.model.requestRemoveFromLoomOnly(other)
        await fixture.model.removeFromLoomOnly(other)?.value
        #expect(fixture.model.errorMessage != nil)
        #expect(fixture.model.deletions.inProgress.isEmpty)
    }

    @Test func aDeletionStillRunningIsNotOfferedARetry() async throws {
        let fixture = try await makeFixture()
        defer { Task { await fixture.cleanup() } }
        let id = fixture.claude.id
        fixture.intents.pending = [pendingRecord(id, failure: nil, running: true)]
        await fixture.model.refreshPendingDeletions()
        #expect(fixture.model.isDeleting(id))
        #expect(!fixture.model.canRetryDeletion(id))
        #expect(!fixture.model.canResume(try row(fixture, fixture.claude)))
    }

    // MARK: Disabled entries

    @Test func codexSyntheticAndBusyRowsAreDisabledWithAReason() async throws {
        let fixture = try await makeFixture()
        defer { Task { await fixture.cleanup() } }
        let codexRow = try row(fixture, fixture.codex)
        #expect(fixture.model.deletionDisabledReason(for: codexRow)?.contains("Codex") == true)
        #expect(!fixture.model.canDelete(codexRow))
        fixture.model.requestDeletion(fixture.codex.id)
        #expect(fixture.model.deletions.confirmation == nil)

        let claudeRow = try row(fixture, fixture.claude)
        #expect(fixture.model.deletionDisabledReason(for: claudeRow) == nil)
        fixture.model.setBusy(fixture.claude.id, .starting)
        #expect(fixture.model.deletionDisabledReason(for: claudeRow) != nil)
        #expect(!fixture.model.canDelete(claudeRow))
        fixture.model.setBusy(fixture.claude.id, nil)
        fixture.model.quitting = true
        #expect(!fixture.model.canDelete(claudeRow))
    }

    // MARK: Confirm copy

    @Test func theConfirmSheetShowsWhatWillBeRemovedAndRefusesWhenAFolderCannotBeRead() async throws {
        let fixture = try await makeFixture()
        defer { Task { await fixture.cleanup() } }
        let body = DeletionCopy.confirmBody(fixture.intents.preview)
        #expect(body.contains("3 files"))
        #expect(body.contains("/tmp/claude-config"))
        #expect(body.contains("can't be undone"))
        #expect(body.contains("Not removed"))
        #expect(body.contains("shared prompt history"))

        fixture.intents.preview = ConversationDeletionPreview(
            sessionID: UUID(), fileCount: 1, byteCount: 10, configDirectory: "/tmp/claude-config",
            isRunning: true, notRemoved: [], unreachable: ["shared-projects"]
        )
        fixture.model.requestDeletion(fixture.claude.id)
        #expect(await waitUntil { fixture.model.deletions.confirmation.map { $0.phase != .loading } == true })
        let confirmation = try #require(fixture.model.deletions.confirmation)
        #expect(!confirmation.canConfirm)
        let note = DeletionCopy.unreachableNote(["shared-projects"])
        #expect(note.contains("cannot look inside shared-projects"))
        #expect(note.contains("link or on another disk"))
        await fixture.model.confirmDeletion()
        #expect(!fixture.intents.calls.contains { $0.hasPrefix("delete:") })
        #expect(DeletionCopy.confirmBody(try #require({ () -> ConversationDeletionPreview? in
            if case let .ready(preview) = confirmation.phase { return preview } else { return nil }
        }())).contains("running"))
    }

    @Test func aRefusedPreviewIsShownAndCannotBeConfirmed() async throws {
        let fixture = try await makeFixture()
        defer { Task { await fixture.cleanup() } }
        fixture.intents.previewError = SessionRuntimeError.deletionRefused("The Claude data folder is not safe to change")
        fixture.model.requestDeletion(fixture.claude.id)
        #expect(await waitUntil { fixture.model.deletions.confirmation.map { $0.phase != .loading } == true })
        let confirmation = try #require(fixture.model.deletions.confirmation)
        guard case let .unavailable(message) = confirmation.phase else { Issue.record("expected unavailable"); return }
        #expect(message.contains("not safe to change"))
        #expect(!confirmation.canConfirm)
    }

    @Test func everyFailureCategoryHasAPlainReason() {
        let categories = ["stop_failed", "stop_unverified", "live_session", "unsafe_directory", "partial_failure",
                          "refused", "plan_failed", "unreachable_folder", "catalog_row_remains",
                          "provider_id_reappeared", "still_running", "leftover_files", "verify_failed",
                          "forget_hook_failed", "step_failed", "unsupported_provider"]
        for category in categories {
            let reason = DeletionCopy.failureReason(category)
            #expect(!reason.isEmpty && !reason.contains("_"), "\(category): \(reason)")
        }
        #expect(DeletionCopy.failureReason("partial_failure: x.jsonl").contains("x.jsonl"))
        #expect(DeletionCopy.failureReason("unreachable_folder: linked").contains("cannot look inside linked"))
        // Unknown categories and a missing reason never show a raw code.
        #expect(!DeletionCopy.failureReason("brand_new_thing").contains("_"))
        #expect(!DeletionCopy.failureReason(nil).isEmpty)
    }

    // MARK: Real runtime, synthetic Claude tree

    private struct Real {
        let root: URL
        let profile: URL
        let catalog: SessionCatalog
        let runtime: SessionRuntime
        let model: CatalogModel
        let controller: ConversationController
        let preferencesURL: URL
        let forgotten: ForgetLog
        let socketDirectory: URL

        func file(_ relative: String) -> URL { profile.appendingPathComponent(relative) }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: file(relative).path) }

        @MainActor func cleanup() async {
            controller.stopObserving()
            await model.stopAndWait()
            _ = await runtime.shutdown()
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: file("projects/p").path)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: socketDirectory)
        }
    }

    final class ForgetLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(UUID, [String])] = []
        func record(_ id: UUID, _ ids: [String]) { lock.withLock { storage.append((id, ids)) } }
        var all: [(UUID, [String])] { lock.withLock { storage } }
    }

    private func makeReal() async throws -> Real {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-delreal-\(UUID())", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let state = root.appendingPathComponent("fake-state", isDirectory: true)
        let profile = root.appendingPathComponent("claude-config", isDirectory: true)
        let temporary = root.appendingPathComponent("tmp-claude", isDirectory: true)
        for directory in [home, state, profile, temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let socketDirectory = URL(fileURLWithPath: "/tmp/ld-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let hub = SessionEventHub()
        let binaries = Bundle(for: DeletionBundleAnchor.self).bundleURL.deletingLastPathComponent()
        let supervisor = try await ProcessSupervisor.restoring(ledger: OwnershipLedger(), catalog: catalog, events: hub)
        let fake = binaries.appendingPathComponent("loom-fake-provider").path
        let forgotten = ForgetLog()
        let forgetters = ConversationForgetters()
        forgetters.register { id, ids in forgotten.record(id, ids) }
        let runtime = SessionRuntime(
            supervisor: supervisor, catalog: catalog,
            configuration: SessionRuntimeConfiguration(
                toolchains: { provider in
                    ProviderToolchain(
                        provider: provider, executable: fake,
                        capabilities: ProviderCapabilities(
                            version: "fake", help: "--settings <s> --session-id <i> --remote <A>",
                            serverHelp: "--listen <U>"
                        ),
                        environment: ["PATH": "/usr/bin:/bin", "HOME": home.path, "LOOM_FAKE_STATE": state.path],
                        profileDirectory: profile
                    )
                },
                hookHelperPath: binaries.appendingPathComponent("loom-hook").path,
                socketDirectory: socketDirectory, homeDirectory: home.path,
                claudeTemporaryRoot: temporary, forgetters: forgetters,
                // Deletion finds the profile without the CLI; never the runner's own environment.
                claudeProfileDirectory: profile, claudeEnvironment: [:]
            )
        )
        try await runtime.start()
        let preferencesURL = root.appendingPathComponent("prefs.json")
        let model = CatalogModel(catalog: catalog, events: hub, preferences: UIPreferencesStore(url: preferencesURL))
        let controller = ConversationController(runtime: runtime, model: model)
        await controller.begin()
        await model.start()
        return Real(root: root, profile: profile, catalog: catalog, runtime: runtime, model: model,
                    controller: controller, preferencesURL: preferencesURL, forgotten: forgotten,
                    socketDirectory: socketDirectory)
    }

    /// A stopped Claude conversation with files named by its provider id.
    private func addConversation(_ real: Real, title: String) async throws -> (session: ManagedSession, id: String) {
        let id = UUID().uuidString.lowercased()
        let session = ManagedSession(provider: .claude, providerConversationID: id, workingDirectory: real.root.path)
        try await real.catalog.insertSession(session, title: title, lifecycle: .idle)
        let files = ["projects/p/\(id).jsonl", "projects/p/\(id)/subagents/agent-1.jsonl", "file-history/\(id)/v1"]
        for file in files {
            let url = real.file(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("data of \(id)".utf8).write(to: url)
        }
        return (session, id)
    }

    @Test func deletingThroughTheRealRuntimeRemovesOnlyThatConversationsFiles() async throws {
        let real = try await makeReal()
        do {
            let target = try await addConversation(real, title: "Target")
            let keep = try await addConversation(real, title: "Keep")
            try Data("shared prompts".utf8).write(to: real.file("history.jsonl"))
            real.model.scheduleRefresh()
            await real.model.settle()
            let model = real.model
            model.openTab(target.session.id)
            model.openTab(keep.session.id)
            model.select(target.session.id)

            model.requestDeletion(target.session.id)
            #expect(await waitUntil { model.deletions.confirmation?.canConfirm == true })
            guard case let .ready(preview) = model.deletions.confirmation?.phase else { Issue.record("no preview"); return }
            #expect(preview.fileCount >= 3)
            #expect(preview.configDirectory.hasSuffix("claude-config"))
            #expect(real.exists("projects/p/\(target.id).jsonl"), "previewing removes nothing")

            await model.confirmDeletion()
            #expect(try await waitUntil { try await real.catalog.session(id: target.session.id) == nil })
            #expect(await waitUntil { !model.tabs.isPinned(target.session.id) })
            #expect(model.selectedSessionID == nil)
            model.flushPreferences()
            #expect(UIPreferencesStore(url: real.preferencesURL).current.selectedSessionID == nil)
            for file in ["projects/p/\(target.id).jsonl", "projects/p/\(target.id)", "file-history/\(target.id)"] {
                #expect(!real.exists(file), "\(file) is removed")
            }
            #expect(real.exists("projects/p/\(keep.id).jsonl"))
            #expect(real.exists("file-history/\(keep.id)/v1"))
            #expect(real.exists("history.jsonl"))
            #expect(model.tabs.isPinned(keep.session.id))
            // The forget hooks ran with this conversation's ids.
            let call = try #require(real.forgotten.all.first { $0.0 == target.session.id })
            #expect(call.1.contains(target.id))
            #expect(real.forgotten.all.allSatisfy { $0.0 != keep.session.id })
            await model.settle()
            #expect(!model.list(for: .activity).rows.contains { $0.id == target.session.id })
            #expect(model.deletions.pending.isEmpty)
            #expect(model.errorMessage == nil)
        } catch {
            await real.cleanup()
            throw error
        }
        await real.cleanup()
    }

    @Test func aFileThatCannotBeRemovedLeavesAVisibleFailureAndRetryFinishesIt() async throws {
        let real = try await makeReal()
        do {
            let target = try await addConversation(real, title: "Stuck")
            real.model.scheduleRefresh()
            await real.model.settle()
            let model = real.model
            // A read-only folder: the transcript cannot be unlinked.
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: real.file("projects/p").path)
            model.requestDeletion(target.session.id)
            #expect(await waitUntil { model.deletions.confirmation?.canConfirm == true })
            await model.confirmDeletion()
            let pending = try #require(model.deletions.pending[target.session.id])
            #expect(pending.lastFailure?.hasPrefix("partial_failure") == true)
            #expect(model.canRetryDeletion(target.session.id))
            #expect(DeletionCopy.bannerText(lastFailure: pending.lastFailure).contains("Nothing else was touched."))

            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: real.file("projects/p").path)
            await model.retryDeletion(target.session.id)
            #expect(model.deletions.pending[target.session.id] == nil)
            #expect(!real.exists("projects/p/\(target.id).jsonl"))
            #expect(try await waitUntil { try await real.catalog.session(id: target.session.id) == nil })
        } catch {
            await real.cleanup()
            throw error
        }
        await real.cleanup()
    }
}
