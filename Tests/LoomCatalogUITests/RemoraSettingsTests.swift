import Foundation
import Testing
import LoomCore
@testable import LoomRemora
@testable import LoomCatalogUI

/// L3b: Settings → Remora as plain values: the section's place, what each control does to the model, what Off dims, the popups'
/// lists, the stepper's ends and the two mono lines. No view, no host, no call to Remora (`askRemora`, `briefRemora` and
/// `briefRemoraIfDue` are not used here), and no panel: the note's panels sit behind `RemoraNoteActions`.
@MainActor
struct RemoraSettingsTests {
    private func makeModel() -> CatalogModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-remora-settings-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CatalogModel(catalog: nil, events: SessionEventHub(), preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
    }

    // MARK: The section

    @Test func remoraIsTheTabBeforeAbout() {
        #expect(SettingsSection.allCases.map(\.title) == ["General", "Connections", "Theme", "Usage", "Sessions", "Remora", "About"])
        #expect(SettingsSection.available(cleanupReview: false).map(\.title) == ["General", "Connections", "Theme", "Usage", "Remora", "About"])
        let all = SettingsSection.available(cleanupReview: true)
        #expect(all.last == .about && all[all.count - 2] == .remora)
    }

    @Test func theMemorySheetOpensFromOutsideWithOneCall() {
        let navigation = SettingsNavigation(section: .general)
        navigation.openRemoraMemory()
        #expect(navigation.section == .remora && navigation.openSheet == .remoraMemory && navigation.memoryTab == .journal)
        navigation.setSheet(nil)
        navigation.openRemoraMemory(tab: .notes)
        #expect(navigation.section == .remora && navigation.openSheet == .remoraMemory && navigation.memoryTab == .notes)
    }

    // MARK: Each control calls its setter

    @Test func everyControlCallsItsSetterAndTheValueIsKept() {
        let model = makeModel()
        let controls = RemoraSettingsControls(model: model, catalog: ModelCatalog())
        let project = UUID()
        let note = FileManager.default.temporaryDirectory.appendingPathComponent("Remora-\(UUID()).md")
        controls.setOn(false)
        controls.setModel("haiku")
        controls.setEffort("high")
        controls.setBriefMode(.whenIAsk)
        controls.setLanguage(tag: "tr")
        controls.setProject(project, reads: false)
        controls.setProposals(false)
        controls.setThreshold(percent: 25)
        controls.setNoteFile(note)
        let expected = RemoraPreferences(isOn: false, model: "haiku", effort: "high", briefMode: .whenIAsk, excludedProjects: [project],
                                         proposals: false, windowThreshold: 0.25, noteFilePath: note.path, language: "tr")
        #expect(model.remora.preferences == expected)
        controls.setLanguage(tag: "")
        controls.setProject(project, reads: true)
        #expect(model.remora.preferences.language == nil && model.remora.preferences.excludedProjects.isEmpty)
    }

    @Test func theExcludedProjectsAreTheUncheckedOnes() {
        let model = makeModel()
        let controls = RemoraSettingsControls(model: model)
        let first = UUID(), second = UUID()
        controls.setProject(first, reads: false)
        controls.setProject(second, reads: false)
        #expect(model.remora.preferences.excludedProjects == [first, second])
        controls.setProject(first, reads: true)
        #expect(model.remora.preferences.excludedProjects == [second])
        // Checking a project that was never left out changes nothing.
        controls.setProject(UUID(), reads: true)
        #expect(model.remora.preferences.excludedProjects == [second])
    }

    @Test func offDimsEveryRowButTheSwitch() {
        #expect(RemoraSettingsRule.dimsTheRest(isOn: false))
        #expect(!RemoraSettingsRule.dimsTheRest(isOn: true))
        #expect(LoomTheme.RemoraTab.dimmed == 0.38)
    }

    // MARK: The popups

    @Test func theLanguageListStartsWithTheLastQuestionAndNilIsItsTag() {
        let list = RemoraChoices.languages(including: nil)
        #expect(list.first == RemoraChoices.Option(value: "", title: "Same as my last question"))
        #expect(list.dropFirst().map(\.value) == ["en", "tr", "de", "fr", "es", "it", "pt", "nl", "ja", "ko", "zh-Hans"])
        #expect(RemoraChoices.tag(forLanguage: nil) == "" && RemoraChoices.language(forTag: "") == nil)
        #expect(RemoraChoices.tag(forLanguage: "tr") == "tr" && RemoraChoices.language(forTag: "tr") == "tr")
        #expect(RemoraChoices.title(of: "", in: list) == "Same as my last question")
        #expect(RemoraChoices.title(of: "zh-Hans", in: list) == "Chinese (Simplified)")
    }

