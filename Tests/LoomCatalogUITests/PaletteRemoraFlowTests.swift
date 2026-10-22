import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomRemora
@testable import LoomCatalogUI

/// L3c, part A: Ask Remora in the ⌘K palette over a real model and a Remora host whose call is the fake provider (no Claude, no
/// profile, no vault). The row heads the list only for a question with Remora on; ↵ makes one call and the answer takes the list's
/// place with its chips; a chip opens its session; ⌘↵ leaves the answer on Home as the Earlier line; Esc stops a call in flight
/// before the palette closes; while Remora answers something else ↵ asks nothing.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PaletteRemoraFlowTests {
    private let question = "which session touched the billing webhook?"

    /// Two projects with a session each; the fake answers with a chip on the first session (the pack lists it by its id).
    private func make(mode: String? = nil, preferences: RemoraPreferences = RemoraPreferences(briefMode: .whenIAsk)) async throws -> RemoraHomeRig {
        try await RemoraHomeRig.make(
            projectNames: ["loom", "api"],
            seeds: [.init(title: "Billing webhook", project: 0, ago: 3_600), .init(title: "Rate limiter", project: 1, ago: 7_200)],
            preferences: preferences,
            scriptFor: { sessions in
                let id = sessions[0].uuidString
                var script = ["LOOM_FAKE_REMORA_ANSWER": "Billing webhook did, an hour ago.\n\n```remora\n{\"cited\":[\"\(id)\"],\"chips\":[{\"session\":\"\(id)\",\"why\":\"Touched the webhook\"}],\"drafts\":[],\"facts\":[]}\n```\n"]
                if let mode { script["LOOM_FAKE_REMORA"] = mode }
                return script
            })
    }

    private func waitUntil(_ seconds: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return condition()
    }

    private func open(_ rig: RemoraHomeRig, _ text: String) -> PaletteState {
        let palette = rig.model.palette
        palette.windowProvider = { nil }
        palette.open(on: rig.model)
        palette.setQuery(text)
        return palette
    }

    // MARK: The row

    @Test func aQuestionPutsAskRemoraFirstAndASearchTermDoesNot() async throws {
        let rig = try await make()
        defer { Task { await rig.finish() } }
        let palette = open(rig, question)
        defer { palette.close() }
        #expect(palette.groups.first?.title == "Remora" && palette.groups.first?.items.map(\.id) == ["ask-remora"])
        #expect(palette.selectedID == "ask-remora", "it heads the list and has the cursor")
        #expect(palette.groups.dropFirst().allSatisfy { $0.section != .remora }, "the palette's own results follow")
        palette.setQuery("billing webhook")
        #expect(!palette.groups.contains { $0.section == .remora })
        #expect(palette.handleRemoraKey(.tab) == false, "⇥ is the palette's own without the row")
        #expect(!rig.ranAProcess, "typing calls nothing")
    }

    @Test func withRemoraOffThereIsNoRow() async throws {
        var off = RemoraPreferences(briefMode: .whenIAsk)
        off.isOn = false
        let rig = try await make(preferences: off)
        defer { Task { await rig.finish() } }
        let palette = open(rig, question)
        defer { palette.close() }
        #expect(!palette.groups.contains { $0.section == .remora })
        #expect(palette.handleRemoraKey(.return) == false && palette.handleRemoraKey(.tab) == false)
        #expect(palette.remoraFacts["offered"] as? Bool == false)
    }

    @Test func tabNarrowsTheScopeToTheSessionsProjectThenTheSession() async throws {
        let rig = try await make()
        defer { Task { await rig.finish() } }
        rig.model.select(rig.sessions[0])
        _ = await waitUntil { rig.model.selectedSessionID == rig.sessions[0] }
        let palette = open(rig, question)
        defer { palette.close() }
        let loom = rig.projects[0].name
        #expect(palette.remoraScopes.map(\.label) == ["All projects", loom, "This session"], "an ended session offers This session")
        var labels: [String] = [palette.remoraScope.label]
        for _ in 0..<3 {
            #expect(palette.handleRemoraKey(.tab))
            labels.append(palette.remoraScope.label)
        }
        #expect(labels == ["All projects", loom, "This session", "All projects"])
        // An excluded project is not offered, nor its session.
        rig.model.setRemoraExcluded(rig.projects[0].id, true)
        #expect(palette.remoraScopes.map(\.label) == ["All projects"])
    }

    // MARK: Asking

    @Test func returnAsksOnceTheAnswerShowsWithItsChipAndTheChipOpensTheSession() async throws {
        let rig = try await make()
        defer { Task { await rig.finish() } }
        let palette = open(rig, question)
        #expect(palette.handleRemoraKey(.return))
        #expect(palette.remoraAsked?.question == question && palette.remoraAsked?.scope == .allProjects)
        #expect(rig.model.remora.phase == .asking)
        await rig.model.remora.settle()
        #expect(rig.model.remora.lastAnswer?.question == question)
        // The view reads the chips' sessions once the answer is in; here the test reads them as the view would.
        await palette.remoraReads?.read(model: rig.model)
        #expect(palette.remoraChips.map(\.id) == [rig.sessions[0]], "the answer's chip is the session it names")
        #expect(palette.remoraFacts["phase"] as? String == "answered")
        #expect(rig.model.remora.usage?.today.questions == 1, "one call")
        // ↵ over the answer opens the chip's session and closes the palette.
        #expect(palette.handleRemoraKey(.return))
        #expect(!palette.isOpen && rig.model.selectedSessionID == rig.sessions[0])
    }

    @Test func commandReturnLeavesTheAnswerOnHomeAsTheEarlierLine() async throws {
        enableAccessibilityTree()
        let rig = try await make()
        defer { Task { await rig.finish() } }
        let palette = open(rig, question)
        #expect(palette.handleRemoraKey(.return))
        #expect(palette.handleRemoraKey(.commandReturn), "taken while the call runs")
        #expect(palette.isOpen, "but Home takes an answer that has ended")
        await rig.model.remora.settle()
        #expect(palette.handleRemoraKey(.commandReturn))
        #expect(!palette.isOpen && rig.model.destination == .home && palette.homeEarlier?.question == question)

        let hosting = NSHostingController(rootView: HomeView(model: rig.model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let shown = await waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return accessibilityElements(in: hosting.view).contains { $0.accessibilityIdentifier?() == "home-remora-earlier" }
        }
        #expect(shown, "Home's field shows the question as its Earlier line")
        #expect(palette.homeEarlier == nil, "Home took it")
    }

    @Test func escapeStopsTheCallInFlightBeforeThePaletteCloses() async throws {
        let rig = try await make(mode: "slow")
        defer { Task { await rig.finish() } }
        let palette = open(rig, question)
        #expect(palette.handleRemoraKey(.return))
        #expect(await waitUntil { !rig.model.remora.streamedText.isEmpty || rig.model.remora.reading != nil })
        #expect(palette.remoraFacts["phase"] as? String == "working")
        #expect(palette.handleRemoraKey(.escape))
        #expect(!palette.isOpen)
        await rig.model.remora.settle()
        #expect(rig.model.remora.stopped == .question && rig.model.remora.phase == .idle, "the call was stopped, not left running")
    }

    @Test func whileRemoraAnswersSomethingElseTheRowSaysSoAndReturnAsksNothing() async throws {
        let rig = try await make(mode: "slow")
        defer { Task { await rig.finish() } }
        #expect(rig.model.askRemora("what moved in api today?"))
        let palette = open(rig, question)
        defer { palette.close() }
        #expect(palette.remoraBusy && palette.groups.first?.section == .remora)
        #expect(palette.handleRemoraKey(.return), "the key is taken")
        #expect(palette.remoraAsked == nil, "and nothing is asked")
        rig.model.stopRemora()
        await rig.model.remora.settle()
        #expect(rig.model.remora.usage?.today.questions ?? 0 <= 1)
    }

    @Test func whileADraftIsReadingTheRowSaysSoAndReturnAsksNothing() async throws {
        let rig = try await make()
        defer { Task { await rig.finish() } }
        // Draft Brief's call (the new-session page) keeps its own state, not `phase`: the palette's row is busy all the same.
        rig.model.remora.draft = .reading(project: UUID(), reading: nil)
        let palette = open(rig, question)
        defer { palette.close() }
        #expect(palette.remoraBusy && palette.groups.first?.section == .remora)
        #expect(palette.handleRemoraKey(.return), "the key is taken")
        #expect(palette.remoraAsked == nil && rig.model.remora.phase == .idle, "and nothing is asked")
        rig.model.remora.draft = .idle
    }
}
