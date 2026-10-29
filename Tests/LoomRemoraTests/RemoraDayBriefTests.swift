import Foundation
import Testing
@testable import LoomCore
@testable import LoomRemora
import LoomTestSupport

/// L3a2 (item 4): the day's brief is kept in Remora's folder, read back on first use, and goes with the day, with a deleted
/// session, with a new exclusion and with Clear. No real Claude, no real profile, no vault: a temporary data root and the fake
/// provider's Remora mode.
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct RemoraDayBriefTests {
    /// A brief whose block cites, chips, drafts and proposes something, all on the rig's one session.
    private func briefAnswer(_ rig: RemoraHostRig, text: String = "Billing waits for your review.") -> String {
        let id = rig.session.uuidString
        return """
        \(text)

        ```remora
        {"cited":["\(id)"],"chips":[{"session":"\(id)","why":"Waits for review"}],"drafts":[{"session":"\(id)","text":"Run the checks again."}],"facts":["Prefers short answers"]}
        ```
        """
    }

    private func host(_ rig: RemoraHostRig, text: String = "Billing waits for your review.", settings: RemoraPreferences = RemoraPreferences(),
                      extra: [String: String] = [:]) -> RemoraHost {
        var script = ["LOOM_FAKE_REMORA_ANSWER": briefAnswer(rig, text: text)]
        script.merge(extra) { _, new in new }
        return rig.makeHost(script: script, settings: settings, withTranscript: true)
    }

    private func kept(_ rig: RemoraHostRig) throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: rig.keptBrief) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Written and read back

    @Test func anAutomaticBriefIsWrittenWith0600AndAFreshHostReadsItBackOnFirstUse() async throws {
        let rig = try RemoraHostRig()
        let first = host(rig)
        guard case .answered = await first.briefIfDue(homeShown: true, windowRemainingShare: 0.8) else {
            Issue.record("the brief did not run"); await rig.finish(); return
        }
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: rig.keptBrief.path)[.posixPermissions] as? Int)
        #expect(mode == 0o600)
        let stored = try #require(try kept(rig))
        #expect(stored["version"] as? Int == 1 && stored["startedAt"] as? Double == rig.clock.now.timeIntervalSince1970)

        // A relaunch: a second host and its first read.
        let id = rig.session.uuidString
        let again = rig.makeHost()
        let brief = try #require(await again.keptBrief())
        #expect(brief.text == "Billing waits for your review." && brief.startedAt == rig.clock.now)
        #expect(brief.cited == [id] && brief.chips == [RemoraChip(sessionID: id, why: "Waits for review")])
        #expect(brief.drafts == [RemoraDraft(sessionID: id, text: "Run the checks again.")])
        #expect(brief.proposedFacts == ["Prefers short answers"])
        #expect(brief.readSessionIDs == [rig.session] && brief.footer == "read 1 session and 0 project notes")
        await rig.finish()
    }

    @Test func aBriefTheUserAsksForIsKeptTooAndReplacesTheOneBefore() async throws {
        let rig = try RemoraHostRig()
        guard case .answered = await host(rig, text: "First.").briefIfDue(homeShown: true, windowRemainingShare: 1) else {
            Issue.record("no first brief"); await rig.finish(); return
        }
        rig.clock.now = rig.clock.now.addingTimeInterval(1_800)
        guard case .answered = await host(rig, text: "Second.").brief() else {
            Issue.record("the asked brief did not run"); await rig.finish(); return
        }
        let brief = try #require(await rig.makeHost().keptBrief())
        #expect(brief.text == "Second." && brief.startedAt == rig.clock.now)
        await rig.finish()
    }

    @Test func proposalsOffKeepsNoProposedFact() async throws {
        let rig = try RemoraHostRig()
        guard case .answered = await host(rig, settings: RemoraPreferences(proposals: false)).brief() else {
            Issue.record("no brief"); await rig.finish(); return
        }
        let brief = try #require(await rig.makeHost().keptBrief())
        #expect(brief.proposedFacts.isEmpty && brief.text == "Billing waits for your review.")
        await rig.finish()
    }

    @Test func aQuestionKeepsNothing() async throws {
        let rig = try RemoraHostRig()
        guard case .answered = await host(rig).ask("What moved?") else { Issue.record("no answer"); await rig.finish(); return }
        #expect(!FileManager.default.fileExists(atPath: rig.keptBrief.path))
        #expect(await rig.makeHost().keptBrief() == nil)
        await rig.finish()
    }

    // MARK: Read on first use, gone with the day

    @Test func theKeptBriefIsReadOnlyWhenAskedForAndALaterDayFindsNothingAndRemovesTheFile() async throws {
        let rig = try RemoraHostRig()
        guard case .answered = await host(rig).brief() else { Issue.record("no brief"); await rig.finish(); return }
        // Later the same day (11:00 to 14:00, the day began at 04:00): still there.
        rig.clock.now = rig.clock.now.addingTimeInterval(3 * 3_600)
        #expect(await rig.makeHost().keptBrief() != nil)
        #expect(FileManager.default.fileExists(atPath: rig.keptBrief.path))
        // The next day's 04:00 has passed: nothing, and the file is removed by that read.
        rig.clock.now = rig.clock.now.addingTimeInterval(22 * 3_600)
        let launched = rig.makeHost()
        #expect(FileManager.default.fileExists(atPath: rig.keptBrief.path), "making the host read the file")
        #expect(await launched.keptBrief() == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.keptBrief.path))
        await rig.finish()
    }

    @Test func aFileThisBuildCannotReadIsNoBriefAndIsLeftAlone() async throws {
        let rig = try RemoraHostRig()
        try FileManager.default.createDirectory(at: rig.remora, withIntermediateDirectories: true)
        try Data(#"{"version":99,"startedAt":1}"#.utf8).write(to: rig.keptBrief)
        #expect(await rig.makeHost().keptBrief() == nil)
        try Data("not json".utf8).write(to: rig.keptBrief)
        #expect(await rig.makeHost().keptBrief() == nil)
        #expect(FileManager.default.fileExists(atPath: rig.keptBrief.path), "an unreadable file was removed, not left for the next brief")
        await rig.finish()
    }

    // MARK: Failure keeps what was kept

    @Test func aFailedOrStoppedBriefKeepsTheEarlierOne() async throws {
        let rig = try RemoraHostRig()
        guard case .answered = await host(rig, text: "Kept.").brief() else { Issue.record("no brief"); await rig.finish(); return }
        let before = try Data(contentsOf: rig.keptBrief)

        rig.clock.now = rig.clock.now.addingTimeInterval(600)
        guard case let .failed(failure) = await rig.makeHost(script: ["LOOM_FAKE_REMORA": "error"], withTranscript: true).brief() else {
            Issue.record("expected a failure"); await rig.finish(); return
        }
        #expect(failure.kind == .apiError)
        #expect(try Data(contentsOf: rig.keptBrief) == before, "a failed brief changed the kept one")

        let slow = rig.makeHost(script: ["LOOM_FAKE_REMORA": "slow", "LOOM_FAKE_REMORA_ANSWER": briefAnswer(rig, text: "Never finished.")],
                                withTranscript: true)
        rig.forgetProcesses()
        let running = Task { await slow.brief() }
        let pid = try #require(await rig.pid())
        try await Task.sleep(for: .milliseconds(700))
        slow.stop()
        #expect(await running.value == .cancelled)
        #expect(await rig.gone(pid))
        #expect(try Data(contentsOf: rig.keptBrief) == before, "a stopped brief changed the kept one")
        #expect(await rig.makeHost().keptBrief()?.text == "Kept.")
        await rig.finish()
    }

    // MARK: Exclusion and Clear

    @Test func excludingAnotherProjectKeepsTheBriefAndExcludingItsProjectRemovesIt() async throws {
        let rig = try RemoraHostRig()
        let subject = host(rig)
        guard case .answered = await subject.brief() else { Issue.record("no brief"); await rig.finish(); return }
        // A project the brief never read: it stays.
        await subject.excludeProject(UUID())
        #expect(await subject.keptBrief() != nil)
        // Shrinking the exclusions is not growth: it stays.
        var smaller = subject.settings
        smaller.excludedProjects = []
        await subject.update(settings: smaller)
        #expect(await subject.keptBrief() != nil)
        // The project of a session the brief names: it goes, with its file.
        await subject.excludeProject(rig.project)
        #expect(await subject.keptBrief() == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.keptBrief.path))
        #expect(await rig.makeHost().keptBrief() == nil)
        await rig.finish()
    }

    @Test func clearingTheWorkingMemoryRemovesTheKeptBriefAndLeavesTheUseCounters() async throws {
        let rig = try RemoraHostRig()
        let subject = host(rig)
        guard case .answered = await subject.brief() else { Issue.record("no brief"); await rig.finish(); return }
        #expect(await subject.keptBrief() != nil)
        await subject.clearWorkingMemory()
        #expect(await subject.keptBrief() == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.keptBrief.path))
        #expect(await subject.usage()?.today.briefs == 1)
        await rig.finish()
    }

    @Test func everySessionABriefNamesIsOneItsDeletionOrExclusionLooksFor() {
        let (read, cited, chipped, drafted) = (UUID(), UUID(), UUID(), UUID())
        let brief = RemoraKeptBrief(
            startedAt: Date(), text: "x", cited: [cited.uuidString, "not-an-id"], chips: [RemoraChip(sessionID: chipped.uuidString, why: "w")],
            drafts: [RemoraDraft(sessionID: drafted.uuidString, text: "t")], readSessionIDs: [read])
        #expect(brief.sessionIDs == [read, cited, chipped, drafted])
    }

    @Test func clearingWithNoBriefOrNoFolderIsQuiet() async throws {
        let rig = try RemoraHostRig()
        let subject = rig.makeHost()
        await subject.clearWorkingMemory()
        #expect(await subject.keptBrief() == nil)
        await rig.finish()
    }
}
