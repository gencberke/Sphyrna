import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
import LoomTerminal
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

@MainActor
private final class AnswerRecorder: ConversationIntents {
    var approved: [UUID] = []
    var denied: [UUID] = []
    var dismissed: [UUID] = []
    func start(provider: ManagedSession.Provider, projectID: UUID?) {}
    func resume(sessionID: UUID) {}
    func stop(sessionID: UUID) {}
    func answer(sessionID: UUID, requestID: String, accept: Bool) {}
    func viewed(sessionID: UUID) {}
    func terminalView(sessionID: UUID) -> NSView? { nil }
    func approveOpen(requestID: UUID) { approved.append(requestID) }
    func denyOpen(requestID: UUID) { denied.append(requestID) }
    func dismissOpen(requestID: UUID) { dismissed.append(requestID) }
}

/// A session opens a session (D-40) at the presentation boundary: what the request box says, how the
/// requester's card reads while the agent waits, what the origin line shows, and the approve path
/// with the real runtime and the fake provider.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct OpenRequestTests {
    // MARK: Box content

    @Test func peerRequestIsDistinctAndFoldsAsSent() {
        let id = UUID(), target = UUID()
        let send = OpenSessionSendRequest(targetSessionID: target, targetTitle: "Reviewer", targetHarness: .codex, operationID: id)
        let request = OpenSessionRequest(id: id, requesterID: UUID(), requesterTitle: "Planner", projectID: UUID(),
            projectName: "", title: "Reviewer", message: "Please review", choices: HarnessLaunchChoices(harness: .codex),
            send: send)
        let content = OpenRequestBoxContent(request)
        #expect(content.heading == "Send to Reviewer?" && content.requester == "from Planner")
        #expect(content.title == "Reviewer" && content.harnessName == "Codex" && content.message == "Please review")
        #expect(content.actions == [.deny, .openSession])
        let starting = OpenSessionRequest(id: id, requesterID: request.requesterID, requesterTitle: "Planner",
            projectID: request.projectID, projectName: "", title: "Reviewer", message: request.message,
            choices: request.choices, send: send, phase: .starting)
        #expect(starting.answeredFold == .sent && OpenRequestBoxContent(starting).status == "Sending…")
        #expect(!OpenRequestFold(id: id, outcome: .sent, title: "Reviewer", requesterID: request.requesterID).showsGoToSession)
    }

    @Test func theBoxStatesTheRequestAndOffersDenyAndOpenSessionOnlyWhileItWaits() {
        let waiting = OpenRequestBoxContent(OpenRequestShared.openRequest(message: "line 1\nline 2"))
        #expect(waiting.heading == "Open a new session?")
        #expect(waiting.requester == "from Planner" && waiting.counter == nil)
        #expect(waiting.title == "EDDP-412 Fix login" && waiting.projectName == "edd-backend")
        #expect(waiting.model == "Default model" && waiting.effort == "Default effort"
                && waiting.mode == "Ask before edits", "a missing choice is Sphyrna's default")
        #expect(waiting.preview == "line 1\nline 2" && !waiting.hasMore)
        #expect(waiting.actions == [.deny, .openSession] && !waiting.actionsDisabled)
        #expect(waiting.status == nil && !waiting.showsSpinner && waiting.failure == nil)

        let starting = OpenRequestBoxContent(OpenRequestShared.openRequest(phase: .starting))
        #expect(starting.status == "Opening…" && starting.showsSpinner && starting.actionsDisabled)
        #expect(starting.actions == [.deny, .openSession])

        let failed = OpenRequestBoxContent(OpenRequestShared.openRequest(phase: .failed("Claude could not be started")))
        #expect(failed.failure == "Claude could not be started" && !failed.showsSpinner)
        #expect(failed.actions == [.dismiss] && !failed.actionsDisabled)
    }

    @Test func theCardReadsAsTheSessionItWillBeWithTheAgentsChoicesOrSphyrnasDefaults() {
        let asked = OpenRequestShared.openRequest(choices: ClaudeLaunchChoices(permissionMode: "plan", model: "opus", effort: "high"))
        let content = OpenRequestBoxContent(asked, position: 1, count: 3)
        #expect(content.counter == "1 of 3", "several requests are one card with a counter, oldest first")
        #expect(content.model == "Opus" && content.effort == "high" && content.mode == "Plan")
        #expect(OpenRequestBoxContent(asked, position: 2, count: 3).counter == "2 of 3")
        #expect(OpenRequestBoxContent(asked, position: 1, count: 1).counter == nil)

        let defaulted = OpenRequestBoxContent(OpenRequestShared.openRequest(choices: ClaudeLaunchChoices(permissionMode: "auto")))
        #expect(defaulted.model == "Default model" && defaulted.effort == "Default effort" && defaulted.mode == "Auto")
        #expect(defaulted.requester == "from Planner")

        let codex = OpenSessionRequest(requesterID: UUID(), projectID: UUID(), projectName: "project", title: "T", message: "go",
                                       choices: HarnessLaunchChoices(harness: .codex, model: "codex-test", effort: "high"))
        let codexContent = OpenRequestBoxContent(codex)
        #expect(codexContent.harnessName == "Codex" && codexContent.provider == .codex)
        #expect(codexContent.model == "codex-test" && codexContent.effort == "high" && codexContent.mode == "Ask before edits")
    }

    @Test func anAnsweredRequestFoldsToOneLineAndADismissedFailureDoesNot() {
        #expect(OpenRequestShared.openRequest(phase: .waiting).answeredFold == .denied)
        #expect(OpenRequestShared.openRequest(phase: .starting).answeredFold == .opened)
        #expect(OpenRequestShared.openRequest(phase: .failed("x")).answeredFold == nil, "dismissing a failure reports nothing")
        let id = UUID()
        let requester = UUID()
        let opened = OpenRequestFold(id: id, outcome: .opened, title: "EDDP-412 Fix login", requesterID: requester)
        #expect(opened.text == "Opened: EDDP-412 Fix login" && opened.showsGoToSession)
        #expect(OpenRequestFold(id: id, outcome: .denied, title: "Nope", requesterID: requester).text == "Denied: Nope")
        #expect(!OpenRequestFold(id: id, outcome: .denied, title: "Nope", requesterID: requester).showsGoToSession)
    }

    @Test func theMessagePreviewIsTheFirstThreeLinesWithTheRestOneClickAway() {
        let six = (1...6).map { "line \($0)" }.joined(separator: "\n")
        let long = OpenRequestBoxContent(OpenRequestShared.openRequest(message: six))
        #expect(long.preview == "line 1\nline 2\nline 3")
        #expect(long.hasMore && long.message == six, "the full message is kept for the scroll area")

        let three = OpenRequestBoxContent(OpenRequestShared.openRequest(message: "a\nb\nc\n\n"))
        #expect(!three.hasMore, "trailing blank lines are not 'more message'")

        let oneLong = OpenRequestBoxContent(OpenRequestShared.openRequest(message: String(repeating: "x", count: 2_000)))
        #expect(oneLong.preview.count == OpenRequestBoxContent.previewCharacterLimit && oneLong.hasMore)
    }

    // MARK: Model

    private func model(catalog: SessionCatalog?, events: SessionEventHub = SessionEventHub(), root: URL) -> CatalogModel {
        CatalogModel(catalog: catalog, events: events,
                     preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-open-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func theBoxButtonsReachTheRuntimeAndAnsweringNeverSelects() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(catalog: nil, root: root)
        let intents = AnswerRecorder()
        model.intents = intents
        let asked = OpenRequestShared.openRequest()
        let failed = OpenRequestShared.openRequest(phase: .failed("Claude could not be started"))
        model.approveOpenRequest(asked.id)
        model.denyOpenRequest(asked.id)
        model.dismissOpenRequest(failed.id)
        #expect(intents.approved == [asked.id] && intents.denied == [asked.id] && intents.dismissed == [failed.id])
        #expect(model.selectedSessionID == nil, "answering never selects anything")

        // Quit started: no new work.
        model.quitting = true
        model.approveOpenRequest(UUID())
        #expect(intents.approved == [asked.id])
    }

    // MARK: Attention

    private struct Rig {
        let root: URL
        let catalog: SessionCatalog
        let hub: SessionEventHub
        let model: CatalogModel
        let project: CatalogProject
        let requester: UUID
        let child: UUID
    }

    /// A project with a requester ("Planner", in /tmp/..a) and a session it opened (in /tmp/..b).
    private func rig(requesterExists: Bool = true) async throws -> Rig {
        let root = try temporaryRoot()
        let folder = root.appendingPathComponent("edd-backend", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let project = try await catalog.addProject(path: folder.path).project
        let requester = ManagedSession(provider: .claude, workingDirectory: "/tmp/loom-origin-a")
        try await catalog.insertSession(requester, title: "Planner", createdAt: Date(timeIntervalSince1970: 100),
                                        lastUsedAt: Date(timeIntervalSince1970: 100), lifecycle: .idle,
                                        projectID: project.id)
        let child = ManagedSession(provider: .claude, workingDirectory: "/tmp/loom-origin-b")
        try await catalog.insertSession(child, title: "EDDP-412 Fix login", createdAt: Date(timeIntervalSince1970: 200),
                                        lastUsedAt: Date(timeIntervalSince1970: 200), lifecycle: .idle,
                                        projectID: project.id,
                                        openedBy: requesterExists ? requester.id : UUID())
        let hub = SessionEventHub()
        return Rig(root: root, catalog: catalog, hub: hub, model: model(catalog: catalog, events: hub, root: root),
                   project: project, requester: requester.id, child: child.id)
    }

    private func waitUntil(_ seconds: TimeInterval = 6, _ condition: () async throws -> Bool) async rethrows -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    @Test func theRequestersCardNeedsApprovalWhileTheAgentWaitsAndIsBackAfterTheAnswer() async throws {
        let rig = try await rig()
        defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        await rig.model.start()
        await rig.hub.publish(sessionID: rig.requester, change: .runStarted(UUID()))
        await rig.hub.publish(sessionID: rig.requester, change: .status(ProviderWorkState(activity: .working)))
        let row = try #require(rig.model.list(for: .activity).rows.first { $0.id == rig.requester })
        #expect(await waitUntil { row.indicator == .working })
        #expect(rig.model.attention(forProject: rig.project.id) == nil)

        var asked = OpenRequestShared.openRequest(requester: rig.requester)
        rig.model.setOpenRequests([asked])
        #expect(row.indicator == .waitingForApproval && row.indicator.label == "Needs approval")
        #expect(rig.model.attention(forProject: rig.project.id) == .attention, "the project dot agrees with the card")
        #expect(rig.model.openRequests(for: rig.requester) == [asked])
        #expect(rig.model.openRequests(for: rig.child).isEmpty)
        // Another session's card is untouched.
        let other = try #require(rig.model.list(for: .activity).rows.first { $0.id == rig.child })
        #expect(other.indicator == .idle)

        // Approved and starting: the user answered, so the card goes back (the new session has its own).
        asked.phase = .starting
        rig.model.setOpenRequests([asked])
        #expect(row.indicator == .working)
        #expect(rig.model.attention(forProject: rig.project.id) == nil)

        // A failed start needs the user again until it is dismissed.
        asked.phase = .failed("Claude could not be started")
        rig.model.setOpenRequests([asked])
        #expect(row.indicator == .waitingForApproval)

        // Denied or dismissed: gone.
        rig.model.setOpenRequests([])
        #expect(row.indicator == .working)
        #expect(rig.model.attention(forProject: rig.project.id) == nil)
    }

    @Test func aRowReadLaterStartsWithTheCurrentApprovalState() async throws {
        let rig = try await rig()
        defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        rig.model.setOpenRequests([OpenRequestShared.openRequest(requester: rig.requester)])
        await rig.model.start()
        await rig.hub.publish(sessionID: rig.requester, change: .runStarted(UUID()))
        let row = try #require(rig.model.list(for: .activity).rows.first { $0.id == rig.requester })
        #expect(await waitUntil { row.live?.runID != nil })
        #expect(row.indicator == .waitingForApproval)
    }

    // MARK: Origin

    @Test func theOriginReplacesTheBranchOnlyWhenBothSessionsAreOnTheSameBranch() {
        let same = SessionOrigin(requesterTitle: "Planner", requesterBranch: .named("main"), ownBranch: .named("main"))
        #expect(same.replacesBranch && same.cardLabel == "from Planner" && same.tooltip == "Opened by Planner")
        let different = SessionOrigin(requesterTitle: "Planner", requesterBranch: .named("main"), ownBranch: .named("fix/login"))
        #expect(!different.replacesBranch && different.tooltip == "Opened by Planner")
        // The requester's branch is not known yet: the card keeps its branch.
        #expect(!SessionOrigin(requesterTitle: "Planner", requesterBranch: nil, ownBranch: .named("main")).replacesBranch)
        // The requester is gone: its branch is unknowable, so the branch stays and the origin is a tooltip.
        let gone = SessionOrigin(requesterTitle: nil, requesterBranch: nil, ownBranch: .named("main"))
        #expect(!gone.replacesBranch && !gone.isKnown)
        #expect(gone.cardLabel == "from another session" && gone.factValue == "Another session")
        #expect(same.factValue == "Planner")
    }

    @Test func aCardReadsItsOriginFromTheRequesterWithoutAskingTheCatalogAgain() async throws {
        let rig = try await rig()
        defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        rig.model.branchReader = { _ in .named("main") }
        await rig.model.start()
        await rig.model.stopAndWait()
        let child = try #require(rig.model.list(for: .activity).rows.first { $0.id == rig.child })
        let requester = try #require(rig.model.list(for: .activity).rows.first { $0.id == rig.requester })
        #expect(requester.record.openedBy == nil && rig.model.origin(of: requester) == nil)

        let origin = try #require(rig.model.origin(of: child))
        #expect(origin.cardLabel == "from Planner" && origin.replacesBranch, "same branch: the origin takes its place")
        #expect(rig.model.openedSession(openedBy: rig.requester, title: "EDDP-412 Fix login") == rig.child,
                "the folded line finds the session the request started")
        #expect(rig.model.openedSession(openedBy: rig.requester, title: "another title") == nil)
        #expect(rig.model.openedSession(openedBy: UUID(), title: "EDDP-412 Fix login") == nil)
        let queries = rig.model.statistics.pageQueries
        for _ in 0..<50 { _ = rig.model.origin(of: child) }
        #expect(rig.model.statistics.pageQueries == queries, "drawing a card never queries the catalog")

        // A rename of the requester shows at once.
        try await rig.model.rename(sessionID: rig.requester, to: "Lead")
        #expect(rig.model.origin(of: child)?.cardLabel == "from Lead")
    }

    @Test func aDifferentBranchKeepsTheBranchAndAMissingRequesterReadsAsAnotherSession() async throws {
        let rig = try await rig()
        defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        rig.model.branchReader = { $0.hasSuffix("a") ? .named("main") : .named("fix/login") }
        await rig.model.start()
        await rig.model.stopAndWait()
        let child = try #require(rig.model.list(for: .activity).rows.first { $0.id == rig.child })
        let origin = try #require(rig.model.origin(of: child))
        #expect(!origin.replacesBranch && origin.tooltip == "Opened by Planner")

        let orphan = try await self.rig(requesterExists: false)
        defer { orphan.model.stop(); try? FileManager.default.removeItem(at: orphan.root) }
        await orphan.model.start()
        await orphan.model.stopAndWait()
        let row = try #require(orphan.model.list(for: .activity).rows.first { $0.id == orphan.child })
        let missing = try #require(orphan.model.origin(of: row))
        #expect(missing.cardLabel == "from another session" && !missing.replacesBranch && missing.factValue == "Another session")
    }

    @Test func theCardNamesItsOriginForVoiceOverAndPlainSessionsNameNone() async throws {
        enableAccessibilityTree()
        let rig = try await rig()
        defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        rig.model.branchReader = { _ in .named("main") }
        await rig.model.start()
        await rig.model.stopAndWait()
        let hosting = NSHostingController(rootView: SidebarView(model: rig.model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 300, height: 600))
        // Never ordered front: the layout runs against a window nobody sees. ARC owns it.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(120))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        let labels = accessibilityElements(in: hosting.view).compactMap { $0.accessibilityLabel?() }
        #expect(labels.contains { $0.hasPrefix("EDDP-412 Fix login, Claude") && $0.contains("opened by Planner") })
        #expect(labels.contains { $0.hasPrefix("Planner, Claude") && !$0.contains("opened by") })
    }

    // MARK: Approve with the real runtime

    private struct Live {
        let root: URL
        let socketDirectory: URL
        let catalog: SessionCatalog
        let runtime: SessionRuntime
        let model: CatalogModel
        let controller: ConversationController
        let project: CatalogProject
        let requester: RuntimeLaunch
        let folder: URL

        @MainActor func cleanup() async {
            controller.stopObserving()
            model.stop()
            _ = await runtime.shutdown()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: socketDirectory)
        }

        /// What `loom-hook open` sends over the control socket.
        func ask(title: String, message: String) async throws -> Task<OpenSessionReply, any Error> {
            let hooks = try #require(await runtime.hookConfiguration)
            let control = try #require(hooks.controlSocketPath)
            let request = OpenSessionWireRequest(
                authenticationToken: hooks.authenticationToken, sessionID: requester.sessionID,
                managedRunID: requester.runID, title: title, project: nil, message: message)
            return Task.detached { try OpenSessionClient.exchange(request, socketPath: control) }
        }
    }

    private func live() async throws -> Live {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-open-live-\(UUID())", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let state = root.appendingPathComponent("fake-state", isDirectory: true)
        let folder = root.appendingPathComponent("project", isDirectory: true)
        for directory in [home, state, folder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let socketDirectory = URL(fileURLWithPath: "/tmp/lo-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let hub = SessionEventHub()
        let binaries = Products.directory
        let supervisor = try await ProcessSupervisor.restoring(
            ledger: OwnershipLedger(), catalog: catalog, events: hub, scopeLauncher: nil)
        let fake = binaries.appendingPathComponent("loom-fake-provider").path
        let runtime = SessionRuntime(
            supervisor: supervisor, catalog: catalog,
            configuration: SessionRuntimeConfiguration(
                toolchains: { provider in
                    return ProviderToolchain(
                        provider: provider, executable: fake,
                        capabilities: ProviderCapabilities(
                            version: "fake", help: "--settings <s> --session-id <i> -n, --name <n> --remote <A> --permission-mode <m>",
                            serverHelp: "--listen <U>"),
                        environment: ["PATH": "/usr/bin:/bin", "HOME": home.path, "LOOM_FAKE_STATE": state.path],
                        profileDirectory: root.appendingPathComponent("profile"))
                },
                hookHelperPath: binaries.appendingPathComponent("loom-hook").path,
                socketDirectory: socketDirectory, homeDirectory: home.path, idlePolicy: SessionIdlePolicy(),
                codexIdentityTimeout: 0.2))
        try await runtime.start()
        let project = try await catalog.addProject(path: folder.path).project
        let model = CatalogModel(catalog: catalog, events: hub,
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("prefs.json")),
                                 startableProviders: [.claude])
        let controller = ConversationController(runtime: runtime, model: model)
        await controller.begin()
        await model.start()
        // The asking session: started by the runtime, not adopted by a controller, so the only
        // terminal this controller ever holds is one an approval created.
        let requester = try await runtime.startConversation(provider: .claude, projectID: project.id)
        return Live(root: root, socketDirectory: socketDirectory, catalog: catalog, runtime: runtime, model: model,
                    controller: controller, project: project, requester: requester, folder: folder)
    }

    @Test func approvingStartsTheSessionAdoptsItsTerminalAndLeavesTheSelectionAlone() async throws {
        let live = try await live()
        do {
            let reply = try await live.ask(title: "EDDP-412 Fix login", message: "Fix it.\nSecond line.")
            // The runtime's list reaches the model through the controller's stream.
            #expect(await waitUntil { live.model.openRequests.count == 1 })
            let request = try #require(live.model.openRequests.first)
            #expect(request.requesterID == live.requester.sessionID && request.phase == .waiting)
            #expect(try await live.catalog.sessions().count == 1, "asking starts nothing")
            #expect(live.model.selectedSessionID == nil)

            live.model.approveOpenRequest(request.id)
            let answer = try await reply.value
            #expect(answer.status == .started)
            let newID = try #require(answer.sessionID)
            // The launch is adopted exactly like a start: a terminal view that the card owns.
            #expect(await waitUntil { live.controller.terminalCount == 1 })
            #expect(await waitUntil { live.model.terminalView(for: newID) != nil })
            #expect(await waitUntil { live.model.openRequests.isEmpty })
            // Opening does not move the user.
            #expect(live.model.selectedSessionID == nil)
            let row = try #require(try await live.catalog.session(id: newID))
            #expect(row.openedBy == live.requester.sessionID)
            #expect(row.title == "EDDP-412 Fix login")
        } catch {
            await live.cleanup()
            throw error
        }
        await live.cleanup()
    }

    @Test func denyStartsNothingAndTheAgentIsToldSo() async throws {
        let live = try await live()
        do {
            let reply = try await live.ask(title: "Nope", message: "no")
            #expect(await waitUntil { live.model.openRequests.count == 1 })
            live.model.denyOpenRequest(try #require(live.model.openRequests.first).id)
            #expect(try await reply.value.status == .denied)
            #expect(await waitUntil { live.model.openRequests.isEmpty })
            #expect(try await live.catalog.sessions().count == 1 && live.controller.terminalCount == 0)
        } catch {
            await live.cleanup()
            throw error
        }
        await live.cleanup()
    }

    @Test func aFailedStartIsShownOnTheRequestAndNeverTriedAgain() async throws {
        let live = try await live()
        do {
            let reply = try await live.ask(title: "Fails", message: "x")
            #expect(await waitUntil { live.model.openRequests.count == 1 })
            let request = try #require(live.model.openRequests.first)
            // The project's folder is gone by the time the user approves: the provider cannot start there.
            try FileManager.default.removeItem(at: live.folder)
            live.model.approveOpenRequest(request.id)
            #expect(try await reply.value.status == .failed)
            #expect(await waitUntil {
                if case .failed = live.model.openRequests.first?.phase { return true }
                return false
            })
            // The failure is on the request's box; no banner, no session, no terminal.
            #expect(live.model.errorMessage == nil)
            #expect(try await live.catalog.sessions().count == 1 && live.controller.terminalCount == 0)
            let sessions = try await live.catalog.sessions().count
            // A stale second click does not start another attempt.
            try FileManager.default.createDirectory(at: live.folder, withIntermediateDirectories: true)
            live.model.approveOpenRequest(request.id)
            try await Task.sleep(for: .milliseconds(400))
            #expect(try await live.catalog.sessions().count == sessions && live.controller.terminalCount == 0)
            if case .failed = live.model.openRequests.first?.phase {} else { Issue.record("the request left the failed state") }
            // The box offers Dismiss, which removes the request.
            #expect(OpenRequestBoxContent(try #require(live.model.openRequests.first)).actions == [.dismiss])
            live.model.dismissOpenRequest(request.id)
            #expect(await waitUntil { live.model.openRequests.isEmpty })
        } catch {
            await live.cleanup()
            throw error
        }
        await live.cleanup()
    }
}
