import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// V07: the draft session. Drafts are stored and reused, the defaults follow one order, a ticket key finds the
/// session the project already has, and the first send hands the runtime what the draft shows. Everything
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
        // One slot per project: the draft with text is what its project opens.
        model.beginNewSession(projectID: rig.projectID)
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
        model.setDraftMode(.claudeDefault, projectID: rig.projectID)
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
        #expect(restored.branchKind == .newBranch && restored.branchName == "feat/mine" && restored.modePick == .claudeDefault)

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

    // MARK: Defaults

    @Test func theDefaultsFollowThePickThenLastUsedThenSettingsThenTheCli() {
        let last = ClaudeLaunchChoices(permissionMode: "acceptEdits", model: "sonnet")
        let settings = NewSessionSettings(permissionMode: "plan", model: "haiku")
        func resolve(_ mode: DraftPick = .inherit, _ model: DraftPick = .inherit, last: ClaudeLaunchChoices? = nil,
                     settings: NewSessionSettings = NewSessionSettings()) -> ResolvedStart {
            NewSessionDefaults.resolve(modePick: mode, modelPick: model, lastUsed: last, settings: settings)
        }
        // 4: nothing says anything, so nothing is passed and the chip still names it.
        let none = resolve()
        #expect(none.mode == ResolvedChoice(value: nil, source: .cliDefault) && none.model == ResolvedChoice(value: nil, source: .cliDefault))
        #expect(none.choices.isEmpty && none.modeTitle == "Claude's default")
        // 3: Loom's settings.
        #expect(resolve(settings: settings).mode == ResolvedChoice(value: "plan", source: .settings))
        #expect(resolve(settings: settings).model == ResolvedChoice(value: "haiku", source: .settings))
        // 2: what was last used in the project beats the settings.
        let remembered = resolve(last: last, settings: settings)
        #expect(remembered.mode == ResolvedChoice(value: "acceptEdits", source: .lastUsed))
        #expect(remembered.model == ResolvedChoice(value: "sonnet", source: .lastUsed))
        #expect(remembered.modeTitle == "Accept edits" && remembered.modelTitle == "Sonnet")
        // 1: a pick beats everything, and choosing Claude's default on purpose is a pick too.
        let picked = resolve(.value("auto"), .value("opus"), last: last, settings: settings)
        #expect(picked.mode == ResolvedChoice(value: "auto", source: .pick) && picked.model == ResolvedChoice(value: "opus", source: .pick))
        let explicit = resolve(.claudeDefault, .claudeDefault, last: last, settings: settings)
        #expect(explicit.mode == ResolvedChoice(value: nil, source: .pick) && explicit.choices.isEmpty)
        // Each chip follows its own levels.
        let mixed = resolve(.value("plan"), last: last)
        #expect(mixed.mode.source == .pick && mixed.model == ResolvedChoice(value: "sonnet", source: .lastUsed))
    }

    @Test func loomNeverPicksFullAccessByItself() {
        let full = ClaudePermissionMode.fullAccess.rawValue
        let last = ClaudeLaunchChoices(permissionMode: full)
        // A remembered or configured Full access is skipped: the next level answers.
        #expect(NewSessionDefaults.resolve(modePick: .inherit, modelPick: .inherit, lastUsed: last,
                                           settings: NewSessionSettings(permissionMode: "plan")).mode
            == ResolvedChoice(value: "plan", source: .settings))
        #expect(NewSessionDefaults.resolve(modePick: .inherit, modelPick: .inherit, lastUsed: last,
                                           settings: NewSessionSettings(permissionMode: full)).mode
            == ResolvedChoice(value: nil, source: .cliDefault))
        // Only a pick in this draft carries it, and it looks like every other mode.
        let picked = NewSessionDefaults.resolve(modePick: .value(full), modelPick: .inherit, lastUsed: nil, settings: NewSessionSettings())
        #expect(picked.mode == ResolvedChoice(value: full, source: .pick) && picked.modeTitle == "Full access")
        // A value that could be taken for an option never resolves.
        #expect(NewSessionDefaults.resolve(modePick: .value("--x"), modelPick: .inherit, lastUsed: nil, settings: NewSessionSettings())
            .mode.value == nil)
    }

    @Test func whatWasLastUsedInAProjectIsRememberedPerProjectAndAcrossRelaunches() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.showDraft(projectID: rig.projectID)
        model.setDraftMode(.value("plan"), projectID: rig.projectID)
        model.setDraftModel(.value("opus"), projectID: rig.projectID)
        model.setDraftText("go", projectID: rig.projectID)
        model.sendDraft(projectID: rig.projectID)
        #expect(await waitUntil { !rig.intents.sends.isEmpty })
        rig.intents.sends[0].outcome(.started(UUID()))

        // The next draft of that project starts from it, wherever it is opened from; another project does not.
        model.showHome()
        model.beginNewSession(projectID: rig.projectID)
        let resolved = model.resolvedStart(for: rig.projectID)
        #expect(resolved.mode == ResolvedChoice(value: "plan", source: .lastUsed))
        #expect(resolved.model == ResolvedChoice(value: "opus", source: .lastUsed))
        model.beginNewSession(projectID: rig.otherProjectID)
        #expect(model.resolvedStart(for: rig.otherProjectID).choices.isEmpty)
        // A relaunch reads it back from the file.
        let again = NewSessionState()
        again.attach(store: NewSessionStore(url: rig.storeURL))
        #expect(again.lastUsed(for: rig.projectID) == ClaudeLaunchChoices(permissionMode: "plan", model: "opus"))
        #expect(again.lastUsed(for: rig.otherProjectID) == nil)
    }

    @Test func loomsOwnDefaultsAreTheThirdLevelAndSurviveARelaunch() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.setNewSessionDefaults(permissionMode: "plan", model: "haiku")
        model.beginNewSession(projectID: rig.projectID)
        #expect(model.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "plan", source: .settings))
        #expect(model.resolvedStart(for: rig.projectID).model == ResolvedChoice(value: "haiku", source: .settings))
        model.setDraftText("go", projectID: rig.projectID)
        model.sendDraft(projectID: rig.projectID)
        #expect(await waitUntil { rig.intents.sends.count == 1 })
        #expect(rig.intents.sends[0].launch.choices == ClaudeLaunchChoices(permissionMode: "plan", model: "haiku"))
        model.newSession.flush()
        let again = NewSessionState()
        again.attach(store: NewSessionStore(url: rig.storeURL))
        #expect(again.settings == NewSessionSettings(permissionMode: "plan", model: "haiku"))
        model.setNewSessionDefaults(permissionMode: "--bad", model: nil)
        #expect(model.newSession.settings == NewSessionSettings())
    }

    // MARK: Ticket detection and the duplicate check

    @Test func aTicketKeyIsFoundByAGenericPatternAndLookAlikesAreLeftOut() {
        let pattern = TicketPattern.generic
        #expect(pattern.firstKey(in: "Add the note PAY-418 to invoices") == "PAY-418")
        #expect(pattern.firstKey(in: "PAY-418") == "PAY-418")
        #expect(pattern.firstKey(in: "see (EDDP-19964), then ABC-1") == "EDDP-19964", "the first key wins")
        #expect(pattern.firstKey(in: "branch feat/PAY-418-note") == "PAY-418")
        for none in ["", "fix the bug", "pay-418", "utf-8 handling", "UTF-8 handling", "SHA-256 of the file", "ISO-8601 dates",
                     "A-1", "ABCDEFGHIJK-12", "PAY-1234567", "XPAY-418x", "a_PAY-418", "PAY418"] {
            #expect(pattern.firstKey(in: none) == nil, "\(none)")
        }
        // The prefixes become configurable later: a list narrows it to the tracker's own.
        let tracker = TicketPattern(allowedPrefixes: ["PAY"])
        #expect(tracker.firstKey(in: "OPS-9 and PAY-418") == "PAY-418" && tracker.firstKey(in: "OPS-9") == nil)
    }

    @Test func aTicketThatAlreadyHasASessionIsFoundByKeyOrByTitleInTheSameProjectOnly() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        let folder = root.appendingPathComponent("api").path
        let byKey = ManagedSession(provider: .claude, workingDirectory: folder)
        try await rig.catalog.insertSession(byKey, title: "Reverse-charge note", projectID: rig.projectID, ticketKey: "PAY-418")
        let byTitle = ManagedSession(provider: .claude, workingDirectory: folder)
        try await rig.catalog.insertSession(byTitle, title: "pay-7 Fix the totals", projectID: rig.projectID)
        let elsewhere = ManagedSession(provider: .claude, workingDirectory: folder)
        try await rig.catalog.insertSession(elsewhere, title: "OPS-3", projectID: rig.otherProjectID, ticketKey: "OPS-3")

        let found = await model.ticketStatus(of: "Please do PAY-418 now", projectID: rig.projectID)
        #expect(found == .exists(key: "PAY-418", sessionID: byKey.id, title: "Reverse-charge note"))
        #expect(await model.ticketStatus(of: "PAY-7: again", projectID: rig.projectID)
            == .exists(key: "PAY-7", sessionID: byTitle.id, title: "pay-7 Fix the totals"))
        #expect(await model.ticketStatus(of: "PAY-99", projectID: rig.projectID) == .free(key: "PAY-99"))
        #expect(await model.ticketStatus(of: "OPS-3", projectID: rig.projectID) == .free(key: "OPS-3"), "another project's session does not count")
        #expect(await model.ticketStatus(of: "no key here", projectID: rig.projectID) == .none)
        #expect(await model.ticketStatus(of: "PAY-418", projectID: nil) == .free(key: "PAY-418"), "no project, no lookup")
    }

    @Test func aTicketWithASessionOffersOpenInsteadOfACopyAndStartAnywayIsTheUsersCall() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        let existing = ManagedSession(provider: .claude, workingDirectory: root.appendingPathComponent("api").path)
        try await rig.catalog.insertSession(existing, title: "Reverse-charge note", projectID: rig.projectID, ticketKey: "PAY-418")

        model.showDraft(projectID: rig.projectID)
        model.setDraftText("PAY-418 add the note", projectID: rig.projectID)
        #expect(await waitUntil { model.newSession.ticketStatus(for: rig.projectID).key == "PAY-418" })
        #expect(await waitUntil { if case .exists = model.newSession.ticketStatus(for: rig.projectID) { true } else { false } })
        #expect(!model.canSendDraft(projectID: rig.projectID), "the line offers Open instead of a copy")
        model.sendDraft(projectID: rig.projectID)
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.intents.sends.isEmpty && !model.newSession.isSending(rig.projectID), "nothing started, nothing stuck")

        model.allowDuplicateTicket(projectID: rig.projectID)
        #expect(model.canSendDraft(projectID: rig.projectID))
        // Changing the ticket in the text takes the permission back (once the typing pauses: the key is looked
        // for in the debounced task, not on the keystroke).
        model.setDraftText("PAY-419 add the note", projectID: rig.projectID)
        #expect(await waitUntil { model.newSession.draft(for: rig.projectID)?.allowDuplicateTicket == false })
        model.setDraftText("PAY-418 add the note", projectID: rig.projectID)
        #expect(await waitUntil { if case .exists = model.newSession.ticketStatus(for: rig.projectID) { true } else { false } })
        model.allowDuplicateTicket(projectID: rig.projectID)
        model.sendDraft(projectID: rig.projectID)
        #expect(await waitUntil { !rig.intents.sends.isEmpty })
        #expect(rig.intents.sends[0].launch.ticketKey == "PAY-418")

        // Open: shows the session the ticket has.
        model.openExistingTicketSession(projectID: rig.projectID)
        #expect(model.destination == .session(existing.id))
    }

    @Test func aSecondSessionAllowedForOneTicketIsNotAllowedForAnotherTypedJustBeforeTheSend() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        let folder = root.appendingPathComponent("api").path
        for key in ["PAY-418", "PAY-500"] {
            try await rig.catalog.insertSession(
                ManagedSession(provider: .claude, workingDirectory: folder), title: "Done \(key)", projectID: rig.projectID, ticketKey: key)
        }
        model.showDraft(projectID: rig.projectID)
        model.setDraftText("PAY-418 add the note", projectID: rig.projectID)
        #expect(await waitUntil { model.newSession.ticketStatus(for: rig.projectID).key == "PAY-418" })
        #expect(await waitUntil { if case .exists = model.newSession.ticketStatus(for: rig.projectID) { true } else { false } })
        model.allowDuplicateTicket(projectID: rig.projectID)

        // The text now names another ticket that has a session; the line has not caught up, and ↵ is pressed.
        model.setDraftText("PAY-500 add the note", projectID: rig.projectID)
        model.sendDraft(projectID: rig.projectID)
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.intents.sends.isEmpty, "the permission was for PAY-418, not for PAY-500")
        #expect(await waitUntil { model.newSession.draft(for: rig.projectID)?.allowDuplicateTicket == false })
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
            let firstScan = model.newSession.ticketScans
            text = String(repeating: "word ", count: size / 5)
            model.setDraftText(text, projectID: id)
            #expect(await waitUntil { model.newSession.ticketScans == firstScan + 1 })
            model.newSession.flush()
            let scans = model.newSession.ticketScans
            let snapshots = store.snapshotsBuilt
            let writes = store.writeCount

            let began = ContinuousClock.now
            for _ in 0..<50 {
                text += "x"
                model.setDraftText(text, projectID: id)
            }
            let spent = ContinuousClock.now - began
            #expect(model.newSession.ticketScans == scans, "no keystroke looks for a ticket key (\(size) bytes)")
            #expect(store.snapshotsBuilt == snapshots, "no keystroke builds the saved form of the drafts (\(size) bytes)")
            #expect(store.writeCount == writes, "and none writes (\(size) bytes)")
            // Loose guard against a pass over the text that grows with it, not a measurement.
            #expect(spent < .seconds(2), "50 keystrokes took \(spent) at \(size) bytes")

            // The pause does the work once: one look at the text, one saved form, one write.
            #expect(await waitUntil { model.newSession.ticketScans == scans + 1 })
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
        #expect(NewSessionBranchNames.suggest(ticket: "PAY-418", text: "\nPAY-418 add the note\nsecond line about other things")
            == "feat/PAY-418-add-the-note")
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

    @Test func theFirstSendHandsTheRuntimeTheMessageTheResolvedChoicesTheTitleAndTheStripsBranch() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        await openDraft(model, rig.projectID)
        model.setDraftText("  PAY-418 Add the reverse-charge note\nThe wording is in the ticket.  ", projectID: rig.projectID)
        model.setDraftMode(.value("plan"), projectID: rig.projectID)
        model.setDraftModel(.value("haiku"), projectID: rig.projectID)
        model.setDraftBranch(.newBranch, projectID: rig.projectID)
        #expect(await waitUntil { model.newSession.ticketStatus(for: rig.projectID).key == "PAY-418" })
        #expect(model.canSendDraft(projectID: rig.projectID))

        model.sendDraft(projectID: rig.projectID)
        #expect(model.newSession.isSending(rig.projectID), "a second ↵ does nothing while the first is under way")
        #expect(!model.canSendDraft(projectID: rig.projectID))
        #expect(await waitUntil { !rig.intents.sends.isEmpty })
        let sent = try #require(rig.intents.sends.first)
        #expect(rig.intents.sends.count == 1 && rig.intents.plainStarts == 0)
        #expect(sent.projectID == rig.projectID && sent.focus == .session)
        #expect(sent.launch.firstMessage == "PAY-418 Add the reverse-charge note\nThe wording is in the ticket.")
        #expect(sent.launch.ticketKey == "PAY-418" && sent.launch.title == "PAY-418 Add the reverse-charge note")
        #expect(sent.launch.choices == ClaudeLaunchChoices(permissionMode: "plan", model: "haiku"))
        #expect(sent.launch.workspace == .newBranch("feat/PAY-418-add-the-reverse-charge"))
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
        #expect(plain.workspace == .projectFolder && plain.title == nil && plain.ticketKey == nil && plain.choices.isEmpty)
        rig.intents.sends[0].outcome(.failed)

        model.setDraftBranch(.newWorktree, name: "feat/mine", projectID: rig.projectID)
        model.sendDraft(projectID: rig.projectID)
        #expect(await waitUntil { rig.intents.sends.count == 2 })
        #expect(rig.intents.sends[1].launch.workspace == .newWorktree("feat/mine"))
        // Without a ticket the suggestion is made from the first words.
        #expect(NewSessionBranchNames.suggest(ticket: nil, text: "Fix the flaky test in billing, please") == "loom/fix-the-flaky-test")
        #expect(NewSessionBranchNames.suggest(ticket: "PAY-418", text: "PAY-418 İşlem düzeltme") == "feat/PAY-418-islem-duzeltme")
        #expect(NewSessionBranchNames.suggest(ticket: nil, text: "???", now: Date(timeIntervalSince1970: 0)).hasPrefix("loom/session-"))
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
        for good in ["feat/PAY-418-x", "loom/a", "a.b"] { #expect(NewSessionBranchNames.isPlausible(good)) }
        for bad in ["", "-x", "a b", "a..b", "x~1", "x^", "a:b", "a?", "a*", "a[", "a\\b", "a/", "/a", "a.lock", "a.", "a//b", "a@{b"] {
            #expect(!NewSessionBranchNames.isPlausible(bad), "\(bad)")
        }
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

        // The start failed: the text comes back, in front of what was typed meanwhile.
        model.setDraftText("second idea", projectID: rig.projectID)
        sent.outcome(.failed)
        #expect(model.newSession.draft(for: rig.projectID)?.text == "first idea\n\nsecond idea")
        // And into an empty slot as it was.
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
        // S2: the CLI restores neither, so a resume passes what the session started with.
        #expect(model.newSession.launchChoices(for: session) == ClaudeLaunchChoices(permissionMode: "plan"))
        #expect(model.newSession.launchChoices(for: UUID()) == nil)
        let again = NewSessionState()
        again.attach(store: NewSessionStore(url: rig.storeURL))
        #expect(again.launchChoices(for: session) == ClaudeLaunchChoices(permissionMode: "plan"))
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

    @Test func returnSendsCommandReturnOpensAFreshDraftShiftReturnIsANewLineAndAnInputMethodIsLeftAlone() throws {
        var sends = 0, fresh = 0
        let host = NewSessionTextView(
            text: .constant(""), height: .constant(60), isEditable: true,
            onSend: { sends += 1 }, onSendAndOpenFresh: { fresh += 1 }, onBlur: {})
        let coordinator = host.makeCoordinator()
        let view = NewSessionTextView.ComposerTextView()
        view.coordinator = coordinator
        coordinator.textView = view
        func press(_ modifiers: NSEvent.ModifierFlags, code: UInt16 = 36, repeating: Bool = false) throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeating, keyCode: code))
            view.keyDown(with: event)
        }
        try press([])
        #expect(sends == 1 && fresh == 0)
        try press([], code: 76)
        #expect(sends == 2, "the keypad's Enter too")
        try press([.command])
        #expect(sends == 2 && fresh == 1)
        try press([], repeating: true)
        try press([.command], repeating: true)
        #expect(sends == 2 && fresh == 1, "a held key never sends twice")
        view.string = "ab"
        view.setSelectedRange(NSRange(location: 1, length: 0))
        try press([.shift])
        #expect(view.string == "a\nb" && sends == 2, "Shift-Return is a new line")
        try press([.option])
        #expect(view.string == "a\n\nb")
        // While an input method composes, Return belongs to it.
        view.setMarkedText("ö", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        try press([])
        #expect(sends == 2)
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
