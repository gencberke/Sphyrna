import Foundation
import Testing
@testable import LoomCore

/// C1: availability is a PATH lookup on the terminal environment, never a `--version` run: On, Off, or Not found (with the
/// switch disabled). The preference map is explicit and a harness absent from it takes its descriptor's `onWhenFound`.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HarnessAvailabilityTests {
    /// A folder holding executable stubs named `names`, and a PATH that holds it.
    private func path(with names: [String]) throws -> (folder: URL, environment: [String: String]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("loom-path-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            let file = folder.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return (folder, ["PATH": folder.path])
    }

    @Test func foundAndSwitchedOnIsOnAndFoundAndSwitchedOffIsOff() throws {
        let fixture = try path(with: ["claude", "codex"])
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let claude = try #require(HarnessCatalogue.descriptor(for: .claude))
        let codex = try #require(HarnessCatalogue.descriptor(for: .codex))

        let on = HarnessAvailability.of(claude, in: fixture.environment, isOn: true)
        #expect(on.state == .on && on.isOn && on.isFound && on.canSwitch)
        #expect(on.executable == fixture.folder.appendingPathComponent("claude").path)
        #expect(on.searchedFolders == 1)

        let off = HarnessAvailability.of(codex, in: fixture.environment, isOn: false)
        #expect(off.state == .off && !off.isOn && off.isFound && off.canSwitch)
        #expect(off.executable?.hasSuffix("/codex") == true)
    }

    @Test func notFoundIsOffAndTheSwitchIsDisabledWhateverThePreferenceSays() throws {
        let fixture = try path(with: [])
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let opencode = try #require(HarnessCatalogue.descriptor(for: .opencode))

        let missing = HarnessAvailability.of(opencode, in: fixture.environment, isOn: true)
        #expect(missing.state == .notFound && !missing.isOn && !missing.isFound)
        #expect(!missing.canSwitch, "a CLI that is not on the PATH cannot be switched on")
        #expect(missing.executable == nil)
        #expect(missing.searchedFolders == 1)
    }

    @Test func allJudgesEveryHarnessInCatalogueOrderFromOnePathAndTheSwitch() throws {
        let fixture = try path(with: ["opencode", "pi"])
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let connections = HarnessConnections()

        let rows = HarnessAvailability.all(in: fixture.environment, connections: connections)
        #expect(rows.map(\.id) == HarnessCatalogue.ids)
        #expect(rows.map(\.state) == [.notFound, .notFound, .off, .notFound, .off],
                "Claude and Codex are not installed here; opencode and pi are found and off by default")
        #expect(rows.filter(\.isFound).map(\.id) == [.opencode, .pi])
        #expect(rows.filter { !$0.canSwitch }.map(\.id) == [.claude, .codex, .agy])
    }

    @Test func theSwitchDefaultsToOnWhenFoundAndKeepsAnExplicitChoice() {
        let connections = HarnessConnections()
        #expect(connections.isOn(.claude) && connections.isOn(.codex), "on when found")
        #expect(!connections.isOn(.opencode) && !connections.isOn(.agy) && !connections.isOn(.pi), "off until switched on")
        #expect(connections.explicitChoices.isEmpty, "a default is the file's absence of an entry")

        connections.setOn(.opencode, true)
        #expect(connections.isOn(.opencode) && connections.explicitChoices == ["opencode": true])
        connections.setOn(.claude, false)
        #expect(!connections.isOn(.claude) && connections.explicitChoices == ["opencode": true, "claude": false])

        connections.setOn(.opencode, false)
        connections.setOn(.claude, true)
        #expect(connections.explicitChoices.isEmpty, "back to the default removes the entry")
    }

    @Test func theReaderUsesTheCachedTerminalEnvironment() async throws {
        let fixture = try path(with: ["agy"])
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let connections = HarnessConnections()
        connections.setOn(.agy, true)

        let reader = HarnessAvailabilityReader(environment: { fixture.environment })
        let rows = try await reader.read(connections)
        #expect(rows.first { $0.id == .agy }?.state == .on)
        #expect(rows.first { $0.id == .claude }?.state == .notFound)
    }
}
