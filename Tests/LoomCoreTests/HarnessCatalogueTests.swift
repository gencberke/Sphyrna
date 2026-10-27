import Foundation
import Testing
@testable import LoomCore

/// C1: one catalogue describes Claude, Codex, opencode, agy and pi (FB6-13). The descriptors carry the facts the old
/// per-provider switches held, an id this build does not know still reads, and a harness without a start path is never
/// startable.
@Suite(.timeLimit(.minutes(1)))
struct HarnessCatalogueTests {
    @Test func theCatalogueListsFiveHarnessesInConnectionsOrder() {
        #expect(HarnessCatalogue.ids == [.claude, .codex, .opencode, .agy, .pi])
        #expect(HarnessCatalogue.all.map(\.displayName) == ["Claude", "Codex", "opencode", "agy", "pi"])
        #expect(HarnessCatalogue.all.map(\.command) == ["claude", "codex", "opencode", "agy", "pi"])
        #expect(HarnessCatalogue.all.map(\.mark) == [
            "harness-claude", "harness-codex-template", "harness-opencode", "harness-agy", "harness-pi",
        ])
        #expect(HarnessCatalogue.descriptor(for: HarnessID("future-harness")) == nil)
    }

    @Test func claudeAndCodexAreOnWhenFoundAndOnlyTheyHaveAStartPath() {
        #expect(HarnessCatalogue.all.filter(\.onWhenFound).map(\.id) == [.claude, .codex])
        #expect(HarnessCatalogue.all.filter(\.startable).map(\.id) == [.claude, .codex])
        for id in [HarnessID.opencode, .agy, .pi] {
            #expect(HarnessCatalogue.descriptor(for: id)?.startable == false)
            #expect(HarnessCapabilities.ofHarness(id, startable: [id]).startable == false, "a harness with no start path never starts")
        }
    }

    @Test func aDescriptorsCapabilitiesAreTheTablesRow() {
        for descriptor in HarnessCatalogue.all {
            #expect(descriptor.capabilities == HarnessCapabilities.intrinsic(ofHarness: descriptor.id))
            #expect(descriptor.capabilities.hasHarness)
            #expect(!descriptor.capabilities.startable, "the descriptor holds the intrinsic row, not the build's answer")
        }
    }

    @Test func theVersionTablesLiveInTheDescriptors() {
        #expect(HarnessCatalogue.descriptor(for: .claude)?.versions?.minimum == ProviderCapabilities.claudeLaunchChoicesFloor)
        #expect(HarnessCatalogue.descriptor(for: .claude)?.versions?.recommended == [2, 1, 300])
        #expect(HarnessCatalogue.descriptor(for: .codex)?.versions?.recommended == [0, 160, 0])
        #expect(HarnessCatalogue.descriptor(for: .codex)?.requiresAppServerListen == true)
        for id in [HarnessID.opencode, .agy, .pi] {
            #expect(HarnessCatalogue.descriptor(for: id)?.versions == nil, "P1's spike has not fixed a version yet")
        }
    }

    @Test func setupAndDoctorLinesComeFromTheDescriptor() {
        let opencode = HarnessCatalogue.descriptor(for: .opencode)
        #expect(opencode?.install?.command == "curl -fsSL https://opencode.ai/install | bash")
        #expect(opencode?.install?.alternative == "brew install sst/tap/opencode")
        #expect(opencode?.signIn?.command == "opencode auth login")
        #expect(opencode?.doctorArguments == ["debug", "config"])

        let agy = HarnessCatalogue.descriptor(for: .agy)
        #expect(agy?.install == nil && agy?.signIn == nil && agy?.doctorArguments == nil, "its --help lists none")

        let pi = HarnessCatalogue.descriptor(for: .pi)
        #expect(pi?.install?.command == "npm install -g @earendil-works/pi-coding-agent")
        #expect(pi?.signIn == nil && pi?.doctorArguments == nil)
        #expect(HarnessSetupCommand.command(forHarness: .opencode, state: .install) == opencode?.install)
        #expect(HarnessSetupCommand.command(forHarness: .agy, state: .install) == nil)
        #expect(HarnessDeepCheck.arguments(forHarness: .opencode) == ["debug", "config"])
        #expect(HarnessDeepCheck.arguments(forHarness: .agy) == nil)
        #expect(HarnessDeepCheck.display(forHarness: .pi) == nil)
    }

    @Test func theProfileFolderAndItsVariableAreFactsOfTheDescriptor() {
        let claude = HarnessCatalogue.descriptor(for: .claude)
        #expect(claude?.profileVariable == "CLAUDE_CONFIG_DIR" && claude?.profileFolder == ".claude")
        #expect(claude?.pinsDefaultProfile == false)
        let codex = HarnessCatalogue.descriptor(for: .codex)
        #expect(codex?.profileVariable == "CODEX_HOME" && codex?.profileFolder == ".codex")
        #expect(codex?.pinsDefaultProfile == true)
        #expect(HarnessCatalogue.descriptor(for: .opencode)?.profileVariable == "OPENCODE_CONFIG_DIR")
        #expect(HarnessCatalogue.descriptor(for: .opencode)?.profileFolder == ".config/opencode")
        #expect(HarnessCatalogue.descriptor(for: .agy)?.profileVariable == "ANTIGRAVITY_GEMINI_DIR")
        #expect(HarnessCatalogue.descriptor(for: .agy)?.profileFolder == ".gemini/antigravity-cli")
        #expect(HarnessCatalogue.descriptor(for: .pi)?.profileVariable == nil)
        #expect(HarnessCatalogue.descriptor(for: .pi)?.profileFolder == ".pi/agent")
    }

    @Test func theStoredProviderIsAThinBridgeThroughTheHarnessId() {
        #expect(HarnessID.claude.provider == .claude)
        #expect(HarnessID.codex.provider == .codex)
        #expect(HarnessID(.synthetic).provider == .synthetic)
        #expect(HarnessID(.synthetic).isKnown == false, "a test fixture is not a harness")
        #expect(HarnessID.opencode.provider == nil, "opencode has no stored provider yet")
        #expect(HarnessID.agy.provider == nil && HarnessID.pi.provider == nil)
        #expect(ManagedSession.Provider.claude.harnessID == .claude)
    }

    @Test func anUnknownHarnessIdOpensInsteadOfFailing() throws {
        let known = try JSONDecoder().decode(HarnessID.self, from: Data(#""claude""#.utf8))
        #expect(known == .claude && known.isKnown && known.provider == .claude)

        let future = try JSONDecoder().decode(HarnessID.self, from: Data(#""future-harness""#.utf8))
        #expect(future.rawValue == "future-harness")
        #expect(!future.isKnown && future.provider == nil && HarnessCatalogue.descriptor(for: future) == nil)

        #expect(try JSONDecoder().decode(HarnessID.self, from: Data("42".utf8)) == .unknown)
        #expect(try JSONDecoder().decode(HarnessID.self, from: Data(#""""#.utf8)) == .unknown)

        let encoded = try JSONEncoder().encode(HarnessID.opencode)
        #expect(String(decoding: encoded, as: UTF8.self) == #""opencode""#)
    }

    @Test func anUnknownHarnessHasNoSwitchAndNoCapabilities() {
        let unknown = HarnessID("future-harness")
        let connections = HarnessConnections(choices: [unknown: true])
        #expect(!connections.isOn(unknown), "a harness this build does not describe is never on")
        #expect(connections.explicitChoices.isEmpty)
        #expect(HarnessCapabilities.intrinsic(ofHarness: unknown).hasHarness == false)
        #expect(HarnessSetupCommand.command(forHarness: unknown, state: .install) == nil)
    }
}
