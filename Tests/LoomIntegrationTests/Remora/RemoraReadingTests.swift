import Foundation
import Testing
@testable import LoomCore
@testable import LoomRemora
import LoomTestSupport

/// L3a2 (item 3): what a call reads is told once its pack is built and before the model is asked. No real Claude: the fake
/// provider's Remora mode over a temporary data root.
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct RemoraReadingTests {
    @MainActor
    private final class Events {
        var items: [String] = []
        var readings: [RemoraReading] = []
    }

    /// A project note, so the pack has one to count.
    private func seedNote(_ rig: RemoraHostRig) async throws {
        let seed = try RemoraMemory(directory: rig.remora, timeZone: rig.zone, clock: { [clock = rig.clock] in clock.now })
        try await seed.replaceNote(project: rig.project, items: [RemoraNoteItem(text: "Waits on review", sessions: [rig.session])])
    }

    @Test func theCountsComeAfterThePackAndBeforeAnyTextAndNameTheScopedProject() async throws {
        let rig = try RemoraHostRig()
        try await seedNote(rig)
        let host = rig.makeHost(script: ["LOOM_FAKE_REMORA": "slow"], withTranscript: true)
        let events = Events()
        rig.forgetProcesses()
        let running = Task {
            await host.ask("What moved?", scope: .project(rig.project),
                           onReading: { events.items.append("reading"); events.readings.append($0) },
                           onText: { _ in events.items.append("text") })
        }
        // The child is running (a slow answer, 400 ms between deltas) and the counts are already there.
        _ = try #require(await rig.pid())
        #expect(events.readings == [RemoraReading(sessions: 1, projectNotes: 1, project: .init(id: rig.project, name: "loom"))])
        guard case .answered = await running.value else { Issue.record("the call did not finish"); await rig.finish(); return }
        #expect(events.items.first == "reading" && events.items.filter { $0 == "reading" }.count == 1)
        await rig.finish()
    }

    @Test func anAllProjectsQuestionAndABriefCarryNoProjectAndASessionScopeCarriesItsProject() async throws {
        let rig = try RemoraHostRig()
        try await seedNote(rig)
        let host = rig.makeHost(withTranscript: true)
        let events = Events()
        _ = await host.ask("What moved?", onReading: { events.readings.append($0) })
        _ = await host.ask("About this one?", scope: .session(rig.session), onReading: { events.readings.append($0) })
        _ = await host.brief(onReading: { events.readings.append($0) })
        let moved = RemoraReading(sessions: 1, projectNotes: 1, project: nil)
        #expect(events.readings == [moved, RemoraReading(sessions: 1, projectNotes: 1, project: .init(id: rig.project, name: "loom")), moved])
        await rig.finish()
    }

    @Test func aRememberOrderMakesNoPackAndReportsNothing() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost()
        let events = Events()
        guard case .remembered = await host.ask("Remember that I prefer tabs", onReading: { events.readings.append($0) }) else {
            Issue.record("not remembered"); await rig.finish(); return
        }
        #expect(events.readings.isEmpty)
        await rig.finish()
    }
}