    @Test func aStoredValueTheListsDoNotHaveIsAddedSoThePopupNeverShowsAnUnlistedValue() {
        let catalog = ModelCatalog()
        #expect(RemoraChoices.languages(including: "sv").last == RemoraChoices.Option(value: "sv", title: "sv"))
        #expect(RemoraChoices.languages(including: "tr").count == RemoraChoices.languages(including: nil).count)
        #expect(RemoraChoices.models(from: catalog.claudeModels, including: "sonnet").map(\.title) == ["Opus", "Sonnet", "Haiku"])
        #expect(RemoraChoices.models(from: catalog.claudeModels, including: "claude-x").map(\.value) == ["opus", "sonnet", "haiku", "claude-x"])
        #expect(RemoraChoices.efforts(for: "sonnet", from: catalog, including: "low").map(\.title)
            == ["Low", "Medium", "High", "Extra high", "Max"])
        #expect(RemoraChoices.efforts(for: "sonnet", from: catalog, including: "weird").last?.value == "weird")
    }

    /// FB6-22: every Claude model the catalog knows (Opus included) with the efforts its own probe listed; a model the probe
    /// gave no levels is offered with no effort row.
    @Test func everyClaudeModelIsOfferedWithItsOwnEfforts() {
        let catalog = ModelCatalog()
        catalog.apply(HarnessReading(provider: .claude, models: [
            HarnessModel(id: "opus", displayName: "Opus", isDefault: false, efforts: ["low", "medium", "high"],
                         resolvedModel: "claude-opus-5-5"),
            HarnessModel(id: "sonnet", displayName: "Sonnet", isDefault: false, efforts: ["low", "medium", "high", "xhigh", "max"],
                         resolvedModel: "claude-sonnet-5-5"),
            HarnessModel(id: "haiku", displayName: "Haiku", isDefault: false, efforts: [], resolvedModel: "claude-haiku-5-5"),
        ], readAt: Date()))
        #expect(RemoraChoices.models(from: catalog.claudeModels, including: "sonnet").map(\.value) == ["opus", "sonnet", "haiku"])
        #expect(RemoraChoices.models(from: catalog.claudeModels, including: "sonnet").map(\.title) == ["Opus 5.5", "Sonnet 5.5", "Haiku 5.5"])
        #expect(RemoraChoices.efforts(for: "opus", from: catalog, including: "low").map(\.value) == ["low", "medium", "high"])
        #expect(RemoraChoices.efforts(for: "opus", from: catalog, including: "max").map(\.value) == ["low", "medium", "high", "max"],
                "a stored level the model does not list stays in its menu")
        #expect(RemoraChoices.efforts(for: "haiku", from: catalog, including: "low").isEmpty, "no level, no row")
        #expect(RemoraChoices.keptEffort("max", for: "opus", from: catalog) == "high", "the nearest level below")
        #expect(RemoraChoices.keptEffort("xhigh", for: "haiku", from: catalog) == nil)
    }

    @Test func aModelChangeKeepsTheNearestEffortAndAModelWithoutEffortsHidesTheRow() {
        let model = makeModel()
        let catalog = ModelCatalog()
        catalog.apply(HarnessReading(provider: .claude, models: [
            HarnessModel(id: "opus", displayName: "Opus", isDefault: false, efforts: ["low", "medium", "high"], resolvedModel: "claude-opus-5-5"),
            HarnessModel(id: "haiku", displayName: "Haiku", isDefault: false, efforts: [], resolvedModel: "claude-haiku-5-5"),
        ], readAt: Date()))
        let controls = RemoraSettingsControls(model: model, catalog: catalog)
        controls.setEffort("max")
        controls.setModel("opus")
        #expect(model.remora.preferences.model == "opus" && model.remora.preferences.effort == "high")
        controls.setModel("haiku")
        #expect(model.remora.preferences.effort == "high", "a model without efforts keeps the stored level for a later one")
        #expect(RemoraChoices.efforts(for: "haiku", from: catalog, including: "high").isEmpty)
    }

    @Test func theBriefModeSegmentsAreAutomaticAndWhenIAsk() {
        #expect([RemoraBriefMode.automatic, .whenIAsk].map(\.settingsTitle) == ["Automatic", "When I ask"])
    }

    // MARK: The threshold

    @Test func theThresholdStepperRunsFromZeroToFiftyPercentAndStopsAtItsEnds() {
        let range = LoomTheme.RemoraTab.thresholdRange
        #expect(range == 0...50)
        #expect(!StepperRule.canStep(0, by: -1, in: range) && StepperRule.canStep(0, by: 1, in: range))
        #expect(!StepperRule.canStep(50, by: 1, in: range) && StepperRule.canStep(50, by: -1, in: range))
        #expect(RemoraThreshold.percent(of: RemoraPreferences.defaultWindowThreshold) == 10)
        #expect(RemoraThreshold.percent(of: 0.9) == 50, "a stored share above the range reads as its top")
        #expect(RemoraThreshold.percent(of: 0) == 0)
        #expect(RemoraThreshold.share(ofPercent: 15) == 0.15)
        #expect(RemoraSettingsLine.threshold(10) == "10%")
    }

    // MARK: The lines

    @Test func theUseLineSaysTodaysQuestionsBriefsAndTokens() {
        var day = RemoraUsage.Day(start: Date())
        #expect(RemoraSettingsLine.today(nil) == "Nothing asked yet today")
        #expect(RemoraSettingsLine.today(day) == "Nothing asked yet today")
        day.questions = 6
        day.briefs = 1
        day.tokens = RemoraTokenUsage(input: 1_000, cacheCreation: 30_000, cacheRead: 40_000, output: 10_000)
        #expect(RemoraSettingsLine.today(day) == "6 questions · 1 brief · 81K tokens of your plan")
        day.questions = 1
        day.briefs = 0
        #expect(RemoraSettingsLine.today(day) == "1 question · 81K tokens of your plan")
    }

    @Test func theWorkingMemoryLineCountsDaysAndNotes() {
        #expect(RemoraSettingsLine.workingMemory(days: 14, notes: 4) == "14 days · 4 project notes")
        #expect(RemoraSettingsLine.workingMemory(days: 1, notes: 1) == "1 day · 1 project note")
        #expect(RemoraSettingsLine.workingMemory(days: 0, notes: 2) == "0 days · 2 project notes")
        #expect(RemoraSettingsLine.workingMemory(days: 0, notes: 0) == "Nothing kept yet")
    }

    @Test func theLastLineSaysWhatLeavesTheMacOnAndWhatOffMeans() {
        #expect(RemoraSettingsText.lastLine(isOn: true).hasPrefix("Remora reads Claude's transcript files on this Mac only while it answers"))
        #expect(RemoraSettingsText.lastLine(isOn: true).hasSuffix("Its memory stays on this Mac."))
        #expect(RemoraSettingsText.lastLine(isOn: false) == "Off: Home starts with its band and Needs you, ⌘K has no Ask row, and the new-session page has no brief row. The memory stays until you clear it.")
    }

    @Test func theMemoryNoteChoiceIsAFileAsChosenOrRemoraMdInAFolder() {
        let folder = URL(fileURLWithPath: "/tmp/vault")
        #expect(RemoraNoteChoice.url(forChosen: folder, isDirectory: true).path == "/tmp/vault/Remora.md")
        let file = URL(fileURLWithPath: "/tmp/vault/Notes.md")
        #expect(RemoraNoteChoice.url(forChosen: file, isDirectory: false) == file)
    }

    /// Open goes to Obsidian only for a note inside a vault (a folder above it holds `.obsidian`); Remora's own folder is outside every
    /// vault, so its `Remora.md` opens in the app that opens the file. A temporary tree, never a real vault.
    @Test func openGoesToObsidianOnlyForANoteInsideAVault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-remora-vault-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("second brain", isDirectory: true)
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let inside = vault.appendingPathComponent("Remora/Remora.md")
        #expect(RemoraNoteChoice.vault(containing: inside)?.path == vault.standardizedFileURL.path)
        let link = try #require(RemoraNoteChoice.obsidianURL(forNote: inside))
        #expect(link.scheme == "obsidian" && link.absoluteString.contains("second%20brain/Remora/Remora.md"), "\(link)")
        #expect(RemoraMemoryText.openTitle(note: inside) == "Open in Obsidian")

        let outside = root.appendingPathComponent("remora/Remora.md")
        #expect(RemoraNoteChoice.vault(containing: outside) == nil && RemoraNoteChoice.obsidianURL(forNote: outside) == nil)
        #expect(RemoraMemoryText.openTitle(note: outside) == "Open" && RemoraMemoryText.openTitle(note: nil) == "Open")

        // A file named .obsidian is not a vault.
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try Data().write(to: plain.appendingPathComponent(".obsidian"))
        #expect(RemoraNoteChoice.vault(containing: plain.appendingPathComponent("Remora.md")) == nil)
    }

    @Test func theNotePathIsTheChosenFileElseRemoraMdInRemorasFolder() {
        let model = makeModel()
        #expect(model.remoraNoteURL == nil, "no host and no chosen file")
        let chosen = URL(fileURLWithPath: "/tmp/vault/Remora.md")
        model.setRemoraNoteFile(chosen)
        #expect(model.remoraNoteURL == chosen)
    }

    // MARK: The panels are a seam

    @Test func theNotePanelsSitBehindClosuresATestReplaces() {
        let navigation = SettingsNavigation()
        var opened: [URL] = []
        let chosen = URL(fileURLWithPath: "/tmp/chosen/Remora.md")
        navigation.noteActions = RemoraNoteActions(choose: { chosen }, open: { opened.append($0) })
        #expect(navigation.noteActions.choose() == chosen)
        navigation.noteActions.open(chosen)
        #expect(opened == [chosen])
    }
}
