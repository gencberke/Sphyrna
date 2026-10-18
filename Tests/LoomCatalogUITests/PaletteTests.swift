import AppKit
import Foundation
@testable import LoomCore
import LoomTerminal
import Testing
@testable import LoomCatalogUI

/// V06: what the command palette ranks, what its actions do, that every keystroke cancels the search before it, that
/// nothing runs while it is closed, that Esc gives the keyboard back, and what the transcript scan reads. A real
/// catalog and event hub; the window tests use an off-screen window.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PaletteTests {
    // MARK: Rig

    @MainActor
    final class RigIntents: ConversationIntents {
        var starts: [(provider: ManagedSession.Provider, projectID: UUID?)] = []
        func start(provider: ManagedSession.Provider, projectID: UUID?) { starts.append((provider, projectID)) }
        func resume(sessionID: UUID) {}
        func stop(sessionID: UUID) {}
        func answer(sessionID: UUID, requestID: String, accept: Bool) {}
        func viewed(sessionID: UUID) {}
        func terminalView(sessionID: UUID) -> NSView? { nil }
        func endedScreen(sessionID: UUID) -> TerminalScreenSnapshot? { nil }
    }

    struct Rig {
        let root: URL
        let hub: SessionEventHub
        let intents: RigIntents
        let model: CatalogModel
        let projectID: UUID
        /// "Token rotation", "Webhook signature check", "Invoice export", "Rate limiter tests", "Nightly import",
        /// in that order (the last is the most recent).
        let ids: [UUID]

        @MainActor func cleanup() {
            model.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private let titles = ["Token rotation", "Webhook signature check", "Invoice export", "Rate limiter tests", "Nightly import"]

    private func makeRig() async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-palette-\(UUID())", isDirectory: true)
        let folder = root.appendingPathComponent("api-gateway", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let projectID = try await catalog.addProject(path: folder.path).project.id
        var ids: [UUID] = []
        for (index, title) in titles.enumerated() {
            let session = ManagedSession(provider: .claude, providerConversationID: "conv-\(index)", workingDirectory: folder.path)
            try await catalog.insertSession(
                session, title: title, createdAt: Date(timeIntervalSince1970: 1_000 + Double(index)),
                lastUsedAt: Date().addingTimeInterval(-Double(5 - index) * 3_600), lifecycle: .idle, projectID: projectID)
            ids.append(session.id)
        }
        let hub = SessionEventHub()
        let intents = RigIntents()
        let model = CatalogModel(catalog: catalog, events: hub,
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        model.intents = intents
        await model.start()
        _ = await waitUntil { model.list(for: .activity).rows.count == ids.count }
        return Rig(root: root, hub: hub, intents: intents, model: model, projectID: projectID, ids: ids)
    }

    private func waitUntil(_ seconds: TimeInterval = 6, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return condition()
    }

    private func needsApproval(_ rig: Rig, _ index: Int, reason: StatusReason?) async {
        await rig.hub.publish(sessionID: rig.ids[index], change: .runStarted(UUID()))
        if let reason { await rig.hub.publish(sessionID: rig.ids[index], change: .reason(reason)) }
        await rig.hub.publish(sessionID: rig.ids[index], change: .status(ProviderWorkState(activity: .waitingForApproval)))
    }

    private func titles(of group: PaletteGroup?) -> [String] { group?.items.map(\.title) ?? [] }

    // MARK: Ranking (pure)

    private func info(_ title: String, project: String? = "api-gateway", age: TimeInterval = 3_600,
                      indicator: SessionIndicator = .ready, reason: String? = nil, now: Date) -> PaletteSessionInfo {
        PaletteSessionInfo(id: UUID(), title: title, project: project, provider: .claude,
                           lastActivityAt: now.addingTimeInterval(-age), indicator: indicator, reason: reason)
    }

    private let sampleActions: [(action: PaletteAction, detail: String?)] = [
        (.newSession, "in api-gateway"), (.home, nil), (.toggleInspector, nil), (.settings, nil), (.findSession, nil),
    ]

    @Test func anEmptyQueryIsTriage() {
        let now = Date()
        let failed = info("Nightly import", age: 600, indicator: .failed("boom"), reason: "boom", now: now)
        let approval = info("Webhook check", age: 7_200, indicator: .waitingForApproval, reason: "allow git push", now: now)
        let unviewed = info("Rate limiter", age: 60, indicator: .unviewedCompletion, now: now)
        let recents = (0..<9).map { info("Session \($0)", age: Double(1_000 + $0 * 100), now: now) }
        let groups = PaletteRanking.groups(query: "  ", sessions: [unviewed] + recents + [approval, failed], projects: [],
                                           actions: sampleActions, now: now)

        #expect(groups.map(\.section) == [.needsYou, .sessions, .actions])
        #expect(groups[0].title == "Needs you" && groups[1].title == "Recent")
        // Failure, then approval, then the unviewed finish; never in the recent list as well.
        #expect(titles(of: groups[0]) == ["Nightly import", "Webhook check", "Rate limiter"])
        #expect(groups[0].items[1].detail == "· allow git push")
        #expect(titles(of: groups[1]) == (0..<PaletteRanking.recentLimit).map { "Session \($0)" })
        #expect(titles(of: groups[2]) == ["New session", "Home", "Toggle Inspector", "Settings…", "Search sessions in the sidebar"])
        #expect(groups[2].items[0].detail == "in api-gateway" && groups[2].items[0].trailing == "⌘N")
        #expect(groups[2].items[1].trailing == "⌃⌘H", "Home shows its menu key: Control, then Command")
    }

    @Test func aQueryRanksTheTitleThenTheProjectThenScatteredLetters() {
        let now = Date()
        let exact = info("Invoice", project: "billing", age: 90_000, now: now)
        let prefix = info("Invoice export", project: "billing", age: 80_000, now: now)
        let word = info("Export invoice", project: "billing", age: 70_000, now: now)
        let inside = info("Reinvoiced items", project: "billing", age: 60_000, now: now)
        let project = info("Payments", project: "invoice-service", age: 50_000, now: now)
        let scattered = info("Insanely voluminous ice", project: "x", age: 40_000, now: now)
        let none = info("Token rotation", now: now)
        let groups = PaletteRanking.groups(
            query: "invoice", sessions: [none, scattered, project, inside, word, prefix, exact], projects: [],
            actions: sampleActions, now: now)

        #expect(groups.map(\.section) == [.sessions])
        #expect(titles(of: groups[0]) == ["Invoice", "Invoice export", "Export invoice", "Reinvoiced items", "Payments", "Insanely voluminous ice"],
                "whole title, start, word start, inside, project name, then the letters of the word found in order; no match drops out")
    }

    @Test func everyWordMustMatchAndCaseAndAccentsDoNotMatter() {
        let now = Date()
        let rows = [info("Güvenlik taraması", project: "api", now: now), info("Webhook tests", project: "api-gateway", now: now)]
        func titles(_ query: String) -> [String] {
            PaletteRanking.groups(query: query, sessions: rows, projects: [], actions: [], now: now)
                .flatMap(\.items).map(\.title)
        }
        #expect(titles("GUVENLIK") == ["Güvenlik taraması"])
        #expect(titles("webhook gateway") == ["Webhook tests"], "a word may match the project")
        #expect(titles("webhook nope").isEmpty, "a word that matches nowhere drops the row")
        #expect(titles("wbk") == ["Webhook tests"], "three scattered letters of a title still match")
        #expect(titles("wb").isEmpty, "two scattered letters do not")
    }

    @Test func needsYouStaysFirstAndAFreshSessionBeatsAnOldOne() {
        let now = Date()
        let old = info("Deploy notes", age: 20 * 86_400, now: now)
        let fresh = info("Deploy checks", age: 60, now: now)
        let waiting = info("Fix flaky deploy", age: 3_600, indicator: .waitingForInput, reason: "waiting for you", now: now)
        let project = PaletteProjectInfo(id: UUID(), name: "deploy-tools", path: "/tmp/deploy-tools")
        let groups = PaletteRanking.groups(query: "deploy", sessions: [old, fresh, waiting], projects: [project],
                                           actions: sampleActions, now: now)

        #expect(groups.first?.section == .needsYou)
        #expect(titles(of: groups.first { $0.section == .sessions }) == ["Deploy checks", "Deploy notes"])
        #expect(groups.contains { $0.section == .projects })
        #expect(!groups.contains { $0.section == .actions }, "no action matches \"deploy\"")
    }

    @Test func aGroupWithTheBestMatchComesFirstAfterNeedsYou() {
        let now = Date()
        let session = info("Something about settings pages", age: 60, now: now)
        let groups = PaletteRanking.groups(query: "settings", sessions: [session], projects: [], actions: sampleActions, now: now)
        #expect(groups.map(\.section) == [.actions, .sessions], "\"Settings…\" is a prefix match; the session only has the word inside")
    }

    // MARK: Reason text

    @Test func theReasonTextSaysWhyASessionNeedsYou() {
        func text(_ reason: StatusReason?, _ indicator: SessionIndicator, open: Bool = false) -> String? {
            PaletteReasonText.line(reason: reason, indicator: indicator, awaitingOpenApproval: open)
        }
        // The sidebar's and Home's words (`SessionReasonLine`), not a second wording of the same reason.
        #expect(text(StatusReason(.approval(tool: "Bash"), detail: "git push"), .waitingForApproval) == "Allow: git push")
        #expect(text(StatusReason(.approval(tool: "Bash")), .waitingForApproval) == "Asks to run a command")
        #expect(text(StatusReason(.approval(tool: "Edit"), detail: "src/a.swift"), .waitingForApproval) == "Allow Edit: src/a.swift")
        #expect(text(StatusReason(.question, detail: "PDF library"), .waitingForApproval) == "Asks: PDF library")
        #expect(text(StatusReason(.planReady), .waitingForApproval) == "Plan ready for review")
        #expect(text(StatusReason(.turnDone, detail: "Added 12 tests"), .unviewedCompletion) == "Added 12 tests")
        #expect(text(StatusReason(.failure(category: "fixture_failure")), .failed(nil)) == "Failed: fixture failure")
        #expect(text(nil, .waitingForApproval) == SessionIndicator.waitingForApproval.label)
        #expect(text(nil, .failed(nil)) == SessionIndicator.failed(nil).label)
        #expect(text(nil, .working) == nil)
        #expect(text(nil, .waitingForApproval, open: true) == "Wants to open a session")
        for (reason, indicator) in [(StatusReason(.approval(tool: "Bash"), detail: "ls"), SessionIndicator.waitingForApproval),
                                    (StatusReason(.failure(category: "x")), .failed(nil))] {
            #expect(text(reason, indicator) == SessionReasonLine(reason)?.text, "palette and sidebar read the same")
        }
    }

    // MARK: The model

    @Test func openingListsWhoNeedsYouWithTheReasonAndRecentSessionsAndTheActions() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let model = rig.model
        await needsApproval(rig, 1, reason: StatusReason(.approval(tool: "Bash"), detail: "git push origin fix"))
        await needsApproval(rig, 2, reason: StatusReason(.question, detail: "PDF library"))
        #expect(await waitUntil { model.attentionCount == 2 })

        model.openPalette()
        #expect(model.palette.isOpen)
        let groups = model.palette.groups
        #expect(groups.map(\.section) == [.needsYou, .sessions, .actions])
        #expect(titles(of: groups[0]) == ["Invoice export", "Webhook signature check"], "same class, so the more recent first")
        let webhook = try #require(groups[0].items.first { $0.title == "Webhook signature check" })
        #expect(webhook.detail == "· Allow: git push origin fix" && webhook.indicator == .waitingForApproval)
        #expect(webhook.trailing?.hasPrefix("api-gateway · ") == true)
        // The rest is recent, most recent first, without the two above.
        #expect(titles(of: groups[1]) == ["Nightly import", "Rate limiter tests", "Token rotation"])
        // New session and Home are there; nothing needs the selected session or the Chat flag, so their actions are not.
        let actions = groups[2].items.compactMap { item -> PaletteAction? in
            if case .action(let action) = item.target { action } else { nil }
        }
        #expect(actions.contains(.newSession) && actions.contains(.home) && actions.contains(.nextAttention))
        #expect(!actions.contains(.toggleInspector) && !actions.contains(.showChat) && !actions.contains(.stopSession))
        #expect(model.palette.selectedID == groups[0].items[0].id, "the first row is selected")
    }

    @Test func arrowsWrapAndReturnOpensTheSelectedSession() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let model = rig.model
        model.openPalette()
        let ids = model.palette.items.map(\.id)
        #expect(ids.count > 3)
        model.palette.move(-1)
        #expect(model.palette.selectedID == ids.last, "up from the first row wraps to the last")
        model.palette.move(1)
        #expect(model.palette.selectedID == ids.first)
        model.palette.move(1)
        #expect(model.palette.selectedID == ids[1])

        model.palette.setQuery("rate limiter")
        #expect(model.palette.selectedID == "session:" + rig.ids[3].uuidString)
        model.palette.activateSelected()
        #expect(!model.palette.isOpen)
        #expect(model.selectedSessionID == rig.ids[3])
        #expect(model.palette.groups.isEmpty && model.palette.query.isEmpty, "closing frees what was found")
    }

    @Test func commandReturnPinsTheSessionInATab() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let model = rig.model
        model.openPalette()
        model.palette.setQuery("nightly")
        model.palette.activateSelected(inTab: true)
        #expect(model.selectedSessionID == rig.ids[4] && model.tabs.isPinned(rig.ids[4]))
    }

    @Test func theActionsDoWhatTheirMenuItemsDo() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let model = rig.model

        func run(_ query: String, expecting action: PaletteAction) {
            model.openPalette()
            model.palette.setQuery(query)
            #expect(model.palette.selectedID == "action:" + action.rawValue, "\"\(query)\" selects \(action)")
            model.palette.activateSelected()
            #expect(!model.palette.isOpen)
        }

        run("home", expecting: .home)
        #expect(model.destination == .home)

        model.showProjectPage(rig.projectID)
        run("new session", expecting: .newSession)
        #expect(model.destination == .draft(projectID: rig.projectID) && rig.intents.starts.isEmpty,
                "New session opens the draft of the project on screen (V07); nothing starts before its first send")

        model.select(rig.ids[0])
        #expect(await waitUntil { model.selectedRow?.id == rig.ids[0] })
        #expect(!model.inspector.isOpen(for: rig.ids[0]))
        run("inspector", expecting: .toggleInspector)
        #expect(model.inspector.isOpen(for: rig.ids[0]))

        run("group by project", expecting: .projectView)
        #expect(model.viewMode == .projects)
        model.openPalette()
        model.palette.setQuery("group by project")
        #expect(model.palette.items.allSatisfy { $0.target != .action(.projectView) }, "already on, so it is not offered")
        model.palette.close()

        // A project page by name.
        model.openPalette()
        model.palette.setQuery("api-gateway")
        let project = try #require(model.palette.items.first { $0.target == .project(rig.projectID) })
        model.palette.activate(project.id)
        #expect(model.destination == .projectPage(rig.projectID))
    }

    @Test func showChatAndTerminalAreOfferedOnlyWhereTheMenuItemsAre() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let model = rig.model
        model.select(rig.ids[0])
        #expect(await waitUntil { model.selectedRow != nil })
        model.readOnlyChatEnabled = false // the kill switch: the faces are not offered
        model.openPalette()
        model.palette.setQuery("show")
        #expect(!model.palette.items.contains { $0.target == .action(.showChat) })
        model.palette.close()

        model.readOnlyChatEnabled = true
        model.openPalette()
        model.palette.setQuery("show chat")
        #expect(model.palette.selectedID == "action:showChat")
        model.palette.activateSelected()
        #expect(model.faces.choice(for: rig.ids[0]) == .chat)
    }

    @Test func commandKClosesAnOpenPalette() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        rig.model.openPalette()
        #expect(rig.model.palette.isOpen)
        ShellCommand.commandPalette.run(on: rig.model)
        #expect(!rig.model.palette.isOpen)
    }

    // MARK: Focus

    @Test func escapeGivesTheKeyboardBackToWhereItWas() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        final class Focusable: NSView { override var acceptsFirstResponder: Bool { true } }
        let terminal = Focusable(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let field = Focusable(frame: NSRect(x: 100, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(terminal)
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(terminal))
        rig.model.palette.windowProvider = { window }

        rig.model.openPalette()
        // The overlay's own field takes the keyboard while open.
        #expect(window.makeFirstResponder(field))
        rig.model.palette.close()
        #expect(window.firstResponder === terminal, "Esc closes and the terminal has the keyboard again")

        // Choosing a row gives it back too, before the place changes.
        rig.model.openPalette()
        #expect(window.makeFirstResponder(field))
        rig.model.palette.setQuery("home")
        rig.model.palette.activateSelected()
        #expect(window.firstResponder === terminal && rig.model.destination == .home)
    }

    // MARK: Closed means idle

    @Test func nothingRunsWhileTheClosedPalette() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let palette = rig.model.palette
        let fake = FakeSources()
        palette.sourcesOverride = fake
        palette.settle = .milliseconds(1)

        palette.setQuery("webhook")
        palette.activateSelected()
        #expect(!palette.isOpen && palette.query.isEmpty && palette.groups.isEmpty && !palette.searchIsRunning)
        try await Task.sleep(for: .milliseconds(50))
        #expect(palette.searchesStarted == 0 && fake.olderCalls == 0 && fake.transcriptCalls == 0)
        #expect(rig.model.selectedSessionID == nil)

        palette.close() // closing a closed palette is a no-op
        #expect(!palette.isOpen)
    }

    @Test func theOpenPaletteReadsNothingUntilAQueryIsTyped() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let palette = rig.model.palette
        let fake = FakeSources()
        palette.sourcesOverride = fake
        palette.settle = .milliseconds(1)
        rig.model.openPalette()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!palette.searchIsRunning && fake.olderCalls == 0 && fake.transcriptCalls == 0, "triage costs no read")
        palette.setQuery("ab")
        #expect(await waitUntil { fake.olderCalls == 1 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(fake.transcriptCalls == 0, "two characters are not searched in conversations")
    }

    // MARK: Cancellation

    /// A search that can be held open: it records when it started and whether it was cancelled, and returns the
    /// hits it was given when it is released.
    @MainActor
    final class FakeSources: PaletteSources {
        private(set) var olderCalls = 0
        private(set) var transcriptCalls = 0
        private(set) var transcriptQueries: [String] = []
        private(set) var cancelledQueries: [String] = []
        var older: [CatalogSession] = []
        var hits: [String: [PaletteTranscriptHit]] = [:]
        var hold = true
        /// A search that fails instead of answering.
        var olderError: (any Error)?
        var transcriptError: (any Error)?
        private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

        func olderSessions(matching query: String) async throws -> [CatalogSession] {
            olderCalls += 1
            if let olderError { throw olderError }
            return older
        }

        func searchTranscripts(query: String, budget: PaletteSearchBudget,
                               progress: @escaping @MainActor (PaletteTranscriptOutcome) -> Void) async throws -> PaletteTranscriptOutcome {
            transcriptCalls += 1
            transcriptQueries.append(query)
            if let transcriptError { throw transcriptError }
            if hold {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { waiters[query] = $0 }
                } onCancel: {
                    Task { @MainActor in
                        self.cancelledQueries.append(query)
                        self.release(query)
                    }
                }
            }
            try Task.checkCancellation()
            var outcome = PaletteTranscriptOutcome(hits: hits[query] ?? [])
            outcome.coverage.filesInWindow = 3
            outcome.coverage.filesSearched = 3
            outcome.coverage.windowDays = budget.days
            return outcome
        }

        func release(_ query: String) {
            waiters.removeValue(forKey: query)?.resume()
        }
    }

    private func hit(_ session: UUID, _ text: String) -> PaletteTranscriptHit {
        PaletteTranscriptHit(sessionID: session, title: "T", project: nil,
                             snippet: PaletteSnippet(role: .you, before: "", match: text, after: ""), timestamp: nil, offset: 1)
    }

    @Test func everyKeystrokeCancelsTheSearchBeforeIt() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let palette = rig.model.palette
        let fake = FakeSources()
        fake.hits["webhook"] = [hit(rig.ids[1], "webhook")]
        fake.hits["web"] = [hit(rig.ids[2], "web")]
        palette.sourcesOverride = fake
        palette.settle = .milliseconds(5)
        rig.model.openPalette()

        palette.setQuery("web")
        #expect(await waitUntil { fake.transcriptCalls == 1 })
        #expect(palette.isSearching)
        palette.setQuery("webhook")
        #expect(await waitUntil { fake.transcriptCalls == 2 })
        #expect(await waitUntil { fake.cancelledQueries == ["web"] }, "the first search was cancelled by the second keystroke")

        // The cancelled one returned nothing the user can see.
        #expect(!palette.items.contains { $0.target == .hit(rig.ids[2]) })
        fake.release("webhook")
        #expect(await waitUntil { !palette.isSearching })
        let found = palette.groups.first { $0.section == .conversations }
        #expect(found?.items.map(\.target).first == .hit(rig.ids[1]))
        #expect(palette.coverageNote == "Searched 3 sessions · last 14 days")
    }

    @Test func aBurstOfKeystrokesStartsOneSearch() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let palette = rig.model.palette
        let fake = FakeSources()
        fake.hold = false
        palette.sourcesOverride = fake
        palette.settle = .milliseconds(60)
        rig.model.openPalette()

        for query in ["r", "ra", "rat", "rate", "rate l", "rate li"] { palette.setQuery(query) }
        #expect(await waitUntil { !palette.isSearching && palette.coverageNote != nil })
        #expect(fake.transcriptQueries == ["rate li"] && fake.olderCalls == 1 && palette.searchesStarted == 1,
                "the five before it were cancelled during the settle and read nothing")
    }

    @Test func closingCancelsTheSearchAndNothingIsShownLater() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let palette = rig.model.palette
        let fake = FakeSources()
        fake.hits["nightly"] = [hit(rig.ids[4], "nightly")]
        palette.sourcesOverride = fake
        palette.settle = .milliseconds(5)
        rig.model.openPalette()
        palette.setQuery("nightly")
        #expect(await waitUntil { fake.transcriptCalls == 1 })
        palette.close()
        #expect(await waitUntil { fake.cancelledQueries == ["nightly"] })
        try await Task.sleep(for: .milliseconds(50))
        #expect(palette.groups.isEmpty && !palette.isSearching && !palette.searchIsRunning && palette.coverageNote == nil)

        // Opening it again starts clean.
        rig.model.openPalette()
        #expect(palette.query.isEmpty && !palette.items.contains { $0.target == .hit(rig.ids[4]) })
    }

    @Test func searchOlderRunsTheWiderPassOnce() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let palette = rig.model.palette
        let fake = FakeSources()
        fake.hold = false
        palette.sourcesOverride = fake
        palette.settle = .milliseconds(5)
        rig.model.openPalette()
        palette.setQuery("invoice")
        #expect(await waitUntil { palette.coverageNote != nil && !palette.isSearching })
        let offer = try #require(palette.items.first { $0.target == .searchOlder })
        #expect(offer.detail == "last 30 days")
        palette.activate(offer.id)
        #expect(palette.isOpen, "the wider pass keeps the palette open")
        #expect(await waitUntil { fake.transcriptCalls == 2 && !palette.isSearching && palette.coverageNote != nil })
        #expect(palette.coverageNote == "No matches in session text · Searched 3 sessions · last 30 days")
        #expect(!palette.items.contains { $0.target == .searchOlder }, "it is offered once")
    }

    struct Broken: Error {}

    @Test func aSearchThatFailsSaysSoInsteadOfLookingLikeNoMatches() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let palette = rig.model.palette
        let fake = FakeSources()
        fake.hold = false
        fake.olderError = Broken()
        palette.sourcesOverride = fake
        palette.settle = .milliseconds(5)
        rig.model.openPalette()
        palette.setQuery("invoice")
        #expect(await waitUntil { fake.transcriptCalls == 1 && !palette.searchIsRunning })
        // The older sessions could not be searched: the footer says that, whatever else was found.
        #expect(palette.searchFailure == "Older sessions could not be searched.")
        #expect(palette.coverageNote == "No matches in session text · Searched 3 sessions · last 14 days",
                "the text search itself went on")

        fake.olderError = nil
        fake.transcriptError = Broken()
        palette.setQuery("invoices")
        #expect(await waitUntil { fake.transcriptCalls == 2 && !palette.searchIsRunning })
        #expect(palette.searchFailure == "Session text could not be searched. What is shown may be incomplete.")
        #expect(palette.coverageNote == nil, "a failed pass has no coverage to print, and it is not \"no matches\"")

        // A new query starts clean, and closing leaves nothing behind.
        fake.transcriptError = nil
        palette.setQuery("webhook")
        #expect(palette.searchFailure == nil)
        #expect(await waitUntil { !palette.searchIsRunning })
        #expect(palette.searchFailure == nil && palette.coverageNote != nil)
        palette.close()
        #expect(palette.searchFailure == nil)
    }

    @Test func aSearchThatTheNextKeystrokeCancelledIsNotReportedAsFailed() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let palette = rig.model.palette
        let fake = FakeSources()
        palette.sourcesOverride = fake
        palette.settle = .milliseconds(5)
        rig.model.openPalette()
        palette.setQuery("web")
        #expect(await waitUntil { fake.transcriptCalls == 1 })
        palette.setQuery("webhook")
        #expect(await waitUntil { fake.cancelledQueries == ["web"] && fake.transcriptCalls == 2 })
        #expect(palette.searchFailure == nil, "the first search ended in a cancellation, not a failure")
        fake.release("webhook")
        #expect(await waitUntil { !palette.isSearching })
        #expect(palette.searchFailure == nil)
    }

    // MARK: Once per open

    /// The Claude profile's `projects` folder with the transcripts of some of the rig's sessions, each in the folder
    /// Claude names after the session's working directory.
    private func transcripts(in rig: Rig, _ files: [(conversation: String, lines: [String])], folder: String? = nil) throws -> URL {
        let projects = rig.root.appendingPathComponent("claude/projects", isDirectory: true)
        let cwd = rig.root.appendingPathComponent("api-gateway").path
        let name = folder ?? String(cwd.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
        let directory = projects.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            try file.lines.joined(separator: "\n").appending("\n")
                .write(to: directory.appendingPathComponent(file.conversation + ".jsonl"), atomically: true, encoding: .utf8)
        }
        return projects
    }

    @Test func aSecondQueryInTheSameOpenLocatesAndReadsTheCatalogForNothingAgain() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let projects = try transcripts(in: rig, [
            ("conv-2", [user("Which PDF library renders the invoice best?"), assistant("WeasyPrint handles CSS page rules well.")]),
            ("conv-3", [user("The limiter drops bursts."), assistant("Use a token bucket for the burst case.")]),
        ])
        let palette = rig.model.palette
        palette.transcriptsDirectory = projects
        palette.settle = .milliseconds(5)
        rig.model.openPalette()

        palette.setQuery("weasyprint")
        #expect(await waitUntil { palette.coverageNote != nil && !palette.isSearching })
        let live = try #require(palette.liveSources)
        #expect(palette.items.contains { $0.target == .hit(rig.ids[2]) })
        let located = live.locateCalls
        #expect(located == 5 && live.candidateReads == 1, "every session of the window was looked for once")

        palette.setQuery("token bucket")
        #expect(await waitUntil { palette.items.contains { $0.target == .hit(rig.ids[3]) } && !palette.isSearching })
        palette.setQuery("css page")
        #expect(await waitUntil { palette.items.contains { $0.target == .hit(rig.ids[2]) } && !palette.isSearching })
        #expect(live.locateCalls == located && live.candidateReads == 1, "the next queries locate nothing and ask the catalog nothing")

        // "Search older" adds only the sessions between 14 and 30 days: none here.
        palette.setQuery("weasyprint")
        #expect(await waitUntil { palette.coverageNote != nil && !palette.isSearching })
        let offer = try #require(palette.items.first { $0.target == .searchOlder })
        palette.activate(offer.id)
        #expect(await waitUntil { palette.coverageNote?.hasSuffix("last 30 days") == true && !palette.isSearching })
        #expect(live.locateCalls == located)

        // Closing forgets it all: the next open looks again.
        palette.close()
        rig.model.openPalette()
        palette.setQuery("weasyprint")
        #expect(await waitUntil { palette.coverageNote != nil && !palette.isSearching })
        #expect(try #require(palette.liveSources).locateCalls == located)
        #expect(try #require(palette.liveSources) !== live)
    }

    @Test func aTranscriptOutsideTheSessionsOwnFolderIsNeverSearchedFor() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        // conv-2's transcript sits in another project's folder: the folder scan that would find it is not made.
        let projects = try transcripts(in: rig, [
            ("conv-2", [user("Which PDF library renders the invoice best?"), assistant("WeasyPrint handles CSS page rules well.")]),
        ], folder: "-tmp-somewhere-else")
        let palette = rig.model.palette
        palette.transcriptsDirectory = projects
        palette.settle = .milliseconds(5)
        rig.model.openPalette()
        palette.setQuery("weasyprint")
        #expect(await waitUntil { palette.coverageNote != nil && !palette.isSearching })
        #expect(!palette.items.contains { $0.target == .hit(rig.ids[2]) })
        #expect(palette.coverageNote == "No matches in session text · Searched 0 sessions · last 14 days")
    }

    @Test func aSessionsFieldsAreFoldedOncePerOpenNotOncePerKeystroke() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let palette = rig.model.palette
        palette.settle = .seconds(30)
        rig.model.openPalette()
        #expect(palette.foldsComputed == 0, "an empty query matches nothing, so folds nothing")
        for query in ["r", "ra", "rat", "rate", "rate l", "rate li", "rate limiter"] { palette.setQuery(query) }
        #expect(palette.foldsComputed == rig.ids.count, "five sessions, folded on the first query and kept")
        #expect(titles(of: palette.groups.first { $0.section == .sessions }).first == "Rate limiter tests")

        // A session whose reason changed is folded again, and only that one.
        await needsApproval(rig, 1, reason: StatusReason(.approval(tool: "Bash"), detail: "git push"))
        #expect(await waitUntil { rig.model.liveStates[rig.ids[1]]?.reason != nil })
        palette.setQuery("rate limite")
        #expect(palette.foldsComputed == rig.ids.count + 1)
        palette.close()
        #expect(palette.foldsComputed == 0, "and nothing is kept once it closes")
    }

    // MARK: What a pass covered

    @Test func aPassOverACutListSaysItLookedAtTheNewestSessionsOnly() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let projects = try transcripts(in: rig, [
            ("conv-4", [user("Nightly import of the ledger"), assistant("The ledger import runs at two.")]),
        ])
        // Five sessions in the catalog, all active in the last 14 days; the source looks at the newest three.
        let capped = LivePaletteSources(model: rig.model, maximumSessions: 3, transcriptsDirectory: { projects })
        let cut = try await capped.searchTranscripts(query: "ledger", budget: .first) { _ in }
        #expect(cut.coverage.sessionCap == 3 && cut.coverage.stop == .completed && !cut.coverage.isComplete)
        let line = PaletteCoverageText.line(cut.coverage, hits: cut.hits.count)
        #expect(line.hasSuffix("last 14 days · newest 3 sessions only"), "\(line)")

        // The same pass over a list the cap did not cut says nothing of the kind.
        let whole = LivePaletteSources(model: rig.model, transcriptsDirectory: { projects })
        let all = try await whole.searchTranscripts(query: "ledger", budget: .first) { _ in }
        #expect(all.coverage.sessionCap == nil && all.coverage.isComplete)
        #expect(!PaletteCoverageText.line(all.coverage, hits: all.hits.count).contains("newest"))
        // A cap that leaves out only sessions older than the window is no cut.
        let exact = LivePaletteSources(model: rig.model, maximumSessions: 5, transcriptsDirectory: { projects })
        #expect(try await exact.searchTranscripts(query: "ledger", budget: .first) { _ in }.coverage.sessionCap == nil)
    }

    // MARK: The scan

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loom-palette-scan-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func user(_ text: String) -> String {
        line(["type": "user", "timestamp": "2026-10-17T10:00:00.000Z", "message": ["role": "user", "content": text]])
    }

    private func assistant(_ text: String) -> String {
        line(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
    }

    private func toolResult(_ text: String) -> String {
        line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": text]]]])
    }

    private func thinking(_ text: String) -> String {
        line(["type": "assistant", "message": ["role": "assistant", "content": [["type": "thinking", "thinking": text]]]])
    }

    private func write(_ lines: [String], to directory: URL, name: String, age: TimeInterval = 60, trailing: String = "\n") throws -> PaletteTranscriptFile {
        let url = directory.appendingPathComponent(name + ".jsonl")
        try (lines.joined(separator: "\n") + trailing).write(to: url, atomically: true, encoding: .utf8)
        let modified = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return PaletteTranscriptFile(sessionID: UUID(), path: url.path, title: name, project: nil, modified: modified)
    }

    @Test func theScanFindsWhatWasSaidAndNotWhatWasRun() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let said = try write([
            user("Please rotate the refresh TOKENS on every use"),
            toolResult("src/auth.py: refresh tokens are issued here"),
            thinking("the user wants refresh tokens rotated"),
            assistant("Refresh tokens are issued in `TokenService._issue()` and \"rotate\" never revokes the old one."),
            line(["type": "user", "isMeta": true, "message": ["role": "user", "content": "refresh tokens meta"]]),
            user("refresh tokens a third time"),
        ], to: dir, name: "said")
        let ran = try write([toolResult("refresh tokens in a tool result only")], to: dir, name: "ran")

        let outcome = PaletteTranscriptScanner.scan(query: "refresh tokens", files: [said, ran], budget: .first, shouldStop: { false })
        #expect(outcome.hits.count == 2, "two hits per session at most, and nothing from tool results, thinking or meta lines")
        #expect(outcome.hits.allSatisfy { $0.sessionID == said.sessionID })
        let first = try #require(outcome.hits.first)
        #expect(first.snippet.role == .you && first.snippet.match == "refresh TOKENS")
        #expect(first.snippet.before == "Please rotate the " && first.snippet.after == " on every use")
        #expect(first.timestamp != nil)
        #expect(outcome.hits[1].snippet.role == .claude)
        #expect(outcome.coverage.filesInWindow == 2 && outcome.coverage.filesSearched == 2 && outcome.coverage.isComplete)

        // A word that fills tool results costs no parse: the lines are turned away before it.
        let busy = try write((0..<50).map { _ in toolResult("refresh tokens refresh tokens") } + [user("refresh tokens in a message")],
                             to: dir, name: "busy")
        let cheap = PaletteTranscriptScanner.scan(query: "refresh tokens", files: [busy], budget: .first, shouldStop: { false })
        #expect(cheap.hits.count == 1 && cheap.coverage.linesDecoded == 1)

        // The same lines written with spaces after the colons (another JSON style) are found too.
        let spaced = try write([user("refresh tokens, spaced out").replacingOccurrences(of: "\":", with: "\": ")], to: dir, name: "spaced")
        let styled = PaletteTranscriptScanner.scan(query: "refresh tokens", files: [spaced], budget: .first, shouldStop: { false })
        #expect(styled.hits.count == 1)

        // A query with a quote and a backslash is looked for as JSON writes it.
        let quoted = PaletteTranscriptScanner.scan(query: "\"rotate\" never", files: [said], budget: .first, shouldStop: { false })
        #expect(quoted.hits.count == 1 && quoted.hits[0].snippet.role == .claude)
        // Too short a query reads nothing.
        let short = PaletteTranscriptScanner.scan(query: "re", files: [said], budget: .first, shouldStop: { false })
        #expect(short.hits.isEmpty && short.coverage.bytesRead == 0)
    }

    @Test func aHalfWrittenLastLineAndAnOversizedLineAreNotRead() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let huge = user(String(repeating: "x", count: PaletteSearchBudget.maxLineBytes + 10) + " needle-in-a-huge-line")
        let file = try write([user("before"), huge, user("a needle here")], to: dir, name: "a", trailing: "\n" + String(user("needle but unfinished").dropLast(3)))
        let outcome = PaletteTranscriptScanner.scan(query: "needle", files: [file], budget: .first, shouldStop: { false })
        #expect(outcome.hits.count == 1 && outcome.hits[0].snippet.before == "a ")
        #expect(outcome.coverage.linesSkipped == 1, "the huge line is counted, not decoded")
    }

    @Test func aLineAcrossManyChunksIsStillFoundWhenItFits() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 3 MiB of filler lines, then a line that straddles a chunk boundary.
        let filler = (0..<30).map { _ in user(String(repeating: "a", count: 100_000)) }
        let straddling = user(String(repeating: "b", count: 90_000) + " straddle " + String(repeating: "c", count: 10))
        let file = try write(filler + [straddling] + filler.prefix(3), to: dir, name: "big")
        let outcome = PaletteTranscriptScanner.scan(query: "straddle", files: [file], budget: .first, shouldStop: { false })
        #expect(outcome.hits.count == 1)
        #expect(outcome.coverage.bytesRead > 3 * PaletteSearchBudget.chunkBytes)
    }

    @Test func theBudgetsBoundTheReadAndTheCoverageSaysSo() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let filler = (0..<20).map { _ in user(String(repeating: "a", count: 100_000)) }
        let files = try (0..<4).map { try write(filler, to: dir, name: "f\($0)", age: Double(60 + $0)) }
        var budget = PaletteSearchBudget.first
        budget.maxBytes = 3 * PaletteSearchBudget.chunkBytes + 1_000

        let bytes = PaletteTranscriptScanner.scan(query: "absent", files: files, budget: budget, shouldStop: { false })
        #expect(bytes.coverage.bytesRead == budget.maxBytes, "never more than the budget")
        #expect(bytes.coverage.stop == .bytes && !bytes.coverage.isComplete && bytes.coverage.filesSearched < 4)
        let note = PaletteCoverageText.line(bytes.coverage, hits: 0)
        #expect(note.contains("stopped at the size limit") && !note.contains("No matches in session text"))

        budget.maxBytes = Int.max
        budget.maxSeconds = 0
        let time = PaletteTranscriptScanner.scan(query: "absent", files: files, budget: budget, shouldStop: { false })
        #expect(time.coverage.stop == .time && time.coverage.bytesRead == 0)

        var hitBudget = PaletteSearchBudget.first
        hitBudget.maxHits = 2
        hitBudget.hitsPerSession = 1
        let said = try (0..<4).map { try write([user("alpha beta gamma")], to: dir, name: "s\($0)", age: Double(60 + $0)) }
        let hits = PaletteTranscriptScanner.scan(query: "beta", files: said, budget: hitBudget, shouldStop: { false })
        #expect(hits.hits.count == 2 && hits.coverage.stop == .hits)
        #expect(hits.hits.map(\.sessionID) == [said[0].sessionID, said[1].sessionID], "newest transcript first")

        let complete = PaletteTranscriptScanner.scan(query: "absent", files: said, budget: .first, shouldStop: { false })
        #expect(PaletteCoverageText.line(complete.coverage, hits: 0).hasPrefix("No matches in session text · Searched 4 sessions"))
    }

    @Test func theScanStopsBetweenChunksWhenCancelled() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let filler = (0..<40).map { _ in user(String(repeating: "a", count: 100_000)) }
        let files = try (0..<3).map { try write(filler, to: dir, name: "f\($0)", age: Double(60 + $0)) }
        var asked = 0
        let outcome = PaletteTranscriptScanner.scan(query: "absent", files: files, budget: .first, shouldStop: {
            asked += 1
            return asked > 4
        })
        #expect(outcome.coverage.stop == .cancelled)
        #expect(outcome.coverage.bytesRead <= 4 * PaletteSearchBudget.chunkBytes, "one chunk at a time, none after the stop")
    }

    @Test func aRunningScanStopsWhenItsTaskIsCancelled() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let filler = (0..<40).map { _ in user(String(repeating: "a", count: 100_000)) }
        let files = try (0..<6).map { try write(filler, to: dir, name: "f\($0)", age: Double(60 + $0)) }
        var budget = PaletteSearchBudget.first
        budget.maxSeconds = 60
        let task = Task.detached(priority: .utility) { () -> PaletteTranscriptOutcome in
            PaletteTranscriptScanner.scan(query: "absent", files: files, budget: budget)
        }
        try await Task.sleep(for: .milliseconds(5))
        task.cancel()
        let outcome = await task.value
        // Cancelled mid-way it read less than everything; if the machine was fast enough to finish, it finished.
        #expect(outcome.coverage.stop == .cancelled ? outcome.coverage.bytesRead < 6 * 4_000_000 : outcome.coverage.isComplete)
    }

    @Test func onlyRecentTranscriptsAreReadAndTheNewestComeFirst() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = try write([user("shared words")], to: dir, name: "old", age: 20 * 86_400)
        let older = try write([user("shared words")], to: dir, name: "older", age: 2 * 86_400)
        let fresh = try write([user("shared words")], to: dir, name: "fresh", age: 60)
        let first = PaletteTranscriptScanner.scan(query: "shared", files: [old, older, fresh], budget: .first, shouldStop: { false })
        #expect(first.hits.map(\.title) == ["fresh", "older"] && first.coverage.filesInWindow == 2 && first.coverage.windowDays == 14)
        let wider = PaletteTranscriptScanner.scan(query: "shared", files: [old, older, fresh], budget: .older, shouldStop: { false })
        #expect(wider.hits.map(\.title) == ["fresh", "older", "old"] && wider.coverage.windowDays == 30)
    }

    @Test func theLiveSourceFindsATranscriptOfACatalogSessionAndOpensIt() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        // A profile whose projects folder holds the transcript of the "Invoice export" session (conv-2).
        let projects = rig.root.appendingPathComponent("claude/projects", isDirectory: true)
        let cwd = rig.root.appendingPathComponent("api-gateway").path
        let folder = projects.appendingPathComponent(String(cwd.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try [user("Which PDF library renders the invoice best?"), assistant("WeasyPrint handles CSS page rules well.")]
            .joined(separator: "\n").appending("\n").write(to: folder.appendingPathComponent("conv-2.jsonl"), atomically: true, encoding: .utf8)

        let palette = rig.model.palette
        palette.transcriptsDirectory = projects
        palette.settle = .milliseconds(5)
        rig.model.openPalette()
        palette.setQuery("weasyprint")
        #expect(await waitUntil { palette.coverageNote != nil && !palette.isSearching })
        let found = try #require(palette.groups.first { $0.section == .conversations }?.items.first)
        #expect(found.target == .hit(rig.ids[2]) && found.title == "Invoice export")
        #expect(found.snippet?.role == .claude && found.snippet?.match == "WeasyPrint")
        #expect(palette.coverageNote == "Searched 1 session · last 14 days")
        palette.activate(found.id)
        #expect(rig.model.selectedSessionID == rig.ids[2] && !palette.isOpen)
    }

    // MARK: Settings → Search session text

    @Test func theSearchSessionTextSwitchIsOnByDefaultPersistsAndReadsOlderFiles() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let model = rig.model
        let store = UIPreferencesStore(url: rig.root.appendingPathComponent("ui-preferences.json"))
        #expect(model.searchesSessionText && model.palette.searchesConversations, "on by default")
        #expect(UIPreferences().searchSessionText)

        model.setSearchesSessionText(false)
        #expect(!model.searchesSessionText && !model.palette.searchesConversations)
        model.flushPreferences()
        #expect(!UIPreferencesStore(url: store.url).current.searchSessionText)
        // A new window starts from what was saved, the palette included.
        let again = CatalogModel(catalog: nil, events: SessionEventHub(), preferences: UIPreferencesStore(url: store.url))
        #expect(!again.searchesSessionText && !again.palette.searchesConversations)
        again.stop()
        model.setSearchesSessionText(true)
        #expect(model.palette.searchesConversations)

        // 0.4.4 and batch 1 files have no key: they read as on. An unreadable value reads as on too.
        let old = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"viewMode": "projects", "sidebarWidth": 340}"#.utf8))
        #expect(old.searchSessionText)
        #expect(try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"searchSessionText": "no"}"#.utf8)).searchSessionText)
        let off = UIPreferences(searchSessionText: false)
        #expect(try JSONDecoder().decode(UIPreferences.self, from: JSONEncoder().encode(off)) == off)
    }

    @Test func withTheSwitchOffThePaletteNeverReadsATranscript() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let palette = rig.model.palette
        palette.settle = .milliseconds(1)

        // The search stage: the source is never asked, however long the query.
        let fake = FakeSources()
        fake.hold = false
        palette.sourcesOverride = fake
        rig.model.setSearchesSessionText(false)
        rig.model.openPalette()
        palette.setQuery("webhook signature")
        #expect(await waitUntil { fake.olderCalls == 1 && !palette.searchIsRunning })
        #expect(fake.transcriptCalls == 0 && !palette.isSearching && palette.coverageNote == nil)
        palette.close()
        rig.model.setSearchesSessionText(true)
        rig.model.openPalette()
        palette.setQuery("webhook signature")
        #expect(await waitUntil { fake.transcriptCalls == 1 }, "the same query reads when the switch is on")
        palette.close()

        // The live source: a transcript that holds the text is found with the switch on and not found with it off.
        let projects = rig.root.appendingPathComponent("claude/projects", isDirectory: true)
        let cwd = rig.root.appendingPathComponent("api-gateway").path
        let folder = projects.appendingPathComponent(String(cwd.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try [user("Which PDF library renders the invoice best?"), assistant("WeasyPrint handles CSS page rules well.")]
            .joined(separator: "\n").appending("\n").write(to: folder.appendingPathComponent("conv-2.jsonl"), atomically: true, encoding: .utf8)
        palette.sourcesOverride = nil
        palette.transcriptsDirectory = projects
        for enabled in [false, true] {
            rig.model.setSearchesSessionText(enabled)
            rig.model.openPalette()
            palette.setQuery("weasyprint")
            #expect(await waitUntil { !palette.searchIsRunning })
            let hits = palette.items.filter { if case .hit = $0.target { true } else { false } }.count
            #expect(hits == (enabled ? 1 : 0), "switch \(enabled ? "on" : "off")")
            #expect((palette.coverageNote != nil) == enabled)
            palette.close()
        }
    }

    @Test func switchingTheSearchOffWhileAScanRunsCancelsItAndDropsItsResult() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let palette = rig.model.palette
        let fake = FakeSources()
        fake.hits["webhook"] = [hit(rig.ids[1], "webhook")]
        palette.sourcesOverride = fake
        palette.settle = .milliseconds(1)
        rig.model.openPalette()
        palette.setQuery("webhook")
        #expect(await waitUntil { fake.transcriptCalls == 1 && palette.isSearching }, "the scan is held open")

        rig.model.setSearchesSessionText(false)
        #expect(await waitUntil { fake.cancelledQueries == ["webhook"] }, "the running scan was cancelled")
        #expect(!palette.isSearching && palette.coverageNote == nil)
        #expect(!palette.items.contains { if case .hit = $0.target { true } else { false } }, "nothing it found is shown")
        // It does not come back by itself, and nothing else reads while the switch is off.
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.transcriptCalls == 1 && !palette.isSearching)
    }

    // MARK: The corpus measurement

    /// `LOOM_PALETTE_CORPUS=<dir of .jsonl files>` (a copy, never the profile itself) and `LOOM_PALETTE_MEASURE=<out.json>`:
    /// scans the directory the way the palette would, warm, and writes the numbers. Off in a normal run.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOOM_PALETTE_CORPUS"] != nil))
    func measureTheScanOnACorpus() throws {
        let environment = ProcessInfo.processInfo.environment
        let corpus = URL(fileURLWithPath: try #require(environment["LOOM_PALETTE_CORPUS"]), isDirectory: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (FileManager.default.enumerator(at: corpus, includingPropertiesForKeys: keys)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "jsonl" }
        let files = urls.map {
            PaletteTranscriptFile(sessionID: UUID(), path: $0.path, title: $0.lastPathComponent, project: nil, modified: Date())
        }
        let total = urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        var budget = PaletteSearchBudget.first
        budget.maxBytes = Int.max
        budget.maxSeconds = 600
        budget.maxHits = Int.max
        budget.hitsPerSession = Int.max
        var rows: [[String: Any]] = []
        for (label, query) in [("absent", "zzqxj-no-such-text"), ("rare", "refresh token"), ("common", "the")] {
            // Warm the page cache once, then time three passes.
            _ = PaletteTranscriptScanner.scan(query: query, files: files, budget: budget, shouldStop: { false })
            var seconds: [Double] = []
            var last = PaletteTranscriptOutcome()
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                last = PaletteTranscriptScanner.scan(query: query, files: files, budget: budget, shouldStop: { false })
                seconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            }
            let best = seconds.min() ?? 0
            rows.append(["query": label, "files": files.count, "bytes": last.coverage.bytesRead, "hits": last.hits.count,
                         "secondsBest": best, "secondsAll": seconds, "mibPerSecond": Double(last.coverage.bytesRead) / 1_048_576 / max(best, 1e-9),
                         "secondsPerGiB": best / (Double(last.coverage.bytesRead) / 1_073_741_824), "linesSkipped": last.coverage.linesSkipped])
        }
        let report: [String: Any] = ["corpusBytes": total, "files": files.count, "runs": rows]
        if let out = environment["LOOM_PALETTE_MEASURE"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
        }
    }
}
