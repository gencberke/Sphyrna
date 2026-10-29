import Foundation
import Testing
@testable import LoomCore
@testable import LoomRemora
import LoomTestSupport

/// L3a2 (item 6): the fake provider's Remora mode reads an optional script file from `$CLAUDE_CONFIG_DIR` (the app's evidence
/// runs set that variable, and Remora's call passes it on), fills its closing block with real session ids out of the pack, and
/// lets the `LOOM_FAKE_REMORA*` variables win.
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct RemoraFixtureScriptTests {
    /// A host whose child gets `CLAUDE_CONFIG_DIR` pointing at a folder with `remora-fixture.json` (when `json` is given).
    private func host(_ rig: RemoraHostRig, json: String?, script: [String: String] = [:]) throws -> RemoraHost {
        let config = rig.root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        if let json { try Data(json.utf8).write(to: config.appendingPathComponent("remora-fixture.json")) }
        var environment = ["CLAUDE_CONFIG_DIR": config.path]
        environment.merge(script) { _, new in new }
        return rig.makeHost(script: environment, withTranscript: true)
    }

    @Test func theScriptFilesTextAnswersWithChipsAndDraftsOnRealSessionIdsFromThePack() async throws {
        let rig = try RemoraHostRig()
        let json = #"{"answer":"The script says billing waits.","chips":["Waits for your review","Second"],"drafts":["Please run the checks."],"facts":["Prefers short answers"]}"#
        guard case let .answered(answer) = await (try host(rig, json: json)).ask("What moved?") else {
            Issue.record("no answer"); await rig.finish(); return
        }
        let id = rig.session.uuidString
        #expect(answer.answer.text == "The script says billing waits.")
        #expect(answer.answer.block == .valid)
        #expect(answer.answer.cited == [id])
        #expect(answer.answer.chips == [RemoraChip(sessionID: id, why: "Waits for your review")])
        #expect(answer.answer.drafts == [RemoraDraft(sessionID: id, text: "Please run the checks.")])
        #expect(answer.proposedFacts == ["Prefers short answers"])
        await rig.finish()
    }

    @Test func aScriptWithNoTextOrChipsStillShowsOneChipAndOneDraft() async throws {
        let rig = try RemoraHostRig()
        guard case let .answered(answer) = await (try host(rig, json: "{}")).brief() else {
            Issue.record("no answer"); await rig.finish(); return
        }
        #expect(answer.answer.chips.map(\.sessionID) == [rig.session.uuidString] && answer.answer.drafts.map(\.sessionID) == [rig.session.uuidString])
        #expect(!answer.answer.text.isEmpty)
        await rig.finish()
    }

    @Test func theScriptsModeAndDelayApply() async throws {
        let rig = try RemoraHostRig()
        guard case let .failed(failure) = await (try host(rig, json: #"{"mode":"login"}"#)).ask("What moved?") else {
            Issue.record("expected a failure"); await rig.finish(); return
        }
        #expect(failure.kind == .notLoggedIn)

        // 60 ms between deltas of 7 characters: the block alone is 40 deltas, over two seconds; the default 5 ms is far under.
        let slow = try host(rig, json: #"{"answer":"A short answer from the script.","delayMs":60}"#)
        let began = ContinuousClock.now
        guard case .answered = await slow.ask("What moved?") else { Issue.record("no answer"); await rig.finish(); return }
        #expect(ContinuousClock.now - began > .milliseconds(1_500), "the script's delay was not used")
        await rig.finish()
    }

    @Test func theEnvironmentVariablesWinOverTheFile() async throws {
        let rig = try RemoraHostRig()
        let json = #"{"answer":"From the file.","mode":"error","delayMs":900}"#
        // The answer variable carries its own block and the file's chips are not added to it; the mode variable beats the file's.
        let script = ["LOOM_FAKE_REMORA": "ok", "LOOM_FAKE_REMORA_ANSWER": "From the variable.", "LOOM_FAKE_REMORA_DELAY_MS": "0"]
        let began = ContinuousClock.now
        guard case let .answered(answer) = await (try host(rig, json: json, script: script)).ask("What moved?") else {
            Issue.record("the file's mode beat the variable"); await rig.finish(); return
        }
        #expect(answer.answer.text == "From the variable." && answer.answer.chips.isEmpty && answer.answer.block == .missing)
        #expect(ContinuousClock.now - began < .seconds(20))
        await rig.finish()
    }

    @Test func withoutAFileTheDefaultAnswerIsUnchanged() async throws {
        let rig = try RemoraHostRig()
        guard case let .answered(answer) = await (try host(rig, json: nil)).ask("What moved?") else {
            Issue.record("no answer"); await rig.finish(); return
        }
        #expect(answer.answer.text == "You left off in the loom project, where session s-one waits for your review.")
        #expect(answer.answer.chips.isEmpty, "the default block names s-one, which no pack has")
        // An unreadable file says nothing either.
        guard case let .answered(again) = await (try host(rig, json: "not json")).ask("What moved?") else {
            Issue.record("no answer"); await rig.finish(); return
        }
        #expect(again.answer.text == answer.answer.text)
        await rig.finish()
    }
}
