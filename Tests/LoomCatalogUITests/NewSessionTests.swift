import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// V07: the draft session. Drafts are stored and reused, the defaults follow one order, and the first send hands the runtime what the draft shows. Everything
/// lives in temporary folders that each test removes; no process starts.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct NewSessionTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-newsession-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return condition()
    }

    /// The runtime's side of a draft send: records what was asked and lets the test answer.
    @MainActor
    final class DraftIntents: NewSessionIntents {
        var sends: [(projectID: UUID?, launch: NewSessionLaunch, focus: NewSessionFocus, outcome: @MainActor (NewSessionOutcome) -> Void)] = []
        var plainStarts = 0
        func start(provider: ManagedSession.Provider, projectID: UUID?) { plainStarts += 1 }
        func resume(sessionID: UUID) {}
        func stop(sessionID: UUID) {}
        func answer(sessionID: UUID, requestID: String, accept: Bool) {}
        func viewed(sessionID: UUID) {}
        func terminalView(sessionID: UUID) -> NSView? { nil }
        func startSession(projectID: UUID?, launch: NewSessionLaunch, focus: NewSessionFocus,
                          outcome: @escaping @MainActor (NewSessionOutcome) -> Void) {
            sends.append((projectID, launch, focus, outcome))
        }
    }

    private struct Rig {
        let root: URL
        let model: CatalogModel
        let intents: DraftIntents
        let catalog: SessionCatalog
        let projectID: UUID
        let otherProjectID: UUID
        var storeURL: URL { root.appendingPathComponent("new-session.json") }
    }

    private func rig(root: URL) async throws -> Rig {
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var ids: [UUID] = []
        for name in ["api", "billing"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            ids.append(try await catalog.addProject(path: folder.path).project.id)
        }
        let hub = SessionEventHub()
        let intents = DraftIntents()
        let model = CatalogModel(
            catalog: catalog, events: hub, preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        model.intents = intents
        await model.start()
        return Rig(root: root, model: model, intents: intents, catalog: catalog, projectID: ids[0], otherProjectID: ids[1])
    }

    /// Opens the draft like the window does, waits for the strip's branch read and then says the folder is on
    /// `main` (the temporary folders have no repository).
    private func openDraft(_ model: CatalogModel, _ projectID: UUID, branch: GitBranch? = .named("main")) async {
        model.showDraft(projectID: projectID)
        _ = await waitUntil { model.newSession.branch(for: projectID) != nil }
        if let branch { model.newSession.setBranch(branch, for: projectID) }
    }

    // MARK: Draft storage and reuse

    @Test func anEmptyDraftIsInvisibleReusedAndCostsNoWrite() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }

        model.beginNewSession(projectID: rig.projectID)
        #expect(model.destination == .draft(projectID: rig.projectID))
        #expect(model.newSession.draft(for: rig.projectID) != nil && model.newSession.visibleDrafts.isEmpty)
        // Opening it again, picking things in it and leaving it all reuse the one slot.
        model.beginNewSession(projectID: rig.projectID)
        model.setDraftMode(.value("plan"), projectID: rig.projectID)
        model.setDraftBranch(.newWorktree, projectID: rig.projectID)
        model.showHome()
        model.beginNewSession(projectID: rig.projectID)
        #expect(model.newSession.drafts.count == 1)
        #expect(model.newSession.draft(for: rig.projectID)?.modePick == .value("plan"), "the pick of the draft survives leaving it")
        #expect(model.visibleDrafts.isEmpty)
        model.newSession.flush()
        #expect(!FileManager.default.fileExists(atPath: rig.storeURL.path), "an empty draft is never written")

        // Typing makes it visible, in its project only.
        model.setDraftText("  fix the flaky test\nsecond line ", projectID: rig.projectID)
        model.beginNewSession(projectID: rig.otherProjectID)
        #expect(model.newSession.drafts.count == 2)
        #expect(model.visibleDrafts.map(\.projectID) == [rig.projectID])
        #expect(model.newSession.draft(for: rig.otherProjectID)?.isVisible == false)
        // The draft with text is what its project shows.
        model.showDraft(projectID: rig.projectID)
        #expect(model.newSession.draft(for: rig.projectID)?.trimmedText == "fix the flaky test\nsecond line")
        #expect(model.newSession.drafts.count == 2)
    }

    @Test func aDraftWithTextIsSavedOnceAfterQuietAndComesBackAfterARelaunch() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.beginNewSession(projectID: rig.projectID)
        let store = try #require(model.newSession.store)
        store.delay = .milliseconds(60)
        model.setDraftBranch(.newBranch, name: "feat/mine", projectID: rig.projectID)
        model.setDraftMode(.value("auto"), projectID: rig.projectID)
        #expect(store.writeCount == 0, "picks on an empty draft are not saved")

        for letter in ["f", "fi", "fix", "fix it"] { model.setDraftText(letter, projectID: rig.projectID) }
        #expect(store.writeCount == 0, "typing writes nothing until it pauses")
        #expect(await waitUntil { store.writeCount == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.writeCount == 1, "one write for the whole burst, none without a change")

        // A relaunch: a new model over the same data root reads the draft back, with its picks.
        let again = CatalogModel(
            catalog: rig.catalog, events: SessionEventHub(),
            preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        defer { again.stop() }
        again.prepareNewSession()
        let restored = try #require(again.newSession.visibleDrafts.first)
        #expect(restored.projectID == rig.projectID && restored.text == "fix it")
        #expect(restored.branchKind == .newBranch && restored.branchName == "feat/mine" && restored.modePick == .value("auto"))

        // Clearing the text makes it invisible again and the file forgets it.
        model.setDraftText("   ", projectID: rig.projectID)
        model.newSession.flush()
        #expect(model.visibleDrafts.isEmpty)
        let later = NewSessionStore(url: rig.storeURL)
        #expect(later.file.drafts.isEmpty)
    }

    @Test func discardEmptiesTheSlotAndMovingCarriesTextToAnEmptyProjectOnly() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.showDraft(projectID: rig.projectID)
        model.setDraftText("write the migration", projectID: rig.projectID)
        model.setDraftMode(.value("acceptEdits"), projectID: rig.projectID)

        // Picking another project in the question: the empty slot takes the draft.
        model.chooseDraftProject(rig.otherProjectID, from: rig.projectID)
        #expect(model.destination == .draft(projectID: rig.otherProjectID))
        let moved = try #require(model.newSession.draft(for: rig.otherProjectID))
        #expect(moved.text == "write the migration" && moved.modePick == .value("acceptEdits"))
        #expect(model.newSession.draft(for: rig.projectID)?.isVisible == false)

        // A project whose slot has text keeps it; the other draft is shown as it is.
        model.setDraftText("other words", projectID: rig.projectID)
        model.chooseDraftProject(rig.projectID, from: rig.otherProjectID)
        #expect(model.newSession.draft(for: rig.projectID)?.text == "other words")
        #expect(model.newSession.draft(for: rig.otherProjectID)?.text == "write the migration")

        model.discardDraft(projectID: rig.projectID)
        #expect(model.newSession.draft(for: rig.projectID)?.isVisible == false)
        #expect(model.visibleDrafts.map(\.projectID) == [rig.otherProjectID])
        // A draft of a project that was removed is not listed.
        model.newSession.update(UUID()) { $0.text = "orphan" }
        #expect(model.newSession.visibleDrafts.count == 2 && model.visibleDrafts.count == 1)
    }

    // MARK: Several drafts per project: the file

    private func writeDrafts(_ drafts: [SessionDraft], to url: URL) {
        let store = NewSessionStore(url: url)
        store.change { $0.drafts = drafts.map(StoredDraft.init) }
        store.flush()
    }

    @Test func aFileFromBeforeDraftIDsLoadsEveryDraftWithAnIDOfItsOwn() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("new-session.json")
        let api = UUID(), billing = UUID()
        writeDrafts([SessionDraft(projectID: api, text: "api work"), SessionDraft(projectID: billing, text: "billing work"),
                     SessionDraft(projectID: nil, text: "loose idea")], to: url)
        // The file as 1.6.0 wrote it: one draft per project and no ids.
        var file = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var drafts = try #require(file["drafts"] as? [[String: Any]])
        #expect(drafts.allSatisfy { $0["id"] != nil }, "a write carries each draft's id")
        for index in drafts.indices { drafts[index]["id"] = nil }
        file["drafts"] = drafts
        try JSONSerialization.data(withJSONObject: file).write(to: url)

        let store = NewSessionStore(url: url)
        let ids = store.file.drafts.compactMap(\.id)
        #expect(ids.count == 3 && Set(ids).count == 3, "each old draft gets an id of its own")
        let state = NewSessionState()
        state.attach(store: store)
        #expect(state.draft(for: api)?.text == "api work" && state.draft(for: billing)?.text == "billing work")
        #expect(state.draft(for: nil)?.text == "loose idea")
        #expect(Set(state.visibleDrafts.map(\.id)) == Set(ids))
    }

    @Test func twoDraftsOfOneProjectInTheFileAreBothKeptAndTheNewestIsShown() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("new-session.json")
        let project = UUID()
        let older = SessionDraft(projectID: project, text: "older idea", updatedAt: Date(timeIntervalSince1970: 1_000))
        let newer = SessionDraft(projectID: project, text: "newer idea", updatedAt: Date(timeIntervalSince1970: 2_000))
        // Oldest first on purpose: the order read does not decide which is shown.
        writeDrafts([older, newer], to: url)
        let state = NewSessionState()
        state.attach(store: NewSessionStore(url: url))
        #expect(state.visibleDrafts.map(\.text) == ["newer idea", "older idea"], "neither draft is dropped")
        #expect(state.draft(for: project)?.id == newer.id, "the project shows its newest draft")
        #expect(state.draft(id: older.id)?.text == "older idea")
    }

    @Test func theFileListsTheNewestDraftFirstSoABuildThatKeepsOnePerProjectKeepsTheLatest() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("new-session.json")
        let project = UUID()
        let older = SessionDraft(projectID: project, text: "older idea", updatedAt: Date(timeIntervalSince1970: 1_000))
        let newer = SessionDraft(projectID: project, text: "newer idea", updatedAt: Date(timeIntervalSince1970: 2_000))
        writeDrafts([newer, older], to: url)
        let state = NewSessionState()
        state.clock = { Date(timeIntervalSince1970: 3_000) }
        let store = NewSessionStore(url: url)
        state.attach(store: store)
        // The older draft is edited: it is now the newest, and the file puts it first.
        state.show(id: older.id)
        state.setText("older idea, edited", for: project)
        state.flush()
        let written = NewSessionStore(url: url).file.drafts
        #expect(written.map(\.id) == [older.id, newer.id])
        // 1.6.0 keeps the first draft of each project in the file.
        var firstPerProject: [UUID?: String] = [:]
        for draft in written where firstPerProject[draft.projectID] == nil { firstPerProject[draft.projectID] = draft.text }
        #expect(firstPerProject[project] == "older idea, edited")
    }

    // MARK: Several drafts per project: the window

    @Test func newSessionOpensAnEmptyDraftAndReusesTheEmptyOneAProjectHas() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.beginNewSession(projectID: rig.projectID)
        model.setDraftText("first idea", projectID: rig.projectID)
        let first = try #require(model.newSession.currentID(for: rig.projectID))
        model.showHome()

        model.beginNewSession(projectID: rig.projectID)
        #expect(model.destination == .draft(projectID: rig.projectID))
        let empty = try #require(model.newSession.draft(for: rig.projectID))
        #expect(empty.id != first && !empty.isVisible, "New Session opens an empty draft, not the one with text")
        #expect(model.visibleDrafts.map(\.id) == [first], "the draft with text stays listed")
        model.showHome()
        model.beginNewSession(projectID: rig.projectID)
        #expect(model.newSession.currentID(for: rig.projectID) == empty.id && model.newSession.drafts.count == 2,
                "the project's empty draft is reused")
        // From the draft with text, New Session again shows an empty draft, and empty drafts do not pile up.
        model.showDraft(id: first)
        model.beginNewSession(projectID: rig.projectID)
        #expect(model.newSession.draft(for: rig.projectID)?.isVisible == false && model.newSession.drafts.count == 2)
    }

    @Test func theDraftAProjectShowsIsRememberedWhenTheWindowLeavesAndComesBack() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.beginNewSession(projectID: rig.projectID)
        model.setDraftText("older idea", projectID: rig.projectID)
        let older = try #require(model.newSession.draft(for: rig.projectID))
        model.beginNewSession(projectID: rig.projectID)
        model.setDraftText("newer idea", projectID: rig.projectID)

        model.showDraft(id: older.id)
        #expect(model.destination == .draft(projectID: rig.projectID) && model.isShownDraft(older))
        model.showHome()
        #expect(!model.isShownDraft(older))
        model.showDraft(projectID: rig.projectID)
        #expect(model.newSession.currentID(for: rig.projectID) == older.id)
        #expect(model.newSession.draft(for: rig.projectID)?.text == "older idea")
    }

    @Test func sendingADraftRemovesThatDraftOnlyAndDiscardTakesOneDraft() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        var now = Date(timeIntervalSince1970: 1_000)
        model.newSession.clock = { now }
        await openDraft(model, rig.projectID)
        var ids: [UUID] = []
        for text in ["keep this", "drop this", "send this"] {
            model.beginNewSession(projectID: rig.projectID)
            model.setDraftText(text, projectID: rig.projectID)
            ids.append(try #require(model.newSession.currentID(for: rig.projectID)))
            now += 60
        }
        let (kept, dropped, sent) = (ids[0], ids[1], ids[2])

        // Discard takes one draft; one that is not on screen goes without touching the page.
        model.discardDraft(id: dropped)
        #expect(model.visibleDrafts.map(\.id) == [sent, kept] && model.newSession.currentID(for: rig.projectID) == sent)

        model.sendDraft(projectID: rig.projectID)
        #expect(await waitUntil { rig.intents.sends.count == 1 })
        #expect(rig.intents.sends.first?.launch.firstMessage == "send this")
        rig.intents.sends.first?.outcome(.started(UUID()))
        #expect(model.newSession.draft(id: sent) == nil, "the sent draft is gone")
        #expect(model.visibleDrafts.map(\.id) == [kept], "the project's other draft stays")

        model.discardDraft(id: kept)
        #expect(model.visibleDrafts.isEmpty && model.newSession.draft(for: rig.projectID)?.isVisible == false)
    }

    // MARK: Defaults

    @Test func theDefaultsFollowThePickThenTheFixedModeThenLastUsedThenTheCli() {
        let last = ClaudeLaunchChoices(permissionMode: "acceptEdits", model: "sonnet")
        let settings = NewSessionSettings(permissionMode: "auto", model: "haiku")
        func resolve(_ mode: DraftPick = .inherit, _ model: DraftPick = .inherit, last: ClaudeLaunchChoices? = nil,
                     settings: NewSessionSettings = NewSessionSettings()) -> ResolvedStart {
            NewSessionDefaults.resolve(modePick: mode, modelPick: model, lastUsed: last, settings: settings)
        }
        // 4: nothing says anything: the mode is Ask before edits, passed explicitly (D-63); the model and the effort are left to the CLI.
        let none = resolve()
        #expect(none.mode == ResolvedChoice(value: "default", source: .loomDefault))
        #expect(none.model == ResolvedChoice(value: nil, source: .cliDefault) && none.effort == ResolvedChoice(value: nil, source: .cliDefault))
        #expect(none.choices == ClaudeLaunchChoices(permissionMode: "default") && none.modeTitle == "Ask before edits")
        #expect(none.modelTitle(in: ModelCatalog()) == "Default model" && none.effortTitle == nil)
        // 3: what was last used in the project, which is what "Last used in the project" in Settings means (no mode stored).
        let remembered = resolve(last: last, settings: NewSessionSettings(model: "haiku"))
        #expect(remembered.mode == ResolvedChoice(value: "acceptEdits", source: .lastUsed))
        #expect(remembered.model == ResolvedChoice(value: "sonnet", source: .lastUsed), "the model's last used beats its setting")
        #expect(remembered.modeTitle == "Accept edits" && remembered.modelTitle(in: ModelCatalog()) == "Sonnet")
        #expect(resolve(settings: settings).model == ResolvedChoice(value: "haiku", source: .settings))
        // 2: the one mode the user fixed in Settings beats the project's last used mode (D-69).
        let fixed = resolve(last: last, settings: settings)
        #expect(fixed.mode == ResolvedChoice(value: "auto", source: .settings))
        #expect(resolve(settings: settings).mode == ResolvedChoice(value: "auto", source: .settings))
        // 1: a pick beats everything, and choosing the model's own default on purpose is a pick too.
        let picked = resolve(.value("ask"), .value("opus"), last: last, settings: settings)
        #expect(picked.mode == ResolvedChoice(value: "ask", source: .pick) && picked.model == ResolvedChoice(value: "opus", source: .pick))
        let explicit = resolve(.claudeDefault, .claudeDefault, last: last, settings: settings)
        #expect(explicit.model == ResolvedChoice(value: nil, source: .pick), "the model's default is a pick")
        #expect(explicit.mode == ResolvedChoice(value: "auto", source: .settings), "the mode has no such pick: an old one reads as nothing")
        // Each chip follows its own levels.
        let mixed = resolve(.value("ask"), last: last)
        #expect(mixed.mode.source == .pick && mixed.model == ResolvedChoice(value: "sonnet", source: .lastUsed))
    }

    @Test func loomNeverPicksFullAccessByItself() {
        let full = ClaudePermissionMode.fullAccess.rawValue
        let last = ClaudeLaunchChoices(permissionMode: full)
        // A remembered Full access is skipped: the next level answers.
        #expect(NewSessionDefaults.resolve(modePick: .inherit, modelPick: .inherit, lastUsed: last,
                                           settings: NewSessionSettings(permissionMode: "auto")).mode
            == ResolvedChoice(value: "auto", source: .settings))
        #expect(NewSessionDefaults.resolve(modePick: .inherit, modelPick: .inherit, lastUsed: last,
                                           settings: NewSessionSettings()).mode
            == ResolvedChoice(value: "default", source: .loomDefault))
        // The mode the user fixed in Settings may be Full access (D-69): the user picked it there.
        #expect(NewSessionDefaults.resolve(modePick: .inherit, modelPick: .inherit, lastUsed: nil,
                                           settings: NewSessionSettings(permissionMode: full)).mode
            == ResolvedChoice(value: full, source: .settings))
        // Only a pick in this draft carries it, and it looks like every other mode.
        let picked = NewSessionDefaults.resolve(modePick: .value(full), modelPick: .inherit, lastUsed: nil, settings: NewSessionSettings())
        #expect(picked.mode == ResolvedChoice(value: full, source: .pick) && picked.modeTitle == "Full access")
        // A value that could be taken for an option never resolves.
        #expect(NewSessionDefaults.resolve(modePick: .value("--x"), modelPick: .inherit, lastUsed: nil, settings: NewSessionSettings())
            .mode == ResolvedChoice(value: "default", source: .loomDefault))
    }

    /// Review B1: Ask is a Chat mode. Where the session starts in the terminal, a picked, remembered or configured Ask becomes
    /// Ask before edits for that start; where it starts in Chat, Ask stays.
    @Test func askFallsBackToAskBeforeEditsWhereTheSessionStartsInTheTerminal() {
        let remembered = ClaudeLaunchChoices(permissionMode: "ask", model: "opus")
        func resolve(_ pick: DraftPick = .inherit, last: ClaudeLaunchChoices? = nil, settings: NewSessionSettings = NewSessionSettings(),
                     askAllowed: Bool) -> ResolvedStart {
            NewSessionDefaults.resolve(modePick: pick, modelPick: .inherit, lastUsed: last, settings: settings, askAllowed: askAllowed)
        }
        #expect(resolve(.value("ask"), askAllowed: true).mode == ResolvedChoice(value: "ask", source: .pick))
        #expect(resolve(.value("ask"), askAllowed: false).mode == ResolvedChoice(value: "default", source: .pick))
        #expect(resolve(last: remembered, askAllowed: true).mode == ResolvedChoice(value: "ask", source: .lastUsed))
        #expect(resolve(last: remembered, askAllowed: false).mode == ResolvedChoice(value: "default", source: .lastUsed))
        #expect(resolve(settings: NewSessionSettings(permissionMode: "ask"), askAllowed: false).mode
            == ResolvedChoice(value: "default", source: .settings))
        // Every other mode is the same in both faces, and the launch choices carry the fallback.
        #expect(resolve(.value("acceptEdits"), askAllowed: false).mode == ResolvedChoice(value: "acceptEdits", source: .pick))
        #expect(resolve(last: remembered, askAllowed: false).choices.permissionMode == "default")
    }

    /// The start face for the mode menu is one question (`newSessionStartsInChat`), Settings → "Sessions run in".
    @Test func theDraftsModeListFollowsTheFaceTheSessionStartsIn() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.beginNewSession(projectID: rig.projectID)
        model.setDraftMode(.value("ask"), projectID: rig.projectID)
        model.setNewSessionFace(.terminal)
        #expect(!model.newSessionStartsInChat && !model.newSessionAllowsAsk)
        #expect(model.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "default", source: .pick))
        model.setNewSessionFace(.chat)
        #expect(model.newSessionStartsInChat && model.newSessionAllowsAsk)
        #expect(model.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "ask", source: .pick))
    }

    @Test func whatWasLastUsedInAProjectIsRememberedPerProjectAndAcrossRelaunches() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.showDraft(projectID: rig.projectID)
        model.setDraftMode(.value("acceptEdits"), projectID: rig.projectID)
        model.setDraftModel(.value("opus"), projectID: rig.projectID)
        model.setDraftEffort(.value("high"), projectID: rig.projectID)
        model.setDraftText("go", projectID: rig.projectID)
        model.sendDraft(projectID: rig.projectID)
        #expect(await waitUntil { !rig.intents.sends.isEmpty })
        rig.intents.sends[0].outcome(.started(UUID()))

        // The next draft of that project starts from it, wherever it is opened from; another project does not.
        model.showHome()
        model.beginNewSession(projectID: rig.projectID)
        let resolved = model.resolvedStart(for: rig.projectID)
        #expect(resolved.mode == ResolvedChoice(value: "acceptEdits", source: .lastUsed))
        #expect(resolved.effort == ResolvedChoice(value: "high", source: .lastUsed))
        #expect(resolved.model == ResolvedChoice(value: "opus", source: .lastUsed))
        model.beginNewSession(projectID: rig.otherProjectID)
        #expect(model.resolvedStart(for: rig.otherProjectID).choices == ClaudeLaunchChoices(permissionMode: "default"))
        // The file keeps no last-used list any more: across a relaunch it is the catalog's (see the catalog tests).
        let again = NewSessionState()
        again.attach(store: NewSessionStore(url: rig.storeURL))
        #expect(again.lastUsed(for: rig.projectID) == nil)
    }

    /// D-63: a new session starts in the project's last used mode, else Ask before edits (`default`), and the mode is always
    /// passed to the CLI explicitly. Full access is never picked by itself, not even when it was the last used.
    @Test func aNewSessionStartsInTheLastUsedModeElseAskBeforeEditsAndNeverInFullAccessByItself() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.setNewSessionFace(.chat) // Ask is a Chat mode: the draft offers it where the session starts in Chat
        func sendOne(mode: DraftPick?) async throws -> NewSessionLaunch {
            let count = rig.intents.sends.count
            await openDraft(model, rig.projectID)
            if let mode { model.setDraftMode(mode, projectID: rig.projectID) }
            model.setDraftText("go \(count)", projectID: rig.projectID)
            model.sendDraft(projectID: rig.projectID)
            #expect(await waitUntil { rig.intents.sends.count == count + 1 })
            let sent = rig.intents.sends[count]
            sent.outcome(.started(UUID()))
            #expect(await waitUntil { !model.newSession.isSending(rig.projectID) })
            model.showHome()
            return sent.launch
        }
        // Nothing used yet: Ask before edits, passed as `default`.
        #expect(try await sendOne(mode: nil).choices.permissionMode == "default")
        // A pick is used and remembered per project.
        #expect(try await sendOne(mode: .value("ask")).choices.permissionMode == "ask")
        #expect(try await sendOne(mode: nil).choices.permissionMode == "ask", "the next session starts where the last one was")
        #expect(model.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "ask", source: .lastUsed))
        #expect(model.resolvedStart(for: rig.otherProjectID).mode == ResolvedChoice(value: "default", source: .loomDefault))
        // Full access is chosen on purpose, and the next session does not inherit it.
        #expect(try await sendOne(mode: .value("bypassPermissions")).choices.permissionMode == "bypassPermissions")
        #expect(try await sendOne(mode: nil).choices.permissionMode == "ask", "Full access is not remembered")
    }

    /// The draft has the model and the effort pickers of the live bar: a pick goes to the launch, `claudeDefault` is the
    /// model's own default on purpose, and the effort a session used is the next one's start.
    @Test func theDraftsModelAndEffortPicksReachTheLaunchAndAreRemembered() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        await openDraft(model, rig.projectID)
        #expect(NewSessionModels.effortLevels == ["low", "medium", "high", "xhigh", "max"])
        model.setDraftModel(.value("sonnet"), projectID: rig.projectID)
        model.setDraftEffort(.value("xhigh"), projectID: rig.projectID)
        let picked = model.resolvedStart(for: rig.projectID)
        #expect(picked.model == ResolvedChoice(value: "sonnet", source: .pick) && picked.effort == ResolvedChoice(value: "xhigh", source: .pick))
        #expect(picked.modelTitle(in: ModelCatalog()) == "Sonnet" && picked.effortTitle == "Extra high")
        // An effort the CLI does not take never reaches a launch.
        model.setDraftEffort(.value("turbo"), projectID: rig.projectID)
        model.setDraftEffort(.value("--x"), projectID: rig.projectID)
        #expect(model.resolvedStart(for: rig.projectID).effort.value == nil)
        model.setDraftEffort(.value("xhigh"), projectID: rig.projectID)
        model.setDraftText("go", projectID: rig.projectID)
        model.sendDraft(projectID: rig.projectID)
        #expect(await waitUntil { !rig.intents.sends.isEmpty })
        #expect(rig.intents.sends[0].launch.choices == ClaudeLaunchChoices(permissionMode: "default", model: "sonnet", effort: "xhigh"))
        rig.intents.sends[0].outcome(.started(UUID()))
        #expect(await waitUntil { model.newSession.lastUsed(for: rig.projectID)?.effort == "xhigh" })
        // The next draft of the project starts from them; choosing the default on purpose is a pick of its own.
        model.showHome()
        model.beginNewSession(projectID: rig.projectID)
        #expect(model.resolvedStart(for: rig.projectID).effort == ResolvedChoice(value: "xhigh", source: .lastUsed))
        model.setDraftModel(.claudeDefault, projectID: rig.projectID)
        let reset = model.resolvedStart(for: rig.projectID)
        #expect(reset.model == ResolvedChoice(value: nil, source: .pick) && reset.modelTitle(in: ModelCatalog()) == "Default model")
    }

    @Test func aDraftFileFromBeforeTheEffortPickerStillReads() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.beginNewSession(projectID: rig.projectID)
        model.setDraftText("old words", projectID: rig.projectID)
        model.setDraftMode(.claudeDefault, projectID: rig.projectID)
        model.setDraftModel(.value("opus"), projectID: rig.projectID)
        model.setDraftEffort(.value("high"), projectID: rig.projectID)
        model.newSession.flush()
        // The file as the version before wrote it: no effort pick.
        var file = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: rig.storeURL)) as? [String: Any])
        var drafts = try #require(file["drafts"] as? [[String: Any]])
        #expect(drafts.allSatisfy { $0["effortPick"] != nil }, "the new file carries the pick")
        for index in drafts.indices { drafts[index]["effortPick"] = nil }
        file["drafts"] = drafts
        try JSONSerialization.data(withJSONObject: file).write(to: rig.storeURL)
        let state = NewSessionState()
        state.attach(store: NewSessionStore(url: rig.storeURL))
        let draft = try #require(state.draft(for: rig.projectID))
        #expect(draft.text == "old words" && draft.effortPick == .inherit && draft.modelPick == .value("opus"))
        // The mode had a "Claude's default" pick: it reads as nothing chosen, so the session starts in Ask before edits.
        let resolved = NewSessionDefaults.resolve(modePick: draft.modePick, modelPick: draft.modelPick, effortPick: draft.effortPick,
                                                  lastUsed: nil, settings: NewSessionSettings())
        #expect(resolved.mode == ResolvedChoice(value: "default", source: .loomDefault))
    }

    @Test func loomsOwnDefaultsSurviveARelaunch() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.setNewSessionDefaults(permissionMode: "acceptEdits", model: "haiku")
        model.beginNewSession(projectID: rig.projectID)
        #expect(model.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "acceptEdits", source: .settings))
        #expect(model.resolvedStart(for: rig.projectID).model == ResolvedChoice(value: "haiku", source: .settings))
        model.setDraftText("go", projectID: rig.projectID)
        model.sendDraft(projectID: rig.projectID)
        #expect(await waitUntil { rig.intents.sends.count == 1 })
        #expect(rig.intents.sends[0].launch.choices == ClaudeLaunchChoices(permissionMode: "acceptEdits", model: "haiku"))
        model.newSession.flush()
        let again = NewSessionState()
        again.attach(store: NewSessionStore(url: rig.storeURL))
        #expect(again.settings == NewSessionSettings(permissionMode: "acceptEdits", model: "haiku"))
        model.setNewSessionDefaults(permissionMode: "--bad", model: nil)
        #expect(model.newSession.settings == NewSessionSettings())
    }

    /// D-69 point 6: Settings → General → Mode of new sessions. Unset, a project's last used mode answers (today's rule); a
    /// fixed mode answers instead; Full access is allowed because the user picks it there, but it asks first.
    @Test func theDefaultModeInSettingsIsLastUsedOrOneFixedModeAndFullAccessAsksFirst() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        let full = ClaudePermissionMode.fullAccess.rawValue
        model.beginNewSession(projectID: rig.projectID)
        // Last used in the project (the setting's default): a project that ran in Accept edits starts there again.
        #expect(model.defaultStartMode == nil)
        #expect(model.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "default", source: .loomDefault))
        model.setDraftMode(.value("acceptEdits"), projectID: rig.projectID)
        model.setDraftText("go", projectID: rig.projectID)
        model.sendDraft(projectID: rig.projectID)
        #expect(await waitUntil { rig.intents.sends.count == 1 })
        rig.intents.sends[0].outcome(.started(UUID()))
        #expect(await waitUntil { !model.newSession.isSending(rig.projectID) })
        model.showHome()
        model.beginNewSession(projectID: rig.projectID)
        #expect(await waitUntil { model.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "acceptEdits", source: .lastUsed) })

        // One fixed mode beats the last used one.
        #expect(model.setDefaultStartMode("auto"))
        #expect(model.defaultStartMode == "auto")
        #expect(model.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "auto", source: .settings))
        // A mode the menus do not offer, or one that could pass for an option, is refused.
        #expect(!model.setDefaultStartMode("plan") && !model.setDefaultStartMode("--bad"))
        #expect(model.defaultStartMode == "auto")

        // Full access asks first: without the confirmation nothing changes.
        #expect(!model.setDefaultStartMode(full))
        #expect(model.defaultStartMode == "auto")
        #expect(model.setDefaultStartMode(full, confirmedFullAccess: true))
        // Drafts then start in it without the per-draft confirmation, and it is not a pick kept from earlier.
        let resolved = model.resolvedStart(for: rig.projectID).mode
        #expect(resolved == ResolvedChoice(value: full, source: .settings))
        #expect(!model.draftKeepsFullAccess(projectID: rig.projectID))
        // Asking once: choosing it again while it is the default asks nothing.
        #expect(model.setDefaultStartMode(full))
        model.newSession.flush()
        let again = NewSessionState()
        again.attach(store: NewSessionStore(url: rig.storeURL))
        #expect(again.settings.permissionMode == full, "the choice survives a relaunch")

        // A first send starts in it, and the project still does not remember Full access.
        model.setDraftText("again", projectID: rig.projectID)
        model.sendDraft(projectID: rig.projectID)
        #expect(await waitUntil { rig.intents.sends.count == 2 })
        #expect(rig.intents.sends[1].launch.choices.permissionMode == full)
        rig.intents.sends[1].outcome(.started(UUID()))
        #expect(await waitUntil { !model.newSession.isSending(rig.projectID) })
        #expect(await waitUntil { model.newSession.lastUsed(for: rig.projectID)?.permissionMode == "acceptEdits" })

        // Back to the project's last used mode.
        #expect(model.setDefaultStartMode(nil))
        #expect(model.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "acceptEdits", source: .lastUsed))
    }

    /// Ask is a Chat mode: where the switch says Terminal, an Ask default starts as Ask before edits.
    @Test func anAskDefaultInSettingsStartsAsAskBeforeEditsWhereTheSwitchSaysTerminal() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.beginNewSession(projectID: rig.projectID)
        #expect(model.setDefaultStartMode("ask"))
        model.setNewSessionFace(.chat)
        #expect(model.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "ask", source: .settings))
        model.setNewSessionFace(.terminal)
        #expect(model.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "default", source: .settings))
    }

    // MARK: A tracker key in the text means nothing to Loom (D-69)

    @Test func aTrackerKeyInADraftChangesNothingItStartsAtOnceUntitledWithALoomBranch() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        // A session of this project whose title starts with the same key: nothing looks it up any more.
        let folder = root.appendingPathComponent("api").path
        try await rig.catalog.insertSession(
            ManagedSession(provider: .claude, workingDirectory: folder), title: "PAY-418 Reverse-charge note", projectID: rig.projectID)

        await openDraft(model, rig.projectID)
        model.setDraftText("PAY-418 add the note", projectID: rig.projectID)
        model.setDraftBranch(.newBranch, projectID: rig.projectID)
        #expect(model.canSendDraft(projectID: rig.projectID), "nothing is checked, so nothing can block the send")
        model.sendDraft(projectID: rig.projectID)
        // At once: no look-up runs first, so the runtime has been asked by the time the call returns.
        let sent = try #require(rig.intents.sends.first, "the send did not wait for a check")
        #expect(rig.intents.sends.count == 1)
        #expect(sent.launch.firstMessage == "PAY-418 add the note")
        #expect(sent.launch.workspace == .newBranch("sphyrna/pay-418-add-the"), "the only suggestion is sphyrna/<words>")
        sent.outcome(.started(UUID()))
        #expect(model.newSession.draft(for: rig.projectID)?.isVisible == false)
    }

    @Test func aFreshDraftSendWithKeysInTheTextHandsTheDraftOverInTheSameTurn() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        await openDraft(model, rig.projectID)
        model.setDraftText("EDDP-19964 and PAY-418: do both", projectID: rig.projectID)
        model.sendDraft(projectID: rig.projectID, startsFreshDraft: true)
        let sent = try #require(rig.intents.sends.first)
        #expect(sent.focus == .freshDraft && sent.launch.workspace == .projectFolder)
        #expect(model.newSession.draft(for: rig.projectID)?.isVisible == false, "handed over in the same turn")
    }

    // MARK: Typing in a long draft

    @Test func aKeystrokeCostsTheSameInAShortDraftAndALongOne() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.beginNewSession(projectID: rig.projectID)
        let store = try #require(model.newSession.store)
        // The timer never fires inside this test: the saves below are asked for.
        store.delay = .seconds(60)
        let id = rig.projectID

        var text = ""
        // From a few words to the cap of one message (128 KiB), each size typed into for fifty keystrokes.
        for size in [40, 4_000, 32_000, NewSessionLaunch.maxFirstMessageBytes - 100] {
            text = String(repeating: "word ", count: size / 5)
            model.setDraftText(text, projectID: id)
            model.newSession.flush()
            let snapshots = store.snapshotsBuilt
            let writes = store.writeCount

            let began = ContinuousClock.now
            for _ in 0..<50 {
                text += "x"
                model.setDraftText(text, projectID: id)
            }
            let spent = ContinuousClock.now - began
            #expect(store.snapshotsBuilt == snapshots, "no keystroke builds the saved form of the drafts (\(size) bytes)")
            #expect(store.writeCount == writes, "and none writes (\(size) bytes)")
            // Loose guard against a pass over the text that grows with it, not a measurement.
            #expect(spent < .seconds(2), "50 keystrokes took \(spent) at \(size) bytes")

            // The save does the work once: one saved form, one write.
            model.newSession.flush()
            #expect(store.snapshotsBuilt == snapshots + 1 && store.writeCount == writes + 1)
        }
        #expect(model.newSession.draft(for: id)?.text == text)
        #expect(store.file.drafts.map(\.text) == [text], "what was saved is what was typed")
    }

    @Test func whetherADraftHasTextIsKnownWithoutReadingItAndItsRowTitleStopsAtTheFirstLine() {
        var draft = SessionDraft(projectID: nil)
        #expect(!draft.isVisible && !draft.hasText)
        draft.text = " \n\t  \n"
        #expect(!draft.isVisible && draft.trimmedText.isEmpty, "white space alone is not a draft")
        draft.text = "\n  fix the flaky test   \nsecond line"
        #expect(draft.isVisible && DraftRow.title(of: draft) == "fix the flaky test")
        draft.text = "   "
        #expect(DraftRow.title(of: draft) == "New session")
        // One line of the cap's size: the title is cut, and the cut is made without reading the rest.
        draft.text = String(repeating: "a", count: NewSessionLaunch.maxFirstMessageBytes)
        #expect(DraftRow.title(of: draft).count == DraftRow.maximumTitleLength)
        draft.text = "PAY-418 add the note\r\nmore"
        #expect(DraftRow.title(of: draft) == "PAY-418 add the note")
        #expect(NewSessionBranchNames.suggest(text: "\nPAY-418 add the note\nsecond line about other things")
            == "sphyrna/pay-418-add-the")
    }

    // MARK: A save that goes wrong

    @Test func aFailedSaveIsSaidWhereTheDraftIsAndTheNextGoodSaveClearsIt() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.beginNewSession(projectID: rig.projectID)
        #expect(model.newSession.storeNotice == nil)
        // The file's place is taken by a folder that is not empty: the write cannot replace it.
        try FileManager.default.createDirectory(at: rig.storeURL, withIntermediateDirectories: true)
        try "keep".write(to: rig.storeURL.appendingPathComponent("inside"), atomically: true, encoding: .utf8)

        model.setDraftText("words that must not be lost", projectID: rig.projectID)
        model.newSession.flush()
        let notice = try #require(model.newSession.storeNotice)
        #expect(notice.contains("could not be saved") && notice.contains("still here"))
        #expect(model.newSession.draft(for: rig.projectID)?.text == "words that must not be lost", "the text itself is untouched")

        try FileManager.default.removeItem(at: rig.storeURL)
        model.newSession.flush()
        #expect(model.newSession.storeNotice == nil, "the next good save clears it")
        #expect(NewSessionStore(url: rig.storeURL).file.drafts.map(\.text) == ["words that must not be lost"])
    }

    // MARK: The first send

    @Test func theFirstSendHandsTheRuntimeTheMessageTheResolvedChoicesAndTheStripsBranchAndNoTitle() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        await openDraft(model, rig.projectID)
        model.setDraftText("  PAY-418 Add the reverse-charge note\nThe wording is in the doc.  ", projectID: rig.projectID)
        model.setDraftMode(.value("plan"), projectID: rig.projectID)
        model.setDraftModel(.value("haiku"), projectID: rig.projectID)
        model.setDraftBranch(.newBranch, projectID: rig.projectID)
        #expect(model.canSendDraft(projectID: rig.projectID))

        model.sendDraft(projectID: rig.projectID)
        #expect(model.newSession.isSending(rig.projectID), "a second ↵ does nothing while the first is under way")
        #expect(!model.canSendDraft(projectID: rig.projectID))
        #expect(await waitUntil { !rig.intents.sends.isEmpty })
        let sent = try #require(rig.intents.sends.first)
        #expect(rig.intents.sends.count == 1 && rig.intents.plainStarts == 0)
        #expect(sent.projectID == rig.projectID && sent.focus == .session)
        #expect(sent.launch.firstMessage == "PAY-418 Add the reverse-charge note\nThe wording is in the doc.")
        #expect(sent.launch.choices == ClaudeLaunchChoices(permissionMode: "plan", model: "haiku"))
        #expect(sent.launch.workspace == .newBranch("sphyrna/pay-418-add-the"))
        // The draft keeps its words until the session exists.
        #expect(model.newSession.draft(for: rig.projectID)?.isVisible == true)
        sent.outcome(.started(UUID()))
        #expect(model.newSession.draft(for: rig.projectID)?.isVisible == false && model.visibleDrafts.isEmpty)
        #expect(!model.newSession.isSending(rig.projectID))
    }

    @Test func aTypedBranchNameAndAWorktreeGoThroughAndWithoutABranchChoiceTheFolderStaysAsItIs() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        await openDraft(model, rig.projectID)
        model.setDraftText("fix the flaky test", projectID: rig.projectID)
        model.sendDraft(projectID: rig.projectID)
        #expect(await waitUntil { rig.intents.sends.count == 1 })
        let plain = rig.intents.sends[0].launch
        #expect(plain.workspace == .projectFolder
            && plain.choices == ClaudeLaunchChoices(permissionMode: "default"))
        rig.intents.sends[0].outcome(.failed)

        model.setDraftBranch(.newWorktree, name: "feat/mine", projectID: rig.projectID)
        model.sendDraft(projectID: rig.projectID)
        #expect(await waitUntil { rig.intents.sends.count == 2 })
        #expect(rig.intents.sends[1].launch.workspace == .newWorktree("feat/mine"))
        // The suggestion is made from the first words.
        #expect(NewSessionBranchNames.suggest(text: "Fix the flaky test in billing, please") == "sphyrna/fix-the-flaky-test")
        #expect(NewSessionBranchNames.suggest(text: "PAY-418 İşlem düzeltme") == "sphyrna/pay-418-islem-duzeltme")
        #expect(NewSessionBranchNames.suggest(text: "???", now: Date(timeIntervalSince1970: 0)).hasPrefix("sphyrna/session-"))
    }

    @Test func aBadBranchNameOrAFolderWithoutGitStopsTheSendBeforeAnythingStarts() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        await openDraft(model, rig.projectID)
        model.setDraftText("work", projectID: rig.projectID)
        model.setDraftBranch(.newBranch, name: "bad name", projectID: rig.projectID)
        #expect(!model.canSendDraft(projectID: rig.projectID))
        model.setDraftBranch(.newBranch, name: "good/name", projectID: rig.projectID)
        #expect(model.canSendDraft(projectID: rig.projectID))
        // The folder is not a repository (the strip read it): there is nothing to branch from.
        model.newSession.setBranch(.unavailable, for: rig.projectID)
        #expect(!model.canSendDraft(projectID: rig.projectID))
        model.setDraftBranch(.stay, projectID: rig.projectID)
        #expect(model.canSendDraft(projectID: rig.projectID))
        for good in ["feat/PAY-418-x", "sphyrna/a", "a.b"] { #expect(NewSessionBranchNames.isPlausible(good)) }
        for bad in ["", "-x", "a b", "a..b", "x~1", "x^", "a:b", "a?", "a*", "a[", "a\\b", "a/", "/a", "a.lock", "a.", "a//b", "a@{b"] {
            #expect(!NewSessionBranchNames.isPlausible(bad), "\(bad)")
        }
    }

    /// DESIGN §8: the popover closes on a name Git would refuse, and the page keeps Send off and says why on the chosen segment.
    @Test func aBadNameKeepsSendOffAndTheChosenSegmentSaysWhy() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        await openDraft(model, rig.projectID)
        model.setDraftText("work", projectID: rig.projectID)
        func chosen() -> DraftWords.Segment {
            let draft = model.newSession.draft(for: rig.projectID) ?? SessionDraft(projectID: rig.projectID)
            return DraftWords.segments(
                hasProject: true, branch: model.newSession.branch(for: rig.projectID), chosen: draft.branchKind,
                name: model.draftBranchName(draft)).first(where: \.isChosen)!
        }
        model.setDraftBranch(.newBranch, name: "bad name", projectID: rig.projectID)
        #expect(!model.canSendDraft(projectID: rig.projectID))
        #expect(chosen().kind == .newBranch && chosen().name == "bad name" && chosen().reason == DraftWords.invalidName)
        model.setDraftBranch(.newWorktree, projectID: rig.projectID)
        #expect(chosen().kind == .newWorktree && chosen().name == "bad name" && chosen().reason != nil, "the name carries over")
        #expect(!model.canSendDraft(projectID: rig.projectID))
        model.setDraftBranch(.newWorktree, name: "feat/mine", projectID: rig.projectID)
        #expect(model.canSendDraft(projectID: rig.projectID))
        #expect(chosen().name == "feat/mine" && chosen().reason == nil)
        // A cleared name goes back to the suggestion made from the text.
        model.setDraftBranch(.newWorktree, name: "", projectID: rig.projectID)
        #expect(chosen().name == "sphyrna/work" && chosen().reason == nil)
        #expect(model.canSendDraft(projectID: rig.projectID))
    }

    @Test func aFirstMessageTooLongForAnArgumentIsRefusedBeforeAnythingStartsWithAClearMessage() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        await openDraft(model, rig.projectID)
        let limit = NewSessionLaunch.maxFirstMessageBytes
        // ~1 MB would reach ARG_MAX; the limit is far below it.
        #expect(limit < 1_048_576 / 4)
        model.setDraftText(String(repeating: "a", count: limit), projectID: rig.projectID)
        #expect(model.canSendDraft(projectID: rig.projectID) && model.draftSendBlock(projectID: rig.projectID) == nil, "at the limit it goes")
        model.setDraftText(String(repeating: "a", count: limit + 1), projectID: rig.projectID)
        #expect(!model.canSendDraft(projectID: rig.projectID))
        let block = try #require(model.draftSendBlock(projectID: rig.projectID))
        #expect(block.contains("too long") && block.contains("\(limit / 1024) KB"))
        model.setDraftBranch(.newBranch, projectID: rig.projectID)
        model.sendDraft(projectID: rig.projectID)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.intents.sends.isEmpty && !model.newSession.isSending(rig.projectID), "no start, no git step")
        // Bytes count, not characters.
        model.setDraftBranch(.stay, projectID: rig.projectID)
        model.setDraftText(String(repeating: "ş", count: limit / 2), projectID: rig.projectID)
        #expect(model.canSendDraft(projectID: rig.projectID))
        model.setDraftText(String(repeating: "ş", count: limit / 2 + 1), projectID: rig.projectID)
        #expect(!model.canSendDraft(projectID: rig.projectID))
    }

    @Test func fullAccessThatWasNotPickedOnThisScreenSaysWhereItCameFromAndAPickNowDoesNot() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        let full = ClaudePermissionMode.fullAccess.rawValue
        await openDraft(model, rig.projectID)
        model.setDraftText("work", projectID: rig.projectID)
        model.setDraftMode(.value(full), projectID: rig.projectID)
        #expect(!model.draftKeepsFullAccess(projectID: rig.projectID), "picked just now")
        model.setDraftMode(.value("plan"), projectID: rig.projectID)
        #expect(!model.draftKeepsFullAccess(projectID: rig.projectID))

        // A pick saved with the draft and read back after a relaunch was not made on this screen.
        model.setDraftMode(.value(full), projectID: rig.projectID)
        model.newSession.flush()
        let again = CatalogModel(
            catalog: rig.catalog, events: SessionEventHub(),
            preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        defer { again.stop() }
        again.prepareNewSession()
        again.showDraft(projectID: rig.projectID)
        #expect(again.resolvedStart(for: rig.projectID).mode.value == full)
        #expect(again.draftKeepsFullAccess(projectID: rig.projectID), "kept from earlier")
        again.setDraftMode(.value(full), projectID: rig.projectID)
        #expect(!again.draftKeepsFullAccess(projectID: rig.projectID), "choosing it again is a decision made now")

        // A preset's mode is kept from earlier too, even when it was just applied; the other modes never say it.
        model.setDraftMode(.value(full), projectID: rig.projectID)
        model.savePreset(projectID: rig.projectID)
        let preset = try #require(model.presets(for: rig.projectID).first)
        model.discardDraft(projectID: rig.projectID)
        model.applyPreset(preset, projectID: rig.projectID)
        #expect(model.draftKeepsFullAccess(projectID: rig.projectID))
        model.setDraftMode(.value("plan"), projectID: rig.projectID)
        #expect(!model.draftKeepsFullAccess(projectID: rig.projectID))
    }

    @Test func theNewSessionFileIsReadableByTheUserAlone() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.beginNewSession(projectID: rig.projectID)
        model.setDraftText("the private words", projectID: rig.projectID)
        model.newSession.flush()
        let mode = try FileManager.default.attributesOfItem(atPath: rig.storeURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        model.setDraftText("more words", projectID: rig.projectID)
        model.newSession.flush()
        #expect(try FileManager.default.attributesOfItem(atPath: rig.storeURL.path)[.posixPermissions] as? Int == 0o600, "and after a rewrite")
    }

    @Test func controlReturnStartsAndOpensAFreshDraftAndAFailedStartGivesTheWordsBack() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.showDraft(projectID: rig.projectID)
        model.setDraftText("first idea", projectID: rig.projectID)
        model.setDraftMode(.value("acceptEdits"), projectID: rig.projectID)
        model.sendDraft(projectID: rig.projectID, startsFreshDraft: true)
        #expect(await waitUntil { rig.intents.sends.count == 1 })
        let sent = rig.intents.sends[0]
        #expect(sent.focus == .freshDraft && sent.launch.firstMessage == "first idea")
        // The window is on a fresh, empty draft of the same project while the session starts.
        #expect(model.destination == .draft(projectID: rig.projectID))
        let fresh = try #require(model.newSession.draft(for: rig.projectID))
        #expect(fresh.text.isEmpty && fresh.modePick == .inherit && model.visibleDrafts.isEmpty)
        #expect(!model.newSession.isSending(rig.projectID))

        // The start failed: the text comes back as its own draft, beside what was typed meanwhile.
        model.setDraftText("second idea", projectID: rig.projectID)
        sent.outcome(.failed)
        #expect(model.newSession.draft(for: rig.projectID)?.text == "second idea")
        #expect(Set(model.visibleDrafts.map(\.text)) == ["first idea", "second idea"])
        // And into an empty draft as it was.
        model.discardDraft(projectID: rig.projectID)
        model.setDraftText("third", projectID: rig.projectID)
        model.sendDraft(projectID: rig.projectID, startsFreshDraft: true)
        #expect(await waitUntil { rig.intents.sends.count == 2 })
        rig.intents.sends[1].outcome(.failed)
        #expect(model.newSession.draft(for: rig.projectID)?.text == "third")
        // A start that worked records what the project used and leaves the fresh draft alone.
        model.sendDraft(projectID: rig.projectID, startsFreshDraft: true)
        #expect(await waitUntil { rig.intents.sends.count == 3 })
        rig.intents.sends[2].outcome(.started(UUID()))
        #expect(model.newSession.draft(for: rig.projectID)?.isVisible == false)
    }

    @Test func aFailedFirstSendKeepsTheDraftAndTheSessionsModeIsKeptForItsResume() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.showDraft(projectID: rig.projectID)
        model.setDraftText("keep me", projectID: rig.projectID)
        model.setDraftMode(.value("plan"), projectID: rig.projectID)
        model.sendDraft(projectID: rig.projectID)
        #expect(await waitUntil { rig.intents.sends.count == 1 })
        rig.intents.sends[0].outcome(.failed)
        #expect(model.newSession.draft(for: rig.projectID)?.text == "keep me" && model.canSendDraft(projectID: rig.projectID))
        #expect(model.newSession.lastUsed(for: rig.projectID) == nil, "a start that failed is not 'last used'")

        model.sendDraft(projectID: rig.projectID)
        #expect(await waitUntil { rig.intents.sends.count == 2 })
        let session = UUID()
        rig.intents.sends[1].outcome(.started(session))
        _ = session
        // The catalog records the session's choices when its card is made (a resume passes them); the draft's file keeps no
        // launch list of its own any more, and the project's next draft shows what this start used at once.
        #expect(model.newSession.lastUsed(for: rig.projectID)?.permissionMode == "plan")
        model.flushPreferences()
        model.newSession.flush()
        let again = NewSessionState()
        again.attach(store: NewSessionStore(url: rig.storeURL))
        #expect(again.legacyLaunchRecords().launched.isEmpty && again.legacyLaunchRecords().lastUsed.isEmpty,
                "nothing is appended to the file's launched or lastUsed lists")
    }

    /// D11: a live change of mode, model or effort in a session is what its project's next draft starts with (the catalog
    /// records it), and Full access is never remembered.
    @Test func aLiveChangeInASessionIsWhatTheNextDraftOfItsProjectStartsWith() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        let session = ManagedSession(provider: .claude, workingDirectory: root.path)
        try await rig.catalog.insertSession(session, title: "Live", projectID: rig.projectID)
        #expect(model.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "default", source: .loomDefault))

        try await rig.catalog.recordLaunchChoices(ClaudeLaunchChoices(permissionMode: "acceptEdits"), sessionID: session.id)
        model.refreshLastUsedChoices()
        #expect(await waitUntil { model.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "acceptEdits", source: .lastUsed) })
        #expect(model.resolvedStart(for: rig.otherProjectID).mode.source == .loomDefault, "another project is untouched")

        // Full access, picked live, is not what the next session starts in; the model next to it is remembered.
        try await rig.catalog.recordLaunchChoices(
            ClaudeLaunchChoices(permissionMode: ClaudePermissionMode.fullAccess.rawValue, model: "opus"), sessionID: session.id)
        model.refreshLastUsedChoices()
        #expect(await waitUntil { model.resolvedStart(for: rig.projectID).model == ResolvedChoice(value: "opus", source: .lastUsed) })
        #expect(model.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "acceptEdits", source: .lastUsed))
        // The catalog is where it lives: a model made later reads it.
        let later = CatalogModel(catalog: rig.catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("prefs-later.json")))
        await later.start()
        defer { later.stop() }
        #expect(later.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "acceptEdits", source: .lastUsed))
    }

    @Test func aDraftNeedsARuntimeThatCanStartIt() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.showDraft(projectID: rig.projectID)
        model.setDraftText("work", projectID: rig.projectID)
        #expect(model.canSendDraft(projectID: rig.projectID))
        model.intents = nil
        #expect(!model.canSendDraft(projectID: rig.projectID), "no runtime, no send: the text stays")
        model.sendDraft(projectID: rig.projectID)
        #expect(rig.intents.sends.isEmpty && model.newSession.draft(for: rig.projectID)?.text == "work")
        // An empty draft cannot be sent either.
        model.intents = rig.intents
        model.setDraftText(" \n ", projectID: rig.projectID)
        #expect(!model.canSendDraft(projectID: rig.projectID))
    }

    // MARK: Presets

    @Test func presetsAreSavedPerProjectApplyWithoutStartingAndSurviveARelaunch() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.showDraft(projectID: rig.projectID)
        model.savePreset(projectID: rig.projectID)
        #expect(model.presets(for: rig.projectID).isEmpty, "nothing typed, nothing to save")
        model.setDraftText("Run the test suite and fix failures\nstart with the slowest", projectID: rig.projectID)
        model.setDraftMode(.value("plan"), projectID: rig.projectID)
        model.savePreset(projectID: rig.projectID)
        let preset = try #require(model.presets(for: rig.projectID).first)
        #expect(preset.name == "Run the test suite and fix failures" && preset.permissionMode == "plan" && preset.projectID == rig.projectID)
        #expect(model.presets(for: rig.otherProjectID).isEmpty, "a preset belongs to its project")
        model.newSession.addPreset(NewSessionPreset(name: "Review my last commit", message: "Review my last commit"))
        #expect(model.presets(for: rig.otherProjectID).map(\.name) == ["Review my last commit"], "one for every project")

        // One click puts the message in the draft with its mode; nothing starts.
        model.discardDraft(projectID: rig.projectID)
        model.applyPreset(preset, projectID: rig.projectID)
        #expect(model.newSession.draft(for: rig.projectID)?.text == preset.message)
        #expect(model.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "plan", source: .pick))
        #expect(rig.intents.sends.isEmpty)
        model.applyPreset(preset, projectID: rig.projectID)
        #expect(model.newSession.draft(for: rig.projectID)?.text == preset.message + "\n\n" + preset.message, "a preset adds to what is there")

        model.newSession.flush()
        let again = NewSessionState()
        again.attach(store: NewSessionStore(url: rig.storeURL))
        #expect(again.presets.map(\.name) == ["Run the test suite and fix failures", "Review my last commit"])
        model.removePreset(preset)
        #expect(model.presets(for: rig.projectID).map(\.name) == ["Review my last commit"])
    }

    @MainActor
    @Test func anUnreadableFileIsKeptAsideAndTheNextSaveDoesNotReplaceIt() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("new-session.json")
        let garbage = "{\"drafts\": [ this is not json"
        try garbage.write(to: url, atomically: true, encoding: .utf8)

        let store = NewSessionStore(url: url)
        #expect(store.file == NewSessionFile(), "it reads as empty")
        let notice = try #require(store.loadNotice)
        #expect(!FileManager.default.fileExists(atPath: url.path), "and is moved out of the way")
        let aside = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("new-session.unreadable-") }
        #expect(aside.count == 1 && notice.contains(aside[0]))
        #expect(try String(contentsOf: root.appendingPathComponent(aside[0]), encoding: .utf8) == garbage, "as it was")

        // The next change writes a new file; the old one is still there.
        store.change { $0.settings = NewSessionSettings(permissionMode: "plan", model: nil) }
        store.flush()
        #expect(FileManager.default.fileExists(atPath: url.path) && store.lastFailure == nil)
        #expect(try String(contentsOf: root.appendingPathComponent(aside[0]), encoding: .utf8) == garbage)

        // A file that reads fine is left where it is, and so is a missing one.
        #expect(NewSessionStore(url: url).loadNotice == nil)
        #expect(NewSessionStore(url: root.appendingPathComponent("nothing.json")).loadNotice == nil)
    }

    @Test func anUnreadableFileOrEntryReadsAsEmptyAndTheRestSurvives() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("new-session.json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(NewSessionStore(url: url).file == NewSessionFile())
        let good = """
        {"presets":[{"id":"\(UUID())","name":"ok","message":"m"},{"broken":true}],"lastUsed":{"none":{"model":"opus"}},
         "unknownKey":1,"drafts":[{"nonsense":1}],"launched":"wrong"}
        """
        try good.write(to: url, atomically: true, encoding: .utf8)
        let file = NewSessionStore(url: url).file
        #expect(file.presets.map(\.name) == ["ok"] && file.lastUsed["none"]?.model == "opus" && file.drafts.isEmpty && file.launched.isEmpty)
    }

    // MARK: The composer's keys

    @MainActor
    @Test func returnSendsCommandReturnOpensAFreshDraftShiftReturnIsANewLineAndAnInputMethodIsLeftAlone() throws {
        // The draft's composer is the shared text field with the draft's host: the keys are the shared rules (`ComposerKeys`).
        final class Host: ComposerEditorHost {
            var sends = 0, fresh = 0
            var keyMode: ComposerKeys.Mode { .draft }
            var syncsByRevision: Bool { false }
            var textRevision: Int { 0 }
            var modelText: String { "" }
            func keyState(isRepeat: Bool, hasMarkedText: Bool, bridge: any ComposerEditorBridge) -> ComposerKeys.State {
                var state = ComposerKeys.State()
                state.mode = .draft
                state.isRepeat = isRepeat
                state.hasMarkedText = hasMarkedText
                return state
            }
            func perform(_ action: ComposerKeys.Action, bridge: any ComposerEditorBridge, in window: NSWindow?) -> Bool {
                switch action {
                case .send: sends += 1
                case .sendSecondary: fresh += 1
                default: return false
                }
                return true
            }
            func textChanged(_ text: String) {}
            func editorEndedEditing() {}
            func paste(_ pasteboard: NSPasteboard, plain: Bool) -> Bool { false }
            func drop(_ pasteboard: NSPasteboard) -> Bool { false }
            func editorAttached(_ bridge: (any ComposerEditorBridge)?) {}
        }
        let host = Host()
        let editor = ComposerTextEditor(host: host, height: .constant(60), minimumHeight: 60, maximumHeight: 220)
        let coordinator = editor.makeCoordinator()
        let view = ComposerTextEditor.ComposerTextView()
        view.coordinator = coordinator
        coordinator.textView = view
        func press(_ modifiers: NSEvent.ModifierFlags, code: UInt16 = 36, repeating: Bool = false) throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeating, keyCode: code))
            view.keyDown(with: event)
        }
        try press([])
        #expect(host.sends == 1 && host.fresh == 0)
        try press([], code: 76)
        #expect(host.sends == 2, "the keypad's Enter too")
        try press([.command])
        #expect(host.sends == 2 && host.fresh == 1)
        try press([], repeating: true)
        try press([.command], repeating: true)
        #expect(host.sends == 2 && host.fresh == 1, "a held key never sends twice")
        view.string = "ab"
        view.setSelectedRange(NSRange(location: 1, length: 0))
        try press([.shift])
        #expect(view.string == "a\nb" && host.sends == 2, "Shift-Return is a new line")
        try press([.option])
        #expect(view.string == "a\n\nb")
        // While an input method composes, Return belongs to it.
        view.setMarkedText("ö", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        try press([])
        #expect(host.sends == 2)
    }

    @Test func theDraftScreenDrawsWithoutStartingAnything() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.showDraft(projectID: rig.projectID)
        model.setDraftText("PAY-418 add the note", projectID: rig.projectID)
        #expect(model.detailRoute == .draft(projectID: rig.projectID))
        // The view builds from the model alone: a hosting view lays out offscreen, no window and no process.
        let hosting = NSHostingView(rootView: DraftSessionView(model: model, projectID: rig.projectID))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0)
        #expect(rig.intents.sends.isEmpty && rig.intents.plainStarts == 0)
    }
}
