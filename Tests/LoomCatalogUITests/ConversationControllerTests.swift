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
        extraEnvironment: [String: String] = [:], scoped: Bool = false,
        startableProviders: Set<ManagedSession.Provider> = [.claude, .codex],
        toolchainDelay: Duration = .zero, toolchainFails: Bool = false
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
                    // A slow login-shell capture, or a missing CLI, before anything can start.
                    if toolchainDelay > .zero { try await Task.sleep(for: toolchainDelay) }
                    if toolchainFails { throw SessionRuntimeError.shuttingDown }
                    return ProviderToolchain(
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
            preferences: UIPreferencesStore(url: root.appendingPathComponent("prefs.json")),
            startableProviders: startableProviders
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

    /// Production: Codex has no entry point and the controller refuses it even
    /// when called directly (evidence `start:codex`, a stale button).
    @Test func productionControllerRefusesCodexWithoutSideEffect() async throws {
        let fixture = try await makeFixture(startableProviders: [.claude])
        do {
            fixture.controller.start(provider: .codex, projectID: nil)
            fixture.model.startConversation(.codex, projectID: nil)
            try await Task.sleep(for: .milliseconds(300))
            #expect(fixture.controller.terminalCount == 0)
            #expect(try await fixture.catalog.sessions().isEmpty)
            #expect(!fixture.model.isStarting(.codex, projectID: nil))
            #expect(fixture.model.errorMessage == nil)
            // Claude still starts.
            fixture.model.startConversation(.claude, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            #expect(try await fixture.catalog.sessions().map(\.session.provider) == [.claude])
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    /// OPT2 item 1: a Codex record in the production catalog is not resumed by any path, including a
    /// direct call on the controller (a stale menu, Cmd+R, evidence).
    @Test func productionControllerRefusesToResumeACodexRecord() async throws {
        let fixture = try await makeFixture(startableProviders: [.claude])
        do {
            let codex = ManagedSession(provider: .codex, workingDirectory: fixture.root.path)
            try await fixture.catalog.insertSession(codex, title: "Old Codex", lifecycle: .idle)
            fixture.controller.resume(sessionID: codex.id)
            fixture.model.resumeConversation(codex.id)
            try await Task.sleep(for: .milliseconds(400))
            #expect(fixture.controller.terminalCount == 0)
            #expect(fixture.model.busy[codex.id] == nil)
            #expect(fixture.model.errorMessage == nil)
            #expect(try await fixture.catalog.session(id: codex.id)?.lifecycle == .idle)
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    /// OPT2 item 2: the preparing notice lasts exactly until the launch returns or fails.
    @Test func thePreparingNoticeClearsWhenTheLaunchReturns() async throws {
        let fixture = try await makeFixture(toolchainDelay: .milliseconds(300))
        do {
            fixture.model.startConversation(.claude, projectID: nil)
            #expect(fixture.model.preparingNotice == "Preparing Claude…")
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            #expect(await waitUntil { fixture.model.preparingNotice == nil })
            #expect(!fixture.model.isStarting(.claude, projectID: nil))
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    @Test func thePreparingNoticeClearsWhenTheLaunchFails() async throws {
        let fixture = try await makeFixture(toolchainFails: true)
        do {
            fixture.model.startConversation(.claude, projectID: nil)
            #expect(fixture.model.preparingNotice == "Preparing Claude…")
            #expect(await waitUntil { fixture.model.errorMessage != nil })
            #expect(await waitUntil { fixture.model.preparingNotice == nil })
            #expect(!fixture.model.isStarting(.claude, projectID: nil))
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
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

    // MARK: U5 start busy state

    @Test func newConversationShowsPreparingWhileTheToolchainResolvesAndClearsWhenItReturns() async throws {
        let fixture = try await makeFixture(toolchainDelay: .milliseconds(500))
        do {
            #expect(fixture.model.preparingNotice == nil)
            fixture.model.startConversation(.claude, projectID: nil)
            #expect(fixture.model.preparingNotice == "Preparing Claude…")
            // Still preparing, with no card yet, well into the delay.
            try await Task.sleep(for: .milliseconds(200))
            #expect(fixture.model.preparingNotice == "Preparing Claude…")
            #expect(fixture.controller.terminalCount == 0)
            #expect(fixture.model.selectedSessionID == nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 && fixture.model.selectedSessionID != nil })
            #expect(await waitUntil { fixture.model.preparingNotice == nil })
            #expect(fixture.model.errorMessage == nil)
        } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    @Test func preparingClearsWhenTheToolchainFails() async throws {
        let fixture = try await makeFixture(toolchainDelay: .milliseconds(150), toolchainFails: true)
        do {
            fixture.model.startConversation(.claude, projectID: nil)
            #expect(fixture.model.preparingNotice == "Preparing Claude…")
            #expect(await waitUntil { fixture.model.preparingNotice == nil })
            #expect(await waitUntil { fixture.model.errorMessage != nil })
            #expect(fixture.model.canStart(.claude, projectID: nil))
            #expect(fixture.controller.terminalCount == 0)
        } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    @Test func preparingEndsWhenTheCardAppearsEvenIfTheStartIsStillWaiting() async throws {
        let fixture = try await makeFixture(extraEnvironment: ["LOOM_FAKE_CODEX_INPUT_BEFORE_IDENTITY": "1"])
        do {
            fixture.model.startConversation(.codex, projectID: nil)
            #expect(fixture.model.preparingNotice == "Preparing Codex…")
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            // The card says "Starting…" itself now; the start is still pending.
            #expect(fixture.model.isStarting(.codex, projectID: nil))
            #expect(fixture.model.preparingNotice == nil)
        } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
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

    /// Feedback 1: start, the user's Stop and resume are real use and move the session to the top.
    @Test func startStopAndResumeMoveTheSessionToTheTopOfTheActivityList() async throws {
        try await withFixture { fixture in
            let old = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 2 * 86_400).rounded())
            let neighbor = ManagedSession(provider: .claude, providerConversationID: "n", workingDirectory: fixture.home.path)
            try await fixture.catalog.insertSession(neighbor, title: "Neighbor", createdAt: old, lastUsedAt: old, lifecycle: .idle)
            fixture.model.startConversation(.claude, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            let sessionID = try #require(fixture.model.selectedSessionID)
            func activity() async throws -> Date? { try await fixture.catalog.session(id: sessionID)?.lastActivityAt }
            let started = try #require(try await activity())
            #expect(started > old)

            try await Task.sleep(for: .milliseconds(30))
            fixture.model.stopConversation(sessionID)
            #expect(await waitUntil { fixture.controller.terminalCount == 0 && fixture.model.busy[sessionID] == nil })
            let stopped = try #require(try await waitUntil { try await activity().map { $0 > started } ?? false } ? activity() : nil)
            #expect(stopped > started, "the user's own Stop is activity")
            #expect(await waitUntil { fixture.model.list(for: .activity).rows.first?.id == sessionID })

            try await Task.sleep(for: .milliseconds(30))
            fixture.model.resumeConversation(sessionID)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            #expect(try await waitUntil { try await activity().map { $0 > stopped } ?? false }, "resume is activity")
            #expect(try await fixture.catalog.session(id: neighbor.id)?.lastActivityAt == old)
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

            // A visible, active window makes the selection a view: the use date moves (the stale
            // delay is preserved) but the activity time, the card and the order do not.
            fixture.model.setWindowActive(true)
            #expect(try await waitUntil { try await fixture.catalog.session(id: stale.id)?.lastUsedAt != old })
            #expect(try await fixture.catalog.session(id: stale.id)?.lifecycle == .stale)
            fixture.model.select(idle.id)
            #expect(try await waitUntil { try await fixture.catalog.session(id: idle.id)?.lastUsedAt != old })
            #expect(try await fixture.catalog.session(id: idle.id)?.lifecycle == .idle)
            #expect(try await fixture.catalog.session(id: idle.id)?.lastActivityAt == old)
            #expect(try await fixture.catalog.session(id: stale.id)?.lastActivityAt == old)
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

    /// Feedback 1: clicking an old session must not pull it into "Today" or change its card time.
    @Test func selectingAnOldSessionKeepsItsActivityTimeOrderAndDayHeading() async throws {
        try await withFixture { fixture in
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: Date())
            let old = startOfToday.addingTimeInterval(-5 * 86_400 + 3_600)
            let recent = Date().addingTimeInterval(-3_600)
            let oldSession = ManagedSession(provider: .claude, providerConversationID: "o", workingDirectory: fixture.home.path)
            let recentSession = ManagedSession(provider: .claude, providerConversationID: "r", workingDirectory: fixture.home.path)
            try await fixture.catalog.insertSession(oldSession, title: "Old", createdAt: old, lastUsedAt: old, lifecycle: .idle)
            try await fixture.catalog.insertSession(recentSession, title: "Recent", createdAt: recent, lastUsedAt: recent, lifecycle: .idle)
            await fixture.model.start()
            fixture.model.setWindowActive(true)

            @MainActor func snapshot() -> (ids: [UUID], oldDay: String?) {
                let rows = fixture.model.list(for: .activity).rows
                let sections = DayGrouping.sections(rows, now: fixture.model.now)
                let heading = sections.first { $0.rows.contains { $0.id == oldSession.id } }?.title
                return (rows.map(\.id), heading)
            }
            let before = snapshot()
            #expect(before.ids == [recentSession.id, oldSession.id])
            #expect(before.oldDay != "Today")

            fixture.model.select(oldSession.id)
            let viewed = try await waitUntil { try await fixture.catalog.session(id: oldSession.id)?.lastUsedAt != old }
            #expect(viewed, "the view still moves the use date (retention)")
            fixture.model.scheduleRefresh() // re-reads the lists from the catalog
            try await Task.sleep(for: .milliseconds(500))

            let after = snapshot()
            #expect(after.ids == before.ids)
            #expect(after.oldDay == before.oldDay)
            let row = try #require(fixture.model.list(for: .activity).rows.first { $0.id == oldSession.id })
            #expect(row.record.lastActivityAt == old, "the card reads the activity time, not the view")
            #expect(try await fixture.catalog.session(id: oldSession.id)?.lastActivityAt == old)
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

    // MARK: D-45 an ended run keeps its last screen

    /// Starts a Claude session and ends it with /exit; returns the id and its surface.
    private func startAndExit(_ fixture: Fixture) async throws -> (id: UUID, surface: TerminalSurface) {
        fixture.model.startConversation(.claude, projectID: nil)
        #expect(await waitUntil { fixture.controller.terminalCount == 1 && fixture.model.selectedSessionID != nil })
        let id = try #require(fixture.model.selectedSessionID)
        let terminal = try #require(surface(fixture, for: id))
        #expect(await waitUntil { terminal.screenText().contains("FAKE-CLAUDE READY") })
        type("/exit", into: terminal)
        return (id, terminal)
    }

    @Test func aSelectedSessionKeepsWhatItPrintedLastReadOnlyUntilTheSelectionMovesOn() async throws {
        try await withFixture { fixture in
            let (id, terminal) = try await startAndExit(fixture)
            #expect(await waitUntil { fixture.controller.terminalCount == 0 && fixture.controller.endedScreenCount == 1 })
            // The detail pane falls back to nothing: the live terminal is gone, the ended screen is there.
            #expect(fixture.model.terminalView(for: id) == nil)
            let kept = try #require(fixture.model.endedTerminalView(for: id))
            #expect((kept as? TerminalContainerView)?.terminal === terminal.view)
            #expect(terminal.screenText().contains("bye"), "what the CLI printed before it exited stays")
            #expect(terminal.isKeptReadOnly)

            // Read-only: nothing typed reaches anything and nothing is reported.
            type("hello?", into: terminal)
            terminal.view.send(data: Array("more".utf8)[...])
            try await Task.sleep(for: .milliseconds(150))
            #expect(terminal.statistics.inputErrors.isEmpty && fixture.model.errorMessage == nil)
            #expect(await fixture.supervisor.runningSessionIDs().isEmpty)

            // Resume is an action, never a default: the notice offers it while the session is not running.
            await fixture.model.settle()
            #expect(fixture.model.canResume(try #require(fixture.model.selectedRow)))

            // The user selects another session: a pinned tab keeps its screen, an unpinned one releases it.
            let other = ManagedSession(provider: .claude, providerConversationID: "o", workingDirectory: fixture.home.path)
            try await fixture.catalog.insertSession(other, title: "Other", lifecycle: .idle)
            fixture.model.select(other.id)
            #expect(fixture.model.tabs.isPinned(id) && fixture.controller.endedScreenCount == 1)
            // Back on it and unpinned: it is still the selected session, so the screen stays; moving on frees it.
            fixture.model.select(id)
            fixture.model.unpinTab(id)
            #expect(fixture.controller.endedScreenCount == 1)
            fixture.model.select(other.id)
            #expect(fixture.controller.endedScreenCount == 0)
            #expect(fixture.model.endedTerminalView(for: id) == nil)
        }
    }

    @Test func aSessionThatIsNeitherSelectedNorPinnedReleasesItsScreenAtOnce() async throws {
        try await withFixture { fixture in
            fixture.model.startConversation(.claude, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 && fixture.model.selectedSessionID != nil })
            let id = try #require(fixture.model.selectedSessionID)
            let terminal = try #require(surface(fixture, for: id))
            #expect(await waitUntil { terminal.screenText().contains("FAKE-CLAUDE READY") })
            fixture.model.closeTab(id) // unpinned, and the selection moves to nothing
            #expect(fixture.model.selectedSessionID == nil && !fixture.model.tabs.isPinned(id))
            type("/exit", into: terminal)
            #expect(await waitUntil { fixture.controller.terminalCount == 0 })
            #expect(fixture.controller.endedScreenCount == 0)
            #expect(fixture.model.endedTerminalView(for: id) == nil)
        }
    }

    @Test func aPinnedTabKeepsItsScreenInTheBackgroundUntilTheTabIsClosed() async throws {
        try await withFixture { fixture in
            fixture.model.startConversation(.claude, projectID: nil)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 && fixture.model.selectedSessionID != nil })
            let id = try #require(fixture.model.selectedSessionID)
            let terminal = try #require(surface(fixture, for: id))
            #expect(await waitUntil { terminal.screenText().contains("FAKE-CLAUDE READY") })
            fixture.model.openTab(id)
            fixture.model.select(nil)
            type("/exit", into: terminal)
            #expect(await waitUntil { fixture.controller.terminalCount == 0 })
            #expect(fixture.controller.endedScreenCount == 1, "a pinned tab keeps it though another session is shown")
            fixture.model.closeTab(id)
            #expect(fixture.controller.endedScreenCount == 0)
        }
    }

    @Test func closingTheScreenResumingAndQuittingReleaseIt() async throws {
        try await withFixture { fixture in
            let (id, first) = try await startAndExit(fixture)
            #expect(await waitUntil { fixture.controller.endedScreenCount == 1 })
            // "Show Details".
            fixture.model.closeEndedScreen(id)
            #expect(fixture.controller.endedScreenCount == 0 && fixture.model.endedTerminalView(for: id) == nil)

            // Resume: the new run gets a new surface and the old screen is not kept beside it.
            #expect(try await waitUntil { try await fixture.catalog.session(id: id)?.session.providerConversationID != nil })
            fixture.model.resumeConversation(id)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            let second = try #require(surface(fixture, for: id))
            #expect(second !== first)
            type("/exit", into: second)
            #expect(await waitUntil { fixture.controller.endedScreenCount == 1 && fixture.controller.terminalCount == 0 })
            fixture.model.resumeConversation(id)
            #expect(await waitUntil { fixture.controller.terminalCount == 1 })
            #expect(fixture.controller.endedScreenCount == 0, "a resumed session's old screen is replaced")

            // Quit releases every kept screen.
            let third = try #require(surface(fixture, for: id))
            type("/exit", into: third)
            #expect(await waitUntil { fixture.controller.endedScreenCount == 1 })
            fixture.controller.quitStarted()
            #expect(fixture.controller.endedScreenCount == 0)
        }
    }

    @Test func atMostEightEndedScreensAreKeptAndTheSelectedOneIsNeverTheVictim() async throws {
        try await withFixture { fixture in
            // Surfaces that never ran a process: only the keeping rules are under test.
            @MainActor func keep(_ owner: UUID) {
                let surface = TerminalSurface()
                fixture.controller.keepEndedScreen(ConversationController.Entry(
                    runID: UUID(), surface: surface, container: TerminalContainerView(terminal: surface.view),
                    owner: owner))
            }
            // The oldest screen belongs to the selected session.
            let selected = ManagedSession(provider: .claude, providerConversationID: "s", workingDirectory: fixture.home.path)
            try await fixture.catalog.insertSession(selected, title: "Selected", lifecycle: .idle)
            fixture.model.select(selected.id)
            await fixture.model.settle()
            keep(selected.id)
            let others = (0..<9).map { _ in UUID() }
            for owner in others.prefix(7) { keep(owner) }
            #expect(fixture.controller.endedScreenCount == 8)
            keep(others[7])
            #expect(fixture.controller.endedScreenCount == 8)
            #expect(fixture.controller.ended[selected.id] != nil, "the selected session's screen stays though it is the oldest")
            #expect(fixture.controller.ended[others[0]] == nil, "the oldest screen that is not selected went")
            keep(others[8])
            #expect(fixture.controller.endedScreenCount == 8)
            #expect(Set(fixture.controller.ended.keys) == Set([selected.id] + others.suffix(7)))
        }
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
            let errorBeforeTyping = fixture.model.errorMessage
            if action == "stop" || action == "quit" {
                #expect(errorBeforeTyping == nil)
            } else {
                #expect(errorBeforeTyping?.contains(action == "exit" ? "exited before" : "connection closed before") == true)
            }
            // The ended run's last screen stays on show while its session is selected (D-45): the live
            // terminal count is zero, the same surface is kept read-only.
            #expect(fixture.controller.endedScreenCount == 1)
            #expect(fixture.model.terminalView(for: id) == nil)
            #expect(fixture.model.endedTerminalView(for: id) === terminal.view.superview)
            #expect(terminal.screenText().contains("BEFORE-IDENTITY"))
            // Stale terminal input cannot resurrect an ended reservation, and says nothing either.
            type("continue", into: terminal)
            #expect(try await fixture.catalog.session(id: id)?.session.providerConversationID == nil)
            #expect(fixture.model.errorMessage == errorBeforeTyping)
            #expect(terminal.statistics.inputErrors.isEmpty)
        } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

}
