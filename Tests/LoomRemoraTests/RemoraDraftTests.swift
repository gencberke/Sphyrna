import Foundation
import Testing
@testable import LoomCore
@testable import LoomRemora
import LoomTestSupport

/// L3c: Draft Brief's call (the new-session page's door, D-80). Synthetic transcripts, the fake provider's Remora mode and a
/// capturing stand-in for `claude`; no real Claude, no real profile.
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct RemoraDraftTests {
    @MainActor
    private final class Readings {
        var items: [RemoraReading] = []
    }

    // MARK: The pack

    @Test func theDraftPackReadsOnlyItsProjectsRecentSessionsNewestFirstAndStaysUnderTheQuestionsBudget() async throws {
        let world = try RemoraPackWorld()
        defer { world.remove() }
        let alpha = (id: UUID(), name: "alpha")
        let beta = (id: UUID(), name: "beta")
        let older = try world.add(title: "A older", project: alpha, minutesAgo: 30, lines: RemoraPackWorld.conversation(turns: 1))
        let newer = try world.add(title: "A newer", project: alpha, minutesAgo: 5, lines: RemoraPackWorld.conversation(turns: 1))
        let other = try world.add(title: "BetaOnlyMarker", project: beta, minutesAgo: 1, lines: RemoraPackWorld.conversation(turns: 1))
        let pack = try await world.build(.draft(project: alpha.id))
        #expect(pack.readSessionIDs == [newer.id, older.id], "the project's sessions, newest first")
        #expect(pack.namedSessionIDs == [newer.id, older.id])
        #expect(!pack.text.contains("BetaOnlyMarker") && !pack.text.contains(other.id.uuidString), "another project's line is in the pack")
        #expect(pack.kind == .question && pack.request().kind == .question && pack.request().isDraft, "a draft runs as a question")
        // An excluded project gives an empty pack (and the host refuses before any pack).
        let excluded = try await world.build(.draft(project: alpha.id), settings: RemoraPackSettings(excludedProjects: [alpha.id]))
        #expect(excluded.readSessionIDs.isEmpty && excluded.text.contains("(no sessions)"))

        // The question's budget holds on a large project.
        let big = try RemoraPackWorld()
        defer { big.remove() }
        let project = (id: UUID(), name: "big")
        for index in 0..<30 {
            try big.add(title: "Session \(index)", project: project, minutesAgo: Double(index) * 20,
                        lines: RemoraPackWorld.conversation(turns: 120, width: 900, topic: "topic\(index)"))
        }
        let large = try await big.build(.draft(project: project.id))
        #expect(large.estimatedTokens <= RemoraPackLimits.standard.questionTokens)
        #expect(large.readSessionIDs.count >= 3 && large.readSessionIDs.count <= 8)
    }

    @Test func aDraftAndAProjectQuestionInTheSameStateShareTheStablePrefixAndTheSystemPrompt() async throws {
        let world = try RemoraPackWorld()
        defer { world.remove() }
        let alpha = (id: UUID(), name: "alpha")
        try world.add(title: "A one", project: alpha, minutesAgo: 10, lines: RemoraPackWorld.conversation(turns: 2))
        try world.add(title: "A two", project: alpha, minutesAgo: 3, lines: RemoraPackWorld.conversation(turns: 2))
        try world.add(title: "B one", project: (id: UUID(), name: "beta"), minutesAgo: 1, lines: RemoraPackWorld.conversation(turns: 2))
        let memory = RemoraMemoryShare(text: "Project alpha: the importer skips empty rows (as of 14 October).",
                                       recent: "- 15 Oct 09:00 asked: \"x\" | answered: \"y\"", projectNotes: 1)
        let question = try await world.build(.question("where does alpha stand?", scope: .project(alpha.id), previous: nil), memory: memory)
        let draft = try await world.build(.draft(project: alpha.id), memory: memory, at: 120)
        #expect(!draft.stablePrefix.isEmpty && draft.stablePrefix == question.stablePrefix)
        #expect(draft.request().systemSuffix == question.request().systemSuffix)
        #expect(draft.text.hasPrefix(draft.stablePrefix))
        // The draft's own words are in the dynamic tail, at the end, after <now>.
        let request = try #require(draft.text.range(of: "\n<request>\n"))
        #expect(draft.text.range(of: "\n<now>\n")!.lowerBound < request.lowerBound && draft.text.hasSuffix("</request>\n"))
        #expect(draft.afterStablePrefix.contains("Write the brief for my next session in alpha"))
        #expect(!draft.stablePrefix.contains("next session"))
    }

    // MARK: The rules

    @Test func theRulesAskForPlainParagraphsInTheFivePartsOrderCitingOnlyInTheBlockAndNeverActing() throws {
        let rules = RemoraRules.text
        let start = try #require(rules.range(of: "A session's brief"), "the rules have no section for Draft Brief")
        let section = String(rules[start.lowerBound...].prefix { $0 != "\n" })
        let parts = ["the goal", "where it stands", "the next step", "the files", "what to watch for"]
        let positions = parts.compactMap { section.range(of: $0)?.lowerBound }
        #expect(positions.count == parts.count && positions == positions.sorted(), "the five parts, in order")
        #expect(section.contains("plain paragraphs") && section.contains("no headings") && section.contains("no lists"))
        #expect(section.contains("language"))
        #expect(section.contains("\"cited\"") && section.contains("only ids the pack gave you"))
        #expect(section.contains("never asks to run, send or change anything"))
        // One section shared by every call: the system prompt does not depend on the call.
        #expect(!rules.contains("<request>\nWrite the brief"))
    }

    @Test func theDraftIsWrittenInTheLanguageOfTheProjectsRecentSessionsElseTheSettingsLanguage() async throws {
        let world = try RemoraPackWorld()
        defer { world.remove() }
        let turkish = (id: UUID(), name: "fatura")
        try world.add(title: "Fatura", project: turkish, minutesAgo: 5, lines: [
            RemoraPackWorld.user("Fatura aktarıcısındaki boş satır hatasını düzeltelim, lütfen testleri de çalıştır."),
            RemoraPackWorld.assistant("The importer now skips empty rows."),
            RemoraPackWorld.user("Şimdi dışa aktarma ekranındaki tarih biçimini de Türkçe yapalım."),
        ])
        let pack = try await world.build(.draft(project: turkish.id), settings: RemoraPackSettings(language: "en"))
        #expect(pack.afterStablePrefix.contains("Write the brief in Turkish (tr).\n</request>"), "the sessions' language wins")
        // Sessions whose language cannot be told: the Settings' brief language.
        let quiet = (id: UUID(), name: "quiet")
        try world.add(title: "Quiet", project: quiet, minutesAgo: 1, lines: [RemoraPackWorld.user("ok")])
        let fallback = try await world.build(.draft(project: quiet.id), settings: RemoraPackSettings(language: "de"))
        #expect(fallback.afterStablePrefix.contains("Write the brief in German (de).\n</request>"))
        let none = try await world.build(.draft(project: quiet.id))
        #expect(!none.afterStablePrefix.contains("Write the brief in "))
    }

    // MARK: Journal and usage

    @Test func aDraftsJournalLineIsAQuestionMarkedAsADraftAndItsUseIsCountedApart() throws {
        let zone = TimeZone(identifier: "Europe/Istanbul")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let session = UUID()
        let entry = RemoraJournalEntry.make(kind: .question, question: "Draft Brief", answerText: "Finish the importer. Then the export.",
                                            sessions: [session], model: "sonnet", tokens: 12, summary: nil, date: date, isDraft: true)
        let line = entry.line(timeZone: zone)
        #expect(line.contains(" question for=draft "))
        let parsed = try #require(RemoraJournalEntry(line: line, day: RemoraDay(date, calendar: calendar), calendar: calendar))
        #expect(parsed.isDraft && parsed.kind == .question && parsed.sessions == [session] && parsed.question == "Draft Brief")
        // A question's line is unchanged.
        let asked = RemoraJournalEntry.make(kind: .question, question: "What moved?", answerText: "A.", sessions: [], model: nil, tokens: 1,
                                            summary: nil, date: date)
        #expect(!asked.line(timeZone: zone).contains("for=") && RemoraJournalEntry(line: asked.line(timeZone: zone),
                                                                                    day: RemoraDay(date, calendar: calendar), calendar: calendar)?.isDraft == false)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("remora-draft-usage-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let usage = RemoraUsage(calendar: calendar, clock: { date }, persistedAt: file)
        usage.recordStart(.question, isDraft: true)
        usage.recordStart(.question)
        #expect(usage.today.drafts == 1 && usage.today.questions == 1 && usage.today.calls == 2)
        let reread = RemoraUsage(calendar: calendar, clock: { date }, persistedAt: file)
        #expect(reread.today.drafts == 1 && reread.today.questions == 1)
    }

    @Test func aDraftLineIsNotTheLastQuestionsLanguageAndFoldsAsADraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remora-draft-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = Date().addingTimeInterval(-20 * 86_400)
        let early = try RemoraMemory(directory: directory, clock: { old })
        try await early.appendJournal(.make(kind: .question, question: "Fatura aktarıcısı nerede kaldı, söyler misin?", answerText: "A.",
                                            sessions: [], model: nil, tokens: 1, summary: nil, date: old))
        try await early.appendJournal(.make(kind: .question, question: "Draft Brief", answerText: "Finish the importer.", sessions: [],
                                            model: nil, tokens: 1, summary: nil, date: old.addingTimeInterval(60), isDraft: true))
        #expect(await RemoraLanguage.ofLastQuestion(in: early) == "tr", "the draft's line was taken for the last question")
        let now = try RemoraMemory(directory: directory)
        #expect(await now.weeklySummaries().flatMap(\.lines).map(\.text) == ["1 question, 1 draft"])
    }

    // MARK: The host

    @Test func aDraftThroughTheHostAnswersJournalsAQuestionLineMarkedDraftAndCountsADraft() async throws {
        let rig = try RemoraHostRig()
        let answer = "The goal is a clean importer.\n\n```remora\n{\"cited\":[\"\(rig.session.uuidString)\"],\"chips\":[],\"drafts\":[],\"facts\":[]}\n```"
        let host = rig.makeHost(script: ["LOOM_FAKE_REMORA_ANSWER": answer])
        let readings = Readings()
        let outcome = await host.draft(project: rig.project, onReading: { readings.items.append($0) })
        guard case let .answered(hosted) = outcome else { Issue.record("not answered: \(outcome)"); await rig.finish(); return }
        #expect(hosted.answer.text == "The goal is a clean importer." && hosted.answer.cited == [rig.session.uuidString])
        #expect(readings.items == [RemoraReading(sessions: 0, projectNotes: 0, project: .init(id: rig.project, name: "loom"))])
        let line = try #require(await host.journal(on: rig.clock.now).last)
        #expect(line.kind == .question && line.isDraft && line.sessions == [rig.session])
        let use = try #require(await host.usage())
        #expect(use.today.drafts == 1 && use.today.questions == 0)
        await rig.finish()
    }

    @Test func theDraftReadsItsProjectsNoteAndNoOtherAndALaterDraftNoLongerReadsADeletedSessionsLine() async throws {
        let rig = try RemoraHostRig()
        let other = UUID()
        let seed = try RemoraMemory(directory: rig.remora, timeZone: rig.zone, clock: { rig.clock.now })
        try await seed.replaceNote(project: rig.project, items: [RemoraNoteItem(text: "LoomNoteMarker", sessions: [rig.session])])
        try await seed.replaceNote(project: other, items: [RemoraNoteItem(text: "OtherNoteMarker")])
        // The first draft answers and leaves its journal line, which cites the rig's session.
        let first = rig.makeHost(script: ["LOOM_FAKE_REMORA_ANSWER": "DeletedSessionMarker is the goal.\n\n```remora\n{\"cited\":[\"\(rig.session.uuidString)\"]}\n```"])
        guard case .answered = await first.draft(project: rig.project) else {
            Issue.record("the first draft did not answer")
            await rig.finish()
            return
        }
        // A relaunch with the capturing stand-in: the second draft reads the note and the line.
        let capturing = rig.makeHost(executable: try rig.captureExecutable())
        _ = await capturing.draft(project: rig.project)
        #expect(rig.capturedSystemPrompt().contains("LoomNoteMarker") && !rig.capturedSystemPrompt().contains("OtherNoteMarker"))
        #expect(rig.capturedStdin().contains("DeletedSessionMarker"))
        // The session is deleted: a later draft no longer reads the line that cited it.
        try await capturing.forgetter.forget(sessionID: rig.session, providerIDs: [])
        _ = await capturing.draft(project: rig.project)
        #expect(!rig.capturedStdin().contains("DeletedSessionMarker") && !rig.capturedSystemPrompt().contains("DeletedSessionMarker"))
        await rig.finish()
    }

    @Test func aDraftIsRefusedWhenOffWhileACallRunsForAnExcludedProjectAndForAProjectWithNoSession() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost(script: ["LOOM_FAKE_REMORA": "slow"])
        #expect(await host.canDraft(project: rig.project))
        #expect(!(await host.canDraft(project: UUID())), "a project with no session")
        let excluded = rig.makeHost(settings: RemoraPreferences(excludedProjects: [rig.project]))
        #expect(!(await excluded.canDraft(project: rig.project)))
        #expect(await excluded.draft(project: rig.project) == .off && !FileManager.default.fileExists(atPath: rig.pids.path))
        let off = rig.makeHost(settings: RemoraPreferences(isOn: false))
        #expect(!(await off.canDraft(project: rig.project)))
        let running = Task { await host.ask("What moved?") }
        for _ in 0..<500 where !host.isRunning { await Task.yield() }
        #expect(!(await host.canDraft(project: rig.project)), "another call runs")
        #expect(await host.draft(project: rig.project) == .busy)
        host.stop()
        _ = await running.value
        await rig.finish()
    }
}
