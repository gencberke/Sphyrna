import Foundation
import Testing
@testable import LoomRemora

/// L3a: Remora's settings, their one set of defaults (LOMBOT §6.2) and the lenient decoding the preferences file relies on.
struct RemoraPreferencesTests {
    private func decode(_ json: String) throws -> RemoraPreferences {
        try JSONDecoder().decode(RemoraPreferences.self, from: Data(json.utf8))
    }

    @Test func theDefaultsAreTheUsersInstallAndOneSetOfValues() throws {
        let defaults = RemoraPreferences()
        #expect(defaults.isOn)
        #expect(defaults.model == "sonnet" && defaults.effort == "low")
        #expect(defaults.briefMode == .automatic)
        #expect(defaults.excludedProjects.isEmpty)
        #expect(defaults.proposals)
        #expect(defaults.windowThreshold == 0.10)
        #expect(defaults.noteFilePath == nil)
        // Decoding nothing, and decoding what is unusable, give the same defaults: no second copy of them.
        #expect(try decode("{}") == defaults)
        #expect(try decode(#"{"isOn":"yes","model":3,"effort":"","briefMode":"sometimes","excludedProjects":"x","proposals":2,"windowThreshold":"a","noteFilePath":7}"#) == defaults)
        // The note is under the data folder, never in a vault.
        let folder = URL(fileURLWithPath: "/tmp/loom-data/remora")
        #expect(defaults.noteURL(defaultIn: folder) == folder.appendingPathComponent("Remora.md"))
    }

    @Test func aValueSurvivesTheRoundTripAndABadFieldFallsBackAloneOnTheRest() throws {
        let project = UUID()
        let custom = RemoraPreferences(isOn: false, model: "haiku", effort: "high", briefMode: .whenIAsk, excludedProjects: [project],
                                       proposals: false, windowThreshold: 0.25, noteFilePath: "/tmp/notes/Remora.md")
        let data = try JSONEncoder().encode(custom)
        #expect(try JSONDecoder().decode(RemoraPreferences.self, from: data) == custom)
        let partial = try decode(#"{"model":"haiku","briefMode":"later","windowThreshold":"x","excludedProjects":["\#(project.uuidString)","nope"]}"#)
        #expect(partial.model == "haiku" && partial.briefMode == .automatic && partial.windowThreshold == 0.10)
        #expect(partial.excludedProjects == [project])
        #expect(partial.isOn && partial.proposals)
    }

    @Test func theThresholdIsClampedAndOnlyAnAbsolutePathCountsForTheNote() throws {
        #expect(RemoraPreferences(windowThreshold: 7).windowThreshold == 1)
        #expect(RemoraPreferences(windowThreshold: -1).windowThreshold == 0)
        #expect(RemoraPreferences(windowThreshold: .nan).windowThreshold == 0.10)
        #expect(RemoraPreferences(noteFilePath: "relative/Remora.md").noteFilePath == nil)
        #expect(RemoraPreferences(noteFilePath: "  ").noteFilePath == nil)
        #expect(RemoraPreferences(noteFilePath: "/tmp/a/Remora.md").noteURL(defaultIn: URL(fileURLWithPath: "/x")).path == "/tmp/a/Remora.md")
    }
}
