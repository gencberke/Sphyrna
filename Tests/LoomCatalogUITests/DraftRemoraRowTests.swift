import Foundation
import Testing
import LoomCore
@testable import LoomRemora
@testable import LoomCatalogUI

/// L3c B, Remora's brief on the new-session page (DESIGN §8 "Remora's brief", D-80) as plain values: when the row is there, its
/// states and their exact words, the line above the composer, and Put in Draft's rule for the draft's composer. No view; the model
/// tests use a host whose calls nobody makes, so no process starts and nothing is sent.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct DraftRemoraRowTests {
    private let project = UUID()
    private let other = UUID()
    private let utc = TimeZone(identifier: "UTC")!
    private let draftedAt = Date(timeIntervalSince1970: 1_792_660_320) // 2026-10-22 09:12 UTC

    private func facts(_ change: (inout DraftRemoraRow.Facts) -> Void = { _ in }) -> DraftRemoraRow.Facts {
        var facts = DraftRemoraRow.Facts(hasHost: true, isOn: true, excluded: false, sessionCount: 3, projectID: project,
                                         projectName: "loom", draft: .idle, remoraBusy: false, origin: nil, slotHasText: false, zone: utc)
        change(&facts)
        return facts
    }

    private func origin(_ result: RemoraDraftResult = .placed, project: UUID? = nil, sessionsRead: Int = 3,
                        duration: TimeInterval? = 6.2) -> DraftRemoraOrigin {
        DraftRemoraOrigin(project: project ?? self.project, draftedAt: draftedAt, sessionsRead: sessionsRead, citedSessionIDs: [UUID()],
                          result: result, placedText: result == .placed ? "The goal is a clean importer." : nil, duration: duration)
    }

    // MARK: The row's presence

    @Test func theRowIsThereWithRemoraOnForAProjectWithASessionThatIsNotExcluded() throws {
        let row = try #require(DraftRemoraRow.make(facts()))
        #expect(row.phase == .offer)
        #expect(row.text == "Remora can write this session's brief from loom's recent work.")
        #expect(row.action == .draft && row.actionTitle == "Draft Brief" && row.actionEnabled)
        #expect(!row.showsSpinner && row.time == nil && !row.showsSources)

        #expect(DraftRemoraRow.make(facts { $0.isOn = false }) == nil, "Remora off")
        #expect(DraftRemoraRow.make(facts { $0.hasHost = false }) == nil, "no host")
        #expect(DraftRemoraRow.make(facts { $0.excluded = true }) == nil, "an excluded project")
        #expect(DraftRemoraRow.make(facts { $0.sessionCount = 0 }) == nil, "before the project's first session")
        #expect(DraftRemoraRow.make(facts { $0.projectID = nil }) == nil, "a draft with no project")
        // Off, excluded or with no session, even a drafted brief has no row.
        #expect(DraftRemoraRow.make(facts { $0.isOn = false; $0.origin = origin(); $0.slotHasText = true }) == nil)
    }

    // MARK: Its states and words

    @Test func readingSaysWhatItReadsWithTheSpinnerAndStop() throws {
        let reading = RemoraReading(sessions: 3, projectNotes: 1, project: .init(id: project, name: "loom"))
        let row = try #require(DraftRemoraRow.make(facts { $0.draft = .reading(project: project, reading: reading) }))
        #expect(row.phase == .reading && row.text == "Reading 3 sessions in loom and its note\u{2026}")
        #expect(row.showsSpinner && row.action == .stop && row.actionTitle == "Stop" && row.actionEnabled)
        // A reading without the project's name gets the page's; one session and no note; before the pack is built.
        let unnamed = RemoraReading(sessions: 1, projectNotes: 0, project: nil)
        #expect(DraftRemoraRow.make(facts { $0.draft = .reading(project: project, reading: unnamed) })?.text
            == "Reading 1 session in loom\u{2026}")
        #expect(DraftRemoraRow.make(facts { $0.draft = .reading(project: project, reading: nil) })?.text
            == "Reading the sessions in loom\u{2026}")
    }

    @Test func whileAnotherRemoraCallRunsDraftBriefDoesNothing() throws {
        // Home's question or brief (or ⌘K's) runs.
        let busy = try #require(DraftRemoraRow.make(facts { $0.remoraBusy = true }))
        #expect(busy.phase == .busy && !busy.actionEnabled && busy.actionTitle == "Draft Brief")
        #expect(busy.text == "Remora is busy with another call. Draft Brief waits until it ends.")
        // Another project's draft runs: this page only waits.
        let elsewhere = try #require(DraftRemoraRow.make(facts { $0.draft = .reading(project: other, reading: nil) }))
        #expect(elsewhere.phase == .busy && !elsewhere.actionEnabled)
        // Draft Again, Draft Brief after a failure and after Stop wait too.
        #expect(DraftRemoraRow.make(facts { $0.remoraBusy = true; $0.origin = origin(); $0.slotHasText = true })?.actionEnabled == false)
        #expect(DraftRemoraRow.make(facts { $0.remoraBusy = true; $0.draft = .stopped(project: project) })?.actionEnabled == false)
    }

    @Test func draftedSaysNothingIsSentWithTheTimeAndDraftAgain() throws {
        let row = try #require(DraftRemoraRow.make(facts { $0.origin = origin(); $0.slotHasText = true }))
        #expect(row.phase == .drafted)
        #expect(row.text == "Remora drafted the brief above. Nothing is sent until you press \u{21B5}.")
        #expect(row.time == "6.2 s" && row.action == .draftAgain && row.actionTitle == "Draft Again" && row.actionEnabled)
        #expect(!row.showsSources, "a placed brief has Sources on the line above the composer")
        // Started from elsewhere (the evidence command): the time it answered.
        let untimed = try #require(DraftRemoraRow.make(facts { $0.origin = origin(duration: nil); $0.slotHasText = true }))
        #expect(untimed.time == LoomDateFormat.time24(draftedAt, zone: utc) && untimed.time?.contains("12") == true)
        // The composer emptied: the row offers Draft Brief again.
        #expect(DraftRemoraRow.make(facts { $0.origin = origin() })?.phase == .offer)
        // Another project's brief is not this page's.
        #expect(DraftRemoraRow.make(facts { $0.origin = origin(project: other); $0.slotHasText = true })?.phase == .offer)
    }

    @Test func aCopiedBriefSaysSoWithSourcesAndDraftAgain() throws {
        let row = try #require(DraftRemoraRow.make(facts { $0.origin = origin(.copiedHasDraft); $0.slotHasText = true }))
        #expect(row.phase == .copied && row.text == "Remora drafted the brief. The composer has text, so it was copied instead.")
        #expect(row.time == "6.2 s" && row.action == .draftAgain && row.showsSources)
    }

    @Test func failedAndStoppedSaySoAndOfferDraftBriefAgain() throws {
        let sentence = "Remora uses your Claude Code login. Log in with claude in a terminal."
        let failed = try #require(DraftRemoraRow.make(facts { $0.draft = .failed(project: project, failure: .notLoggedIn, sentence: sentence) }))
        #expect(failed.phase == .failed && failed.text == sentence && failed.actionTitle == "Draft Brief" && failed.actionEnabled)
        let stopped = try #require(DraftRemoraRow.make(facts { $0.draft = .stopped(project: project) }))
        #expect(stopped.phase == .stopped && stopped.text == "Stopped. Draft Brief writes the whole brief." && stopped.action == .draft)
        // A failure wins over the brief still in the composer, until the next click.
        #expect(DraftRemoraRow.make(facts {
            $0.draft = .failed(project: project, failure: .apiError, sentence: "Remora could not get an answer from Claude.")
            $0.origin = origin(); $0.slotHasText = true
        })?.text == "Remora could not get an answer from Claude.")
        // Another project's failure is not this page's.
        #expect(DraftRemoraRow.make(facts { $0.draft = .stopped(project: other) })?.phase == .offer)
    }

    // MARK: The line above the composer

    @Test func theOriginLineSaysWhereTheBriefCameFromWithSourcesAndClear() throws {
        let line = try #require(DraftRemoraOriginLine.make(origin: origin(), project: project, projectName: "loom", slotHasText: true))
        #expect(line.title == "Remora's draft" && line.detail == "from 3 sessions in loom \u{00B7} not sent")
        #expect(line.citedSessionIDs.count == 1 && line.sessionsRead == 3)
        #expect(DraftRemoraOriginLine.make(origin: origin(sessionsRead: 1), project: project, projectName: "loom", slotHasText: true)?.detail
            == "from 1 session in loom \u{00B7} not sent")
        #expect(DraftRemoraText.sources == "Sources" && DraftRemoraText.clear == "Clear")
        #expect(DraftRemoraText.sourcesFoot(sessionsRead: 3, duration: 6.2) == "3 sessions \u{00B7} 6.2 s")
        #expect(DraftRemoraText.sourcesFoot(sessionsRead: 1, duration: nil) == "1 session")
        // Only while the composer holds the placed brief, of this project.
        #expect(DraftRemoraOriginLine.make(origin: origin(.copiedHasDraft), project: project, projectName: "loom", slotHasText: true) == nil)
        #expect(DraftRemoraOriginLine.make(origin: origin(), project: project, projectName: "loom", slotHasText: false) == nil)
        #expect(DraftRemoraOriginLine.make(origin: origin(), project: other, projectName: "loom", slotHasText: true) == nil)
        #expect(DraftRemoraOriginLine.make(origin: nil, project: project, projectName: "loom", slotHasText: true) == nil)
    }

    @Test func theWordsSaySessionNeverConversation() {
        let words = [DraftRemoraText.offer(projectName: "loom"), DraftRemoraText.drafted, DraftRemoraText.copied, DraftRemoraText.busy,
                     DraftRemoraText.stopped, DraftRemoraText.originTitle, DraftRemoraText.reading(nil, projectName: "loom", project: project),
                     DraftRemoraText.originDetail(sessionsRead: 2, projectName: "loom")]
        #expect(words.allSatisfy { !$0.lowercased().contains("conversation") })
    }

    // MARK: Put in Draft for the draft's composer (on the model)

    private func rig() async throws -> RemoraHomeRig {
        try await RemoraHomeRig.make(projectNames: ["loom"], seeds: [.init(title: "Port the sidebar", project: 0, ago: 600)],
                                     preferences: RemoraPreferences(briefMode: .whenIAsk))
    }

    private func brief(_ rig: RemoraHomeRig, _ text: String, at offset: TimeInterval) -> RemoraModelState.DraftState {
        .drafted(RemoraDraftedBrief(project: rig.projects[0].id, text: text, citedSessionIDs: [rig.sessions[0]], sessionsRead: 3,
                                    draftedAt: rig.base.addingTimeInterval(offset)))
    }

    @Test func anEmptyComposerTakesTheBriefOnceAndAComposerWithTextKeepsItAndTheBriefIsCopied() async throws {
        let rig = try await rig()
        let model = rig.model
        let intents = NewSessionTests.DraftIntents()
        model.intents = intents
        let project = rig.projects[0].id
        var copied: [String] = []
        #expect(model.sessionCounts[project] == 1 && model.hasRemora)
        #expect(model.draftRemoraRow(projectID: project)?.phase == .offer)

        // Empty: the brief lands in the composer, unsent, with the line above it.
        model.noteRemoraDraftClick(projectID: project, at: rig.base.addingTimeInterval(-6.2))
        model.remora.draft = brief(rig, "The goal is a clean importer.", at: 0)
        #expect(model.landRemoraDraft(copy: { copied.append($0) }) == .placed)
        #expect(model.newSession.draft(for: project)?.text == "The goal is a clean importer." && copied.isEmpty)
        #expect(model.draftRemoraRow(projectID: project)?.phase == .drafted)
        #expect(model.draftRemoraRow(projectID: project)?.time == "6.2 s")
        let name = rig.projects[0].name
        #expect(model.draftRemoraOriginLine(projectID: project)?.detail == "from 3 sessions in \(name) \u{00B7} not sent")
        // It lands once.
        #expect(model.landRemoraDraft(copy: { copied.append($0) }) == nil)

        // Draft Again over Remora's untouched brief replaces it.
        model.remora.draft = brief(rig, "The goal is a faster importer.", at: 10)
        #expect(model.landRemoraDraft(copy: { copied.append($0) }) == .placed)
        #expect(model.newSession.draft(for: project)?.text == "The goal is a faster importer." && copied.isEmpty)

        // Edited, it is the user's text: kept, and the next brief is copied.
        model.setDraftText("The goal is a faster importer. And mine.", projectID: project)
        model.remora.draft = brief(rig, "Third brief.", at: 20)
        #expect(model.landRemoraDraft(copy: { copied.append($0) }) == .copiedHasDraft)
        #expect(model.newSession.draft(for: project)?.text == "The goal is a faster importer. And mine." && copied == ["Third brief."])
        #expect(model.draftRemoraRow(projectID: project)?.phase == .copied)
        #expect(model.draftRemoraOriginLine(projectID: project) == nil, "the composer's text is not Remora's")

        // The user's own words from the start: kept, the brief copied.
        model.setDraftText("", projectID: project)
        model.setDraftText("My own words", projectID: project)
        model.remora.draft = brief(rig, "Fourth brief.", at: 30)
        #expect(model.landRemoraDraft(copy: { copied.append($0) }) == .copiedHasDraft)
        #expect(model.newSession.draft(for: project)?.text == "My own words" && copied.last == "Fourth brief.")

        // Nothing was sent: no start asked of the runtime, no send under way, no process.
        #expect(intents.sends.isEmpty && intents.plainStarts == 0 && !model.newSession.isSending(project) && !rig.ranAProcess)
        await rig.finish()
    }

    @Test func clearAndAnEmptiedComposerTakeTheLineAwayAndTheRowOffersDraftBriefAgain() async throws {
        let rig = try await rig()
        let model = rig.model
        let project = rig.projects[0].id
        model.remora.draft = brief(rig, "The goal is a clean importer.", at: 0)
        #expect(model.landRemoraDraft(copy: { _ in Issue.record("an empty composer copies nothing") }) == .placed)
        #expect(model.draftRemoraOriginLine(projectID: project) != nil)
        model.clearRemoraDraft(projectID: project)
        #expect(model.newSession.draft(for: project)?.hasText == false && model.draftRemoraOriginLine(projectID: project) == nil)
        #expect(model.draftRemoraRow(projectID: project)?.phase == .offer)
        // Typing again is the user's own text: no line comes back.
        model.setDraftText("Something else", projectID: project)
        #expect(model.draftRemoraOriginLine(projectID: project) == nil && model.draftRemoraRow(projectID: project)?.phase == .offer)

        // Emptied by hand: the same.
        model.setDraftText("", projectID: project)
        model.remora.draft = brief(rig, "Again.", at: 5)
        #expect(model.landRemoraDraft(copy: { _ in }) == .placed)
        model.setDraftText("", projectID: project)
        #expect(model.newSession.remoraOrigins.isEmpty)
        await rig.finish()
    }

    @Test func theEvidenceCarriesThePhaseAndCountsAndNeverTheText() async throws {
        let rig = try await rig()
        let model = rig.model
        let project = rig.projects[0].id
        #expect(model.draftRemoraEvidence["phase"] as? String == "idle")
        model.remora.draft = .reading(project: project, reading: RemoraReading(sessions: 3, projectNotes: 1))
        #expect(model.draftRemoraEvidence["phase"] as? String == "reading" && model.draftRemoraEvidence["sessionsRead"] as? Int == 3)
        model.remora.draft = brief(rig, "A secret goal.", at: 0)
        model.landRemoraDraft(copy: { _ in })
        let summary = model.draftRemoraEvidence
        #expect(summary["phase"] as? String == "drafted" && summary["project"] as? String == project.uuidString)
        #expect(summary["sessionsRead"] as? Int == 3 && summary["cited"] as? Int == 1 && summary["landed"] as? String == "placed")
        #expect(!summary.values.contains { "\($0)".contains("secret") })
        await rig.finish()
    }
}
