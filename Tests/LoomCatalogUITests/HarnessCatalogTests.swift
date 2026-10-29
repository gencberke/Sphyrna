import AppKit
import Foundation
@testable import LoomChat
import LoomCore
import Testing
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

private typealias LookupCount = HarnessCatalogShared.LookupCount

/// Intents that start nothing: a model with one can ask whether a start is available (C2B).
@MainActor
private final class StartIntents: ConversationIntents {
    func start(provider: ManagedSession.Provider, projectID: UUID?) {}
    func resume(sessionID: UUID) {}
    func stop(sessionID: UUID) {}
    func answer(sessionID: UUID, requestID: String, accept: Bool) {}
    func viewed(sessionID: UUID) {}
    func terminalView(sessionID: UUID) -> NSView? { nil }
}

/// The connect switch's preference and the composer's model lists as they come from `ModelCatalog` (D-98, D-99).
@MainActor
struct HarnessCatalogTests: HarnessCatalogFixtures {
    // MARK: The preference

    @Test func theSwitchIsStoredPerHarnessAndReadsOnInAnOlderFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-harness-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences.json")
        let store = UIPreferencesStore(url: url)
        #expect(store.current.isHarnessConnected(HarnessID.claude) && store.current.isHarnessConnected(HarnessID.codex),
                "on by default")
        #expect(!store.current.isHarnessConnected(HarnessID.opencode), "off until switched on")
        try store.update { $0.setHarnessConnected(HarnessID.codex, false) }

        let reread = UIPreferencesStore(url: url).current
        #expect(!reread.isHarnessConnected(HarnessID.codex) && reread.isHarnessConnected(HarnessID.claude))
        #expect(reread.disconnectedHarnesses == [.codex])
        #expect(reread.harnessChoices == [.codex: false])
        let connections = HarnessConnections(choices: reread.harnessChoices)
        #expect(!connections.isOn(.codex) && connections.isOn(.claude))

        try store.update { $0.setHarnessConnected(HarnessID.codex, true) }
        #expect(UIPreferencesStore(url: url).current == UIPreferences(), "on again is the default, so the file says nothing")
    }

    @Test func aNewHarnessKeepsItsExplicitChoiceAndAnOlderBuildStillReadsTheFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-harness-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences.json")
        let store = UIPreferencesStore(url: url)
        try store.update { $0.setHarnessConnected(HarnessID.opencode, true) }
        #expect(store.current.harnessConnections == ["opencode": true], "an explicit on is written for a harness off by default")

        // 1.7.2 reads the key as a [String: Bool] and ignores a harness it does not know; the type is unchanged.
        struct OlderPreferences: Decodable { let harnessConnections: [String: Bool]? }
        let written = try JSONDecoder().decode(OlderPreferences.self, from: Data(contentsOf: url))
        #expect(written.harnessConnections == ["opencode": true])

        let reread = UIPreferencesStore(url: url).current
        #expect(reread.isHarnessConnected(HarnessID.opencode))
        #expect(reread.harnessChoices == [.opencode: true])
        #expect(reread.disconnectedHarnesses.isEmpty, "1.7.2 reads the same [String: Bool] and ignores a harness it does not know")

        try store.update { $0.setHarnessConnected(HarnessID.opencode, false) }
        #expect(UIPreferencesStore(url: url).current == UIPreferences(), "off is its default, so the file says nothing")
    }

    @Test func anOlderOrDamagedFileReadsClaudeAndCodexOnAndTheNewHarnessesOff() throws {
        for json in ["{}", #"{"viewMode":"projects"}"#, #"{"harnessConnections":{"codex":"no"}}"#, #"{"harnessConnections":[1]}"#] {
            let old = try JSONDecoder().decode(UIPreferences.self, from: Data(json.utf8))
            #expect(old.isHarnessConnected(HarnessID.claude) && old.isHarnessConnected(HarnessID.codex), "\(json)")
            #expect(!old.isHarnessConnected(HarnessID.opencode) && !old.isHarnessConnected(HarnessID.agy)
                    && !old.isHarnessConnected(HarnessID.pi), "\(json)")
            #expect(old.disconnectedHarnesses.isEmpty)
        }
        let named = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"harnessConnections":{"codex":false,"unknown":false}}"#.utf8))
        #expect(!named.isHarnessConnected(HarnessID.codex))
        #expect(named.disconnectedHarnesses == [.codex], "a harness this build does not know is ignored")
        #expect(named.harnessChoices == [.codex: false])
    }

    // MARK: The lists

    @Test func claudeIsTheCatalogsList() {
        #expect(ModelCatalog.claudeTitle(of: "sonnet") == "Sonnet" && ModelCatalog.claudeTitle(of: "fable") == "fable")
        #expect(HeaderModelContent.launchTitle("haiku", catalog: ModelCatalog()) == "Haiku")
        let claude = picker().groups()[0]
        #expect(claude.rows.map(\.id) == ["default"] + ModelCatalog.claude.map(\.id))
    }

    /// Full model names (D-100 round): a Claude alias is named by the release the probe said it resolves to; an id not shaped
    /// like a release falls back to the CLI's display name.
    @Test func claudeAliasesTakeTheFullNamesOfTheirReleases() {
        let catalog = ModelCatalog()
        #expect(catalog.claudeTitle(of: "opus") == "Opus", "before a probe answered: the fixed short title")
        catalog.apply(HarnessReading(provider: .claude, models: [
            HarnessModel(id: "default", displayName: "Default", isDefault: true, efforts: [], resolvedModel: "claude-opus-5-5"),
            HarnessModel(id: "opus", displayName: "Opus", isDefault: false, efforts: [], resolvedModel: "claude-opus-5-5"),
            HarnessModel(id: "sonnet", displayName: "Sonnet", isDefault: false, efforts: [], resolvedModel: "claude-sonnet-5-5"),
            HarnessModel(id: "haiku", displayName: "Haiku", isDefault: false, efforts: [], resolvedModel: "claude-haiku-5-5-20260901"),
            HarnessModel(id: "fable", displayName: "Fable", isDefault: false, efforts: [], resolvedModel: "claude-fable-5-1"),
            HarnessModel(id: "mystery", displayName: "Mystery Model", isDefault: false, efforts: [], resolvedModel: "m-7"),
            HarnessModel(id: "opus[1m]", displayName: "Opus 1M", isDefault: false, efforts: [], resolvedModel: "claude-opus-5-5[1m]"),
        ], readAt: Date()))
        #expect(catalog.claudeModels.map(\.id) == ["opus", "sonnet", "haiku", "fable", "mystery"])
        #expect(catalog.claudeModels.map(\.title) == ["Opus 5.5", "Sonnet 5.5", "Haiku 5.5", "Fable 5.1", "Mystery Model"])
        #expect(catalog.claudeTitle(of: "sonnet") == "Sonnet 5.5" && catalog.claudeTitle(of: "unknown") == "unknown")
        #expect(ModelCatalog.claudeFullName(resolvedModel: "claude-3-5-sonnet-20241022", displayName: nil) == "Sonnet 3.5")
        // The live composer's chip: the release's full name, not the CLI's short display name.
        var state = ChatComposerState.idle(sessionID: UUID())
        state.resolvedModel = "claude-opus-5-5"
        state.models = [ModelOption(value: "opus", resolvedModel: "claude-opus-5-5", displayName: "Opus",
                                    supportedEffortLevels: [])]
        #expect(ComposerBarText.modelTitle(state) == "Opus 5.5")
    }

    @Test func fallbackCodexRowsUseModelIDsRatherThanDisplayNames() {
        #expect(ModelCatalog.codexFallback.map(\.id) == ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna"])
        #expect(ModelCatalog.codexFallback.map(\.title) == ["GPT-6 Astra", "GPT-6.1 Sol", "GPT-6 Luna"])
    }

    // MARK: Startable (C2B)

    /// One rule for "startable": a harness switched off is not startable, and switching it on again makes it startable with no
    /// restart. (The lists follow in their own test.)
    @Test func aHarnessSwitchedOffIsNotStartableUntilSwitchedOn() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-harness-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let intents = StartIntents()
        model.intents = intents
        let connections = HarnessConnections(choices: [.claude: false])
        model.harnessConnections = connections
        #expect(!model.canStart(.claude, projectID: nil), "switched off: nothing starts Claude")
        #expect(!model.canStart(.newSessionDefault, projectID: nil), "the default harness is the same harness")
        connections.setOn(.claude, true)
        #expect(model.canStart(.claude, projectID: nil), "switched on again: startable with no restart")
    }

    /// A CLI that is not on the PATH is never startable, whatever the switch says: Codex keeps its entry, disabled with the reason,
    /// and the default harness has no entry where it cannot start.
    @Test func aNotFoundCLIIsNeverStartableAndSaysWhy() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-harness-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let intents = StartIntents()
        model.intents = intents
        model.harnessAvailability = [
            .claude: HarnessAvailability(id: .claude, state: .notFound),
            .codex: HarnessAvailability(id: .codex, state: .on, executable: "/fake/bin/codex"),
        ]
        #expect(model.canStart(.codex, projectID: nil), "found and switched on: startable")
        #expect(!model.canStart(.claude, projectID: nil) && !model.offersNewSession(.claude), "not found: no entry for the default harness")
        #expect(model.startUnavailableReason(.claude) == nil)

        model.harnessAvailability?[.codex] = HarnessAvailability(id: .codex, state: .notFound)
        #expect(!model.canStart(.codex, projectID: nil))
        #expect(model.offersNewSession(.codex), "not found: the entry is offered, disabled")
        #expect(model.startUnavailableReason(.codex) == CatalogModel.notFoundReason)
        #expect(CatalogModel.notFoundReason == "Not found on this Mac")

        model.harnessConnections = HarnessConnections(choices: [.codex: false])
        #expect(!model.offersNewSession(.codex) && !model.canStart(.codex, projectID: nil), "switched off: no entry at all")
    }

    /// Every list follows the catalogue (C2B): the sidebar's entries, the Dock menu and the menu bar lose a switched-off harness at once,
    /// and a Codex whose CLI is not found stays listed, disabled, with its reason.
    @Test func theListsFollowTheSwitchAndTheCLIsWithNoRestart() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-harness-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let intents = StartIntents()
        model.intents = intents
        let connections = HarnessConnections(choices: [.claude: false])
        model.harnessConnections = connections
        func listedProviders() -> [ManagedSession.Provider] { NewConversationAction.listed(on: model).map(\.provider) }
        func dockHasNewSession() -> Bool { model.dockMenuItems().contains { $0.kind == .newSession } }
        func menuBarHasNewSession() -> Bool { MenuBarMenu.items(for: model.menuBarState()).contains { $0.kind == .newSession } }

        #expect(listedProviders() == [.codex], "Claude switched off: its entries are gone")
        #expect(NewConversationAction.startable(on: model).map(\.provider) == [.codex])
        #expect(!dockHasNewSession() && !menuBarHasNewSession())

        connections.setOn(.claude, true)
        #expect(listedProviders() == [.claude, .codex] && dockHasNewSession() && menuBarHasNewSession(), "switched on again: no restart")

        // The CLIs are not found: Claude has no entry, Codex stays listed, disabled with the reason.
        model.harnessAvailability = [
            .claude: HarnessAvailability(id: .claude, state: .notFound),
            .codex: HarnessAvailability(id: .codex, state: .notFound),
        ]
        #expect(listedProviders() == [.codex] && !dockHasNewSession() && !menuBarHasNewSession())
        let codex = NewConversationAction.listed(on: model).last
        #expect(codex?.unavailableReason(on: model) == CatalogModel.notFoundReason)
        #expect(codex?.isEnabled(on: model, projectID: nil) == false)
    }

    /// The app's reader looks for the CLIs on the terminal environment's PATH when it is installed, and then at most once a minute
    /// (a forced read at once). Nothing runs the CLI: the lookup only checks that the file is there.
    @Test func theCLIsAreLookedForOnTheTerminalPathAtMostOnceAMinute() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("loom-path-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let claude = folder.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

        let reads = LookupCount()
        let reader = HarnessAvailabilityReader(environment: {
            await reads.bump()
            return ["PATH": folder.path]
        })
        let clock = LookupClock(Date(timeIntervalSince1970: 2_000_000))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-harness-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let intents = StartIntents()
        model.intents = intents
        model.currentDate = { clock.now }
        model.installHarnessAvailability(reader)
        #expect(await inspectorWaitUntil { model.harnessAvailability != nil })
        #expect(model.harnessAvailability?[.claude]?.isFound == true && model.harnessAvailability?[.codex]?.isFound == false)
        #expect(model.canStart(.claude, projectID: nil) && !model.canStart(.codex, projectID: nil))
        #expect(await lookups(reads, reached: 1) == 1)

        clock.now = clock.now.addingTimeInterval(30)
        model.refreshHarnessAvailability()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await reads.value == 1, "activation within the minute reads nothing")

        clock.now = clock.now.addingTimeInterval(31)
        model.refreshHarnessAvailability()
        #expect(await lookups(reads, reached: 2) == 2, "a minute on: read again")

        model.refreshHarnessAvailability(force: true)
        #expect(await lookups(reads, reached: 3) == 3, "Check Again or a switch: at once")
    }
}

/// A clock a test moves by hand.
private final class LookupClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}
