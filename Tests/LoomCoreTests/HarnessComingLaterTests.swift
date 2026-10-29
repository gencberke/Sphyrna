import Foundation
import Testing
@testable import LoomCore

/// D-120: opencode and agy are frozen for 1.8.0. The catalogue marks them "Coming later", and every gate that could start
/// one reads that mark: the capability row, the connect switch (models, probe, usage), and the CLI's `open` and
/// `task create` (both validate through `OpenSessionInput`).
struct HarnessComingLaterTests {
    static let frozen: [HarnessID] = [.opencode, .agy]

    @Test func aFrozenHarnessCannotStartWhereTheBuildWouldStartIt() {
        let everything = Set(HarnessCatalogue.ids)
        for id in Self.frozen {
            let row = HarnessCapabilities.ofHarness(id, startable: everything)
            #expect(!row.startable, "\(id.rawValue) is coming later")
            #expect(row.hasHarness, "\(id.rawValue) is still a real harness, so its stored sessions keep their name")
        }
        #expect(!HarnessCapabilities.of(.agy, startable: [.agy]).startable)
        #expect(HarnessCapabilities.of(.claude, startable: [.claude]).startable)
        #expect(HarnessCapabilities.of(.codex, startable: [.codex]).startable)
    }

    @MainActor @Test func aFrozenHarnessIsNeverOfferedEvenWhenItsSwitchWasOn() {
        let connections = HarnessConnections(choices: [.opencode: true, .agy: true])
        for id in Self.frozen { #expect(!connections.isOn(id), "\(id.rawValue) is not offered") }
        #expect(connections.explicitChoices == ["opencode": true, "agy": true], "the stored choice is kept for later")
        #expect(connections.isOn(.claude) && connections.isOn(.codex))
        #expect(ModelCatalog(connections: connections).models(for: .agy).isEmpty, "no models to pick")

        let environment = ["PATH": "/usr/bin:/bin"]
        for id in Self.frozen {
            let descriptor = HarnessCatalogue.descriptor(for: id)!
            let availability = HarnessAvailability.of(descriptor, in: environment, isOn: true)
            #expect(!availability.isOn && !availability.canSwitch, "\(id.rawValue)'s switch cannot be used")
        }
    }

    @Test func theCLIRefusesAFrozenHarnessWithTheReason() {
        for id in Self.frozen {
            #expect {
                _ = try OpenSessionInput.validated(title: "Child", project: nil, message: "Do it", harness: id.rawValue)
            } throws: { error in
                String(describing: error) == "\(id.rawValue) is coming later: this version of Sphyrna cannot start its sessions"
            }
        }
        #expect((try? OpenSessionInput.validated(title: "Child", project: nil, message: "Do it", harness: "codex")) != nil)
    }
}
