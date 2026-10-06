import AppKit
import Foundation
import LoomCore
import LoomTerminal
import Testing
@testable import LoomCatalogUI

private final class ControllerBundleAnchor: NSObject {}

/// CP5 C at the presentation boundary: the real model, controller, runtime,
/// supervisor and catalog against provider-shaped fixtures. Native AppKit
/// clicks are not exercised here; the intents are what the buttons call.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ConversationControllerTests {
    struct Fixture {
        let root: URL
        let socketDirectory: URL
        let catalog: SessionCatalog
        let hub: SessionEventHub
        let supervisor: ProcessSupervisor
        let runtime: SessionRuntime
        let model: CatalogModel
        let controller: ConversationController
        let home: URL

        @MainActor func cleanup() async {
            controller.stopObserving()
            model.stop()
            _ = await runtime.shutdown()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: socketDirectory)
        }
    }

    private func makeFixture(
        idle: SessionIdlePolicy = SessionIdlePolicy(), startWindowActive: Bool = false,
        extraEnvironment: [String: String] = [:], scoped: Bool = false
    ) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-controller-\(UUID())", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let state = root.appendingPathComponent("fake-state", isDirectory: true)
        for directory in [home, state] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let socketDirectory = URL(fileURLWithPath: "/tmp/lc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let hub = SessionEventHub()
        var binaries = Bundle(for: ControllerBundleAnchor.self).bundleURL.deletingLastPathComponent()
        var launcher: RunScopeLauncher?
        if scoped {
            // Run hosts are their own TCC-responsible apps, and build products may
            // live under ~/Documents: scoped children run copies from a temp folder.
            let copies = root.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
            for name in ["loom-fake-provider", "loom-hook"] {
                try FileManager.default.copyItem(at: binaries.appendingPathComponent(name),
                                                 to: copies.appendingPathComponent(name))
            }
            let bundle = try RunScopeLauncher.assembleOwnedBundle(
                executable: binaries.appendingPathComponent("loom-run-host"), in: root)
            launcher = RunScopeLauncher(hostBundle: bundle, socketDirectory: socketDirectory.appendingPathComponent("scopes"))
            binaries = copies
        }
        let supervisor = try await ProcessSupervisor.restoring(
            ledger: OwnershipLedger(), catalog: catalog, events: hub,
            scopeLauncher: launcher
        )
        let fake = binaries.appendingPathComponent("loom-fake-provider").path
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
                        environment: ["PATH": "/usr/bin:/bin", "HOME": home.path, "LOOM_FAKE_STATE": state.path]
                            .merging(extraEnvironment) { _, value in value },
                        profileDirectory: root.appendingPathComponent("profile")
                    )
                },
                hookHelperPath: binaries.appendingPathComponent("loom-hook").path,
                socketDirectory: socketDirectory, homeDirectory: home.path, idlePolicy: idle,
                codexIdentityTimeout: 0.2
            )
        )
        try await runtime.start()
        let model = CatalogModel(
            catalog: catalog, events: hub,
            preferences: UIPreferencesStore(url: root.appendingPathComponent("prefs.json"))
        )
        let controller = ConversationController(runtime: runtime, model: model)
        await controller.begin()
        await model.start()
        if startWindowActive { model.setWindowActive(true) }
        return Fixture(
            root: root, socketDirectory: socketDirectory, catalog: catalog, hub: hub,
            supervisor: supervisor, runtime: runtime, model: model, controller: controller, home: home
        )
    }

    /// Runs a test body and always shuts the runtime down, so no fixture
    /// process outlives its test.
    private func withFixture(
        idle: SessionIdlePolicy = SessionIdlePolicy(), scoped: Bool = false,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let fixture = try await makeFixture(idle: idle, scoped: scoped)
        do { try await body(fixture) }
        catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    private func waitUntil(
        _ seconds: TimeInterval = 6, _ condition: () async throws -> Bool
    ) async rethrows -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func type(_ text: String, into surface: TerminalSurface) {
        surface.send(source: surface.view, data: ArraySlice(Array((text + "\r").utf8)))
    }

    private func surface(_ fixture: Fixture, for sessionID: UUID) -> TerminalSurface? {
        fixture.controller.entries.values.first { $0.owner == sessionID }?.surface
    }

    @Test func fontPreferenceAppliesToExistingAndNewConversationSurfaces() async throws {
        try await withFixture { fixture in
            fixture.model.onTerminalFontSizeChange = { fixture.controller.setTerminalFontSize($0) }
            fixture.model.setTerminalFontSize(18)
            fixture.model.startConversation(.claude, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            let first = try #require(fixture.controller.entries.values.first?.surface)
            #expect(first.view.font.pointSize == 18)
            fixture.model.setTerminalFontSize(20)
            #expect(first.view.font.pointSize == 20)
            #expect(await waitUntil { !fixture.model.isStarting(.claude, projectID: nil) })
            fixture.model.startConversation(.claude, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 2 })
            #expect(fixture.controller.entries.values.allSatisfy { $0.surface.view.font.pointSize == 20 })
        }
    }

    /// The app's real configuration: every run starts in its own run-host
    /// scope. The card, its terminal and Stop must work through that scope.
    @Test func scopedStartRunsInsideARunHostAndStopEmptiesTheScope() async throws {
        try await withFixture(scoped: true) { fixture in
            fixture.model.startConversation(.claude, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 && fixture.model.selectedSessionID != nil })
            let sessionID = try #require(fixture.model.selectedSessionID)
            let surface = try #require(surface(fixture, for: sessionID))
            #expect(await waitUntil { surface.screenText().contains("FAKE-CLAUDE READY") })
            type("through the scope", into: surface)
            #expect(await waitUntil { surface.screenText().contains("echo: through the scope") })

            let members = try await fixture.supervisor.liveScopeMembers()
            #expect(members.contains { $0.launchdSpawned }, "the run host is a scope member")
            let provider = try #require(members.first { !$0.launchdSpawned }, "the provider is a scope member")
            #expect(ProcessTable.resourceCoalition(pid: provider.identity.pid) != ProcessTable.resourceCoalition(pid: getpid()))

            fixture.model.stopConversation(sessionID)
            #expect(await waitUntil { fixture.controller.terminalCount == 0 && fixture.model.busy[sessionID] == nil })
            #expect(await waitUntil { ((try? await fixture.supervisor.liveScopeMembers()) ?? [provider]).isEmpty })
        }
    }

    // MARK: C1

    @Test func startCreatesOneCardWithAWorkingTerminalAndRepeatedClicksAddNoSecondRun() async throws {
        try await withFixture { fixture in
            #expect(fixture.model.actionsAvailable)
            #expect(fixture.controller.terminalCount == 0)

            fixture.model.startConversation(.claude, projectID: nil)
            fixture.model.startConversation(.claude, projectID: nil) // second click
            #expect(fixture.model.isStarting(.claude, projectID: nil))
            #expect(!fixture.model.canStart(.claude, projectID: nil))
            #expect(await waitUntil { fixture.controller.terminalCount == 1 && fixture.model.selectedSessionID != nil })
            try await Task.sleep(for: .milliseconds(200))
            #expect(fixture.controller.terminalCount == 1)
            #expect(try await fixture.catalog.sessions().count == 1)
            #expect(!fixture.model.isStarting(.claude, projectID: nil))

            let sessionID = try #require(fixture.model.selectedSessionID)
            let surface = try #require(surface(fixture, for: sessionID))
            #expect(fixture.model.terminalView(for: sessionID) != nil)
            #expect(await waitUntil { surface.screenText().contains("FAKE-CLAUDE READY") })
            type("hello ui", into: surface)
            #expect(await waitUntil { surface.screenText().contains("echo: hello ui") })

            // The card knows it is live and offers Stop, not Resume.
            await fixture.model.settle()
            let row = try #require(fixture.model.selectedRow)
            #expect(fixture.model.canStop(row))
            #expect(!fixture.model.canResume(row))
        }
    }

    @Test func projectStartRunsInTheProjectFolderAndAppearsInThatProject() async throws {
        try await withFixture { fixture in
            let folder = fixture.root.appendingPathComponent("proj", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await fixture.model.addProject(path: folder.path)?.project
            let id = try #require(project?.id)
            fixture.model.startConversation(.codex, projectID: id)
            #expect(await waitUntil { fixture.model.selectedSessionID != nil })
            let sessionID = try #require(fixture.model.selectedSessionID)
            #expect(try await fixture.catalog.session(id: sessionID)?.projectID == id)
            let surface = try #require(surface(fixture, for: sessionID))
            #expect(await waitUntil { surface.screenText().contains("FAKE-CODEX READY") })
            #expect(surface.screenText().contains("cwd="))
        }
    }

    @Test func missingProjectFolderShowsAnErrorAndCreatesNothing() async throws {
        try await withFixture { fixture in
            let folder = fixture.root.appendingPathComponent("vanishing", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try #require(try await fixture.model.addProject(path: folder.path)?.project)
            try FileManager.default.removeItem(at: folder)
            fixture.model.startConversation(.claude, projectID: project.id)
            #expect(await waitUntil { fixture.model.errorMessage != nil })
            #expect(fixture.model.errorMessage?.contains("no longer exists") == true)
            #expect(try await fixture.catalog.sessions().isEmpty)
            #expect(fixture.controller.terminalCount == 0)
            #expect(!fixture.model.isStarting(.claude, projectID: project.id))
        }
    }

    @Test func aCatalogErrorOrQuitBlocksEveryAction() async throws {
        try await withFixture { fixture in
            fixture.controller.quitStarted()
            #expect(!fixture.model.actionsAvailable)
            fixture.model.startConversation(.claude, projectID: nil)
            try await Task.sleep(for: .milliseconds(150))
            #expect(fixture.controller.terminalCount == 0)
            #expect(try await fixture.catalog.sessions().isEmpty)

            let broken = CatalogModel(
                catalog: nil, startupError: "catalog is unreadable", events: SessionEventHub(),
                preferences: UIPreferencesStore(url: fixture.root.appendingPathComponent("p2.json"))
            )
            #expect(!broken.actionsAvailable)
            #expect(!broken.canStart(.claude, projectID: nil))
        }
    }

    // MARK: C2 / C5 ownership, stop and resume

    @Test func terminalResolvedInputDisappearsFromTheCardWithoutSendingAnAnswer() async throws {
        try await withFixture { fixture in
            fixture.model.startConversation(.codex, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            let id = try #require(fixture.model.selectedSessionID)
            let terminal = try #require(surface(fixture, for: id))
            #expect(await waitUntil { terminal.screenText().contains("FAKE-CODEX READY") })
            type("input", into: terminal)
            #expect(await waitUntil { fixture.model.selectedRow?.live?.userRequests.count == 1 })
            type("/resolve-first", into: terminal)
            #expect(await waitUntil { fixture.model.selectedRow?.live?.userRequests.isEmpty == true })
            #expect(await fixture.supervisor.providerWorkState(sessionID: id)?.pendingProviderWorkCount == 0)
            #expect(fixture.model.selectedSessionID == id)
            #expect(surface(fixture, for: id) === terminal)
            #expect(fixture.model.errorMessage == nil)
        }
    }

    @Test func helperThreadKeepsTheSelectedTerminalAndExportsSafeStopDiagnostics() async throws {
        let fixture = try await makeFixture(extraEnvironment: ["LOOM_FAKE_CODEX_STOP_FAILURE": "prepare"])
        do {
            fixture.model.startConversation(.codex, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            let id = try #require(fixture.model.selectedSessionID)
            let original = try #require(surface(fixture, for: id))
            #expect(try await waitUntil { try await fixture.catalog.session(id: id)?.session.providerConversationID != nil })
            let thread = try #require(try await fixture.catalog.session(id: id)?.session.providerConversationID)
            let runID = try #require(await fixture.supervisor.session(id: id)?.currentRun?.id)
            type("/helper", into: original)
            #expect(try await waitUntil {
                await fixture.runtime.codexRoutingDiagnostics().entries.filter { $0.decision == "unmatched" }.count >= 2
            })
            await fixture.model.settle()
            #expect(fixture.model.selectedSessionID == id)
            #expect(surface(fixture, for: id) === original)
            #expect(try await fixture.catalog.sessions().count == 1)
            #expect(await fixture.hub.snapshot().sessions[id]?.identity == .known)
            fixture.model.stopConversation(id)
            #expect(try await waitUntil { await fixture.supervisor.lastStopReport(sessionID: id) != nil })
            #expect(await waitUntil { fixture.model.busy[id] == nil })
            #expect(fixture.model.errorMessage?.contains("Provider prepare failed (rpc, RPC -32041)") == true)
            #expect(fixture.model.errorMessage?.contains("private-provider-error-text") == false)
            let evidence = await fixture.controller.runtimeEvidence()
            let json = String(decoding: try JSONSerialization.data(withJSONObject: evidence), as: UTF8.self)
            #expect(json.contains("ignoredEphemeral") && json.contains("prepare"))
            #expect(json.contains("-32041") && json.contains(thread))
            #expect(!json.contains("private-provider-error-text") && !json.contains("private-originator-value"))
            #expect(surface(fixture, for: id) === original)
            try await fixture.supervisor.registerStopHooks(runID: runID,
                hooks: ManagedRunStopHooks(prepare: {}, completed: {}))
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    @Test func stopThenResumeReturnsTheSameCardToALiveTerminal() async throws {
        try await withFixture { fixture in
            fixture.model.startConversation(.claude, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            let sessionID = try #require(fixture.model.selectedSessionID)
            let first = try #require(surface(fixture, for: sessionID))
            #expect(await waitUntil { first.screenText().contains("FAKE-CLAUDE READY") })
            type("remember me", into: first)
            #expect(await waitUntil { first.screenText().contains("echo: remember me") })
            #expect(try await waitUntil { try await fixture.catalog.session(id: sessionID)?.session.providerConversationID != nil })

            fixture.model.stopConversation(sessionID)
            #expect(await waitUntil { fixture.controller.terminalCount == 0 && fixture.model.busy[sessionID] == nil })
            #expect(fixture.model.terminalView(for: sessionID) == nil)
            await fixture.model.settle()
            let stoppedRow = try #require(fixture.model.selectedRow)
            #expect(fixture.model.canResume(stoppedRow))
            #expect(!fixture.model.canStop(stoppedRow))

            fixture.model.resumeConversation(sessionID)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            let resumed = try #require(surface(fixture, for: sessionID))
            #expect(resumed !== first)
            #expect(await waitUntil { resumed.screenText().contains("remembered=1") })
            #expect(try await fixture.catalog.sessions().count == 1)
        }
    }

    @Test func clearMovesTheTerminalToTheNewCardAndTheOldCardsCallbacksCannotWriteThere() async throws {
        try await withFixture { fixture in
            fixture.model.startConversation(.claude, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            let oldID = try #require(fixture.model.selectedSessionID)
            let terminalSurface = try #require(surface(fixture, for: oldID))
            #expect(await waitUntil { terminalSurface.screenText().contains("FAKE-CLAUDE READY") })
            type("before clear", into: terminalSurface)
            #expect(try await waitUntil { try await fixture.catalog.session(id: oldID)?.session.providerConversationID != nil })

            type("/clear", into: terminalSurface)
            #expect(try await waitUntil { try await fixture.catalog.sessions().count == 2 })
            let newID = try #require(try await fixture.catalog.sessions().first { $0.session.id != oldID }?.session.id)
            #expect(await waitUntil { fixture.controller.entries.values.first?.owner == newID })
            // The user was looking at this terminal, so the selection follows it.
        #expect(await waitUntil { fixture.model.selectedSessionID == newID })
        // The same terminal now belongs to the new card; the old card shows history.
            #expect(surface(fixture, for: newID) === terminalSurface)
            #expect(fixture.model.terminalView(for: oldID) == nil)
            #expect(fixture.model.terminalView(for: newID) != nil)

            // A title announced by the terminal goes to whoever owns the run now.
            terminalSurface.setTerminalTitle(source: terminalSurface.view, title: "Fresh topic")
            #expect(try await waitUntil { try await fixture.catalog.session(id: newID)?.title == "Fresh topic" })
            #expect(try await fixture.catalog.session(id: oldID)?.title == nil)

            // An action from the old card cannot touch the new conversation's run.
            fixture.model.stopConversation(oldID)
            try await Task.sleep(for: .milliseconds(300))
            #expect(fixture.controller.terminalCount == 1)
            #expect(await fixture.supervisor.session(id: newID)?.currentRun != nil)
        }
    }

    // MARK: U3 conversation tabs

    @Test func startAndResumePinATabAndStopThenCloseKeepsTheCardOnly() async throws {
        try await withFixture { fixture in
            fixture.model.startConversation(.claude, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            let sessionID = try #require(fixture.model.selectedSessionID)
            #expect(fixture.model.tabs.pinned == [sessionID])
            #expect(fixture.model.visibleTabIDs == [sessionID])

            // Closing the tab never stops the run: the terminal stays.
            fixture.model.closeTab(sessionID)
            try await Task.sleep(for: .milliseconds(200))
            #expect(fixture.model.tabs.pinned.isEmpty)
            #expect(fixture.controller.terminalCount == 1)
            #expect(fixture.model.terminalView(for: sessionID) != nil)

            fixture.model.stopConversation(sessionID)
            #expect(await waitUntil { fixture.controller.terminalCount == 0 && fixture.model.busy[sessionID] == nil })
            fixture.model.resumeConversation(sessionID)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            #expect(await waitUntil { fixture.model.tabs.pinned == [sessionID] })
            #expect(fixture.model.selectedSessionID == sessionID)
        }
    }

    @Test func clearReplacesThePinnedTabInPlaceAndNeighborsStay() async throws {
        try await withFixture { fixture in
            let neighbor = ManagedSession(provider: .claude, workingDirectory: "/tmp")
            try await fixture.catalog.insertSession(neighbor, title: "Neighbor", lifecycle: .idle)
            fixture.model.openTab(neighbor.id)
            fixture.model.startConversation(.claude, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            let oldID = try #require(fixture.model.selectedSessionID)
            #expect(fixture.model.tabs.pinned == [neighbor.id, oldID])
            let terminalSurface = try #require(surface(fixture, for: oldID))
            #expect(await waitUntil { terminalSurface.screenText().contains("FAKE-CLAUDE READY") })
            type("before clear", into: terminalSurface)
            #expect(try await waitUntil { try await fixture.catalog.session(id: oldID)?.session.providerConversationID != nil })

            type("/clear", into: terminalSurface)
            #expect(try await waitUntil { try await fixture.catalog.sessions().count == 3 })
            let newID = try #require(try await fixture.catalog.sessions()
                .first { $0.session.id != oldID && $0.session.id != neighbor.id }?.session.id)
            #expect(await waitUntil { fixture.model.tabs.pinned == [neighbor.id, newID] })
            #expect(await waitUntil { fixture.model.selectedSessionID == newID })
            #expect(fixture.model.visibleTabIDs == [neighbor.id, newID])
            #expect(await waitUntil { fixture.model.tabRow(newID) != nil })
        }
    }

    @Test func selectingAndOpeningTabsOfStoppedConversationsCreatesNoTerminal() async throws {
        try await withFixture { fixture in
            var created: [UUID] = []
            for index in 0..<3 {
                let session = ManagedSession(provider: .claude, workingDirectory: "/tmp")
                created.append(session.id)
                try await fixture.catalog.insertSession(session, title: "Old \(index)", lifecycle: .idle)
            }
            for id in created { fixture.model.openTab(id) }
            for id in created.reversed() { fixture.model.select(id) }
            fixture.model.closeTab(created[0])
            try await Task.sleep(for: .milliseconds(200))
            #expect(fixture.controller.terminalCount == 0)
            #expect(await fixture.supervisor.runningSessionIDs().isEmpty)
        }
    }

    // MARK: C3 viewing

    @Test func onlyAVisibleActiveSelectionUpdatesUseTimeAndStaleStaysStale() async throws {
        try await withFixture { fixture in
            // Older than the idle threshold but far from the stale one, so the running
            // lifecycle timer leaves the idle row alone.
            let old = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3 * 3_600).rounded())
            let idle = ManagedSession(provider: .claude, providerConversationID: "i", workingDirectory: fixture.home.path)
            let stale = ManagedSession(provider: .codex, providerConversationID: "s", workingDirectory: fixture.home.path)
            for (session, state) in [(idle, SessionLifecycle.idle), (stale, .stale)] {
                try await fixture.catalog.insertSession(session, createdAt: old, lastUsedAt: old, lifecycle: state)
            }
            await fixture.model.start()

            // Window not active: selecting and refreshing count as nothing.
            fixture.model.select(idle.id)
            fixture.model.select(stale.id)
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await fixture.catalog.session(id: idle.id)?.lastUsedAt == old)
            #expect(try await fixture.catalog.session(id: stale.id)?.lastUsedAt == old)

            // A visible, active window makes the selection a view.
            fixture.model.setWindowActive(true)
            #expect(try await waitUntil { try await fixture.catalog.session(id: stale.id)?.lastUsedAt != old })
            #expect(try await fixture.catalog.session(id: stale.id)?.lifecycle == .stale)
            fixture.model.select(idle.id)
            #expect(try await waitUntil { try await fixture.catalog.session(id: idle.id)?.lastUsedAt != old })
            #expect(try await fixture.catalog.session(id: idle.id)?.lifecycle == .idle)
            // Selecting started nothing.
            #expect(fixture.controller.terminalCount == 0)
            #expect(await fixture.supervisor.runningSessionIDs().isEmpty)

            fixture.model.setWindowActive(false)
            let before = try await fixture.catalog.session(id: idle.id)?.lastUsedAt
            fixture.model.select(stale.id)
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await fixture.catalog.session(id: idle.id)?.lastUsedAt == before)
        }
    }

    // MARK: C4 Codex request through the card

    @Test func aCodexApprovalAppearsOnTheCardAndOnlyTheUsersAnswerResolvesIt() async throws {
        try await withFixture { fixture in
            fixture.model.startConversation(.codex, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            let sessionID = try #require(fixture.model.selectedSessionID)
            let terminalSurface = try #require(surface(fixture, for: sessionID))
            #expect(await waitUntil { terminalSurface.screenText().contains("FAKE-CODEX READY") })
            #expect(try await waitUntil { try await fixture.catalog.session(id: sessionID)?.session.providerConversationID != nil })

            type("approve this", into: terminalSurface)
            #expect(await waitUntil { fixture.model.selectedRow?.live?.userRequests.count == 1 })
            let request = try #require(fixture.model.selectedRow?.live?.userRequests.first)
            #expect(request.isAnswerable)
            #expect(fixture.model.selectedRow?.indicator == .waitingForApproval)
            try await Task.sleep(for: .milliseconds(300))
            #expect(!terminalSurface.screenText().contains("CODEX-TURN-DONE"))

            fixture.model.answerRequest(sessionID: sessionID, requestID: request.id, accept: true)
            #expect(await waitUntil { terminalSurface.screenText().contains("CODEX-TURN-DONE completed approved") })
            #expect(await waitUntil { fixture.model.selectedRow?.live?.userRequests.isEmpty == true })
        }
    }

    @Test func clearDoesNotStealTheSelectionOfSomeoneWhoLeftTheTerminal() async throws {
        try await withFixture { fixture in
            fixture.model.startConversation(.claude, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            let oldID = try #require(fixture.model.selectedSessionID)
            let surface = try #require(surface(fixture, for: oldID))
            #expect(await waitUntil { surface.screenText().contains("FAKE-CLAUDE READY") })
            type("before clear", into: surface)
            #expect(try await waitUntil { try await fixture.catalog.session(id: oldID)?.session.providerConversationID != nil })
            let other = ManagedSession(provider: .codex, providerConversationID: "elsewhere", workingDirectory: fixture.home.path)
            try await fixture.catalog.insertSession(other, lifecycle: .idle)
            fixture.model.select(other.id)

            type("/clear", into: surface)
            #expect(try await waitUntil { try await fixture.catalog.sessions().count == 3 })
            #expect(await waitUntil { fixture.controller.entries.values.first?.owner != oldID })
            try await Task.sleep(for: .milliseconds(300))
            #expect(fixture.model.selectedSessionID == other.id)
        }
    }

    @Test func redactedEvidenceCarriesTokenPresenceAndNoScreenText() async throws {
        try await withFixture { fixture in
            fixture.model.startConversation(.claude, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            let id = try #require(fixture.model.selectedSessionID)
            let surface = try #require(surface(fixture, for: id))
            #expect(await waitUntil { surface.screenText().contains("FAKE-CLAUDE READY") })
            type("secret-ish prompt LOOM_TOKEN", into: surface)
            #expect(await waitUntil { surface.screenText().contains("echo: secret-ish prompt LOOM_TOKEN") })

            let redacted = try #require(fixture.controller.terminalEvidence(
                redacted: true, tokens: ["LOOM_TOKEN", "ABSENT"]
            ).first)
            #expect(redacted.screenTail == nil)
            #expect(redacted.tokenPresence == ["LOOM_TOKEN": true, "ABSENT": false])
            let raw = try #require(fixture.controller.terminalEvidence().first)
            #expect(raw.screenTail?.contains("secret-ish") == true)
        }
    }

    @Test func identityGateShowsTerminalAcceptsInputAndKeepsTheSameSurface() async throws {
        let fixture = try await makeFixture(extraEnvironment: ["LOOM_FAKE_CODEX_INPUT_BEFORE_IDENTITY": "1"])
        do {
            fixture.model.startConversation(.codex, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            let id = try #require(fixture.model.selectedSessionID)
            let terminal = try #require(surface(fixture, for: id))
            let run = try #require(fixture.controller.entries.values.first?.runID)
            #expect(await waitUntil { terminal.screenText().contains("BEFORE-IDENTITY") })
            // Outlive the headless deadline without silently accepting a prompt.
            try await Task.sleep(for: .milliseconds(400))
            #expect(try await fixture.catalog.session(id: id)?.session.providerConversationID == nil)
            #expect(fixture.model.busy[id] == .starting)
            #expect(fixture.model.terminalView(for: id) != nil)
            await fixture.model.settle()
            #expect(fixture.model.canStop(try #require(fixture.model.selectedRow)))
            fixture.model.startConversation(.codex, projectID: nil)
            #expect(try await fixture.catalog.sessions().count == 1)
            type("continue", into: terminal)
            #expect(await waitUntil { !fixture.model.isStarting(.codex, projectID: nil) })
            #expect(try await fixture.catalog.session(id: id)?.session.providerConversationID != nil)
            #expect(surface(fixture, for: id) === terminal)
            #expect(fixture.controller.entries[run]?.owner == id)
            #expect(fixture.model.busy[id] == nil)
            #expect(fixture.model.errorMessage == nil)
        } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    @Test(arguments: ["stop", "quit", "exit", "connection"])
    func identityGateEndsWithoutLeavingTerminalsOrLeases(_ action: String) async throws {
        let fixture = try await makeFixture(extraEnvironment: ["LOOM_FAKE_CODEX_INPUT_BEFORE_IDENTITY": "1"])
        do {
            fixture.model.startConversation(.codex, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            let id = try #require(fixture.model.selectedSessionID)
            let terminal = try #require(surface(fixture, for: id))
            #expect(await waitUntil { terminal.screenText().contains("BEFORE-IDENTITY") })
            if action == "stop" {
                fixture.model.stopConversation(id)
            } else if action == "quit" {
                #expect((await fixture.runtime.shutdown()).succeeded)
            } else if action == "exit" {
                type("exit", into: terminal)
            } else {
                let serverID = try #require(await fixture.runtime.codexServerState().internalSessionID)
                _ = try await fixture.supervisor.stop(sessionID: serverID)
            }
            #expect(await waitUntil { !fixture.model.isStarting(.codex, projectID: nil) })
            #expect(await waitUntil { fixture.controller.terminalCount == 0 })
            #expect(await waitUntil { await fixture.supervisor.runningSessionIDs().isEmpty })
            #expect(await fixture.runtime.codexServerState().servers == 0)
            #expect(try await fixture.catalog.session(id: id)?.session.providerConversationID == nil)
            if action == "stop" || action == "quit" {
                #expect(fixture.model.errorMessage == nil)
            } else {
                #expect(fixture.model.errorMessage?.contains(action == "exit" ? "exited before" : "connection closed before") == true)
            }
            // Stale terminal input cannot resurrect an ended reservation.
            type("continue", into: terminal)
            #expect(try await fixture.catalog.session(id: id)?.session.providerConversationID == nil)
        } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

}
