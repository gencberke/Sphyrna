import Foundation
import Testing
@testable import LoomCore

struct AgyLaunchProfileTests {
    @Test func newAndResumeKeepTheirNativeContractsSeparate() throws {
        let root = URL(fileURLWithPath: "/private/tmp/owned-agy-channel")
        let environment = ["HOME": "/private/tmp/owned-home", "SPHYRNA_CLI": "/private/tmp/owned-helper"]
        let choices = HarnessLaunchChoices(harness: .agy, model: "gemini-3.8-flash-medium", effort: "low", mode: .acceptEdits)
        let fresh = try AgyLaunchProfile.terminal(route: .new(firstMessage: "owned opening"), choices: choices,
                                                  discoveryDirectory: root, environment: environment)
        #expect(fresh.arguments == ["--add-dir", root.path, "--model", "gemini-3.8-flash-medium", "--effort", "low",
                                    "--mode", "accept-edits", "-i", "owned opening"])
        #expect(fresh.environment == environment)
        let id = UUID()
        let resumed = try AgyLaunchProfile.terminal(route: .resume(id), choices: .init(harness: .agy),
                                                    discoveryDirectory: root, environment: environment)
        #expect(resumed.arguments == ["--add-dir", root.path, "--conversation", id.uuidString.lowercased()])
        #expect(throws: AgyLaunchError.unsupportedChoice) {
            try AgyLaunchProfile.terminal(route: .resume(id), choices: choices,
                                         discoveryDirectory: root, environment: environment)
        }
    }

    @Test func emptyTaskStartupHasNoInputAndUnsupportedChoicesAreRefused() throws {
        let root = URL(fileURLWithPath: "/private/tmp/owned-agy-channel")
        let fresh = try AgyLaunchProfile.terminal(route: .new(firstMessage: nil), choices: .init(harness: .agy),
                                                  discoveryDirectory: root, environment: [:])
        #expect(fresh.arguments == ["--add-dir", root.path])
        for mode in [HarnessMode.fullAccess, .askBeforeEdits, .ask] {
            #expect(throws: AgyLaunchError.unsupportedChoice) {
                try AgyLaunchProfile.terminal(route: .new(firstMessage: nil), choices: .init(harness: .agy, mode: mode),
                                             discoveryDirectory: root, environment: [:])
            }
        }
    }

    @Test func discoveryUsesOnlyItsFreshOwnedRootAndKeepsCapabilityValuesOut() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-agy-discovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = URL(fileURLWithPath: "/usr/bin/true")
        _ = try AgySessionDiscovery.install(in: root, helper: helper)
        let hooks = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".agents/hooks.json"))) as? [String: [String: [[String: Any]]]]
        let events = try #require(hooks?["sphyrna-owned-channel"])
        #expect(Set(events.keys) == Set(AgySessionDiscovery.hookEvents))
        #expect(events.values.allSatisfy { $0.count == 1 && $0[0]["timeout"] as? Int == 5 })
        let skill = try String(contentsOf: root.appendingPathComponent(".agents/skills/sphyrna/SKILL.md"), encoding: .utf8)
        let description = try #require(skill.split(separator: "\n").first { $0.hasPrefix("description:") })
        #expect(description.count <= 300)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path))
        #expect(throws: AgyLaunchError.invalidTarget) { try AgySessionDiscovery.install(in: root, helper: helper) }
    }
}
