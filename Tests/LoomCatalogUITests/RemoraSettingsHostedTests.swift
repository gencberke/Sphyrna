import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomRemora
@testable import LoomCatalogUI

/// L3b: what needs a view, hosted in a window nobody sees (never ordered front): Remora's tab at the window's 680×520, and the memory
/// sheet's frame under the band. A real click, the focus on Done and the scrim need a key window on screen: they are the end batch's checks.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(4)))
struct RemoraSettingsHostedTests {
    private let size = NSSize(width: LoomTheme.Settings.width, height: LoomTheme.Settings.height)

    private func settingsView(_ model: CatalogModel, navigation: SettingsNavigation) -> SettingsView {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SettingsView(model: model, usage: nil, navigation: navigation,
                            about: SettingsAbout(version: "Version 1.6.0", dataFolder: home.appendingPathComponent("Library/Application Support/Loom"),
                                                 claudeProfile: nil))
    }

    private func host<V: View>(_ view: V, size: NSSize? = nil) -> (NSWindow, NSHostingController<some View>) {
        enableAccessibilityTree()
        let size = size ?? self.size
        let hosting = NSHostingController(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        return (window, hosting)
    }

    private func settle(_ window: NSWindow, until ready: () -> Bool = { true }) async throws {
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if ready() { break }
        }
        try await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// A rect from the accessibility tree (screen coordinates) in the window's: the left edge, the right edge, the distance of the top
    /// and of the bottom from the window's top.
    private func local(_ rect: NSRect, in window: NSWindow, height: CGFloat) -> (minX: CGFloat, maxX: CGFloat, top: CGFloat, bottom: CGFloat) {
        let frame = window.convertFromScreen(rect)
        return (frame.minX, frame.maxX, height - frame.maxY, height - frame.minY)
    }

    private func elements(in controller: NSViewController) -> [AnyObject] { accessibilityElements(in: controller.view) }

    private func labelled(_ label: String, in controller: NSViewController) -> [AnyObject] {
        elements(in: controller).filter { InkAX.label($0) == label || InkAX.value($0) == label }
    }

    private func isEnabled(_ element: AnyObject) -> Bool {
        element.isAccessibilityEnabled?() ?? true
    }

    // MARK: Remora's tab

    /// Remora's tab at 680×520, on and off: the page scrolls under the band, its texts and controls stay inside the 32 inset, a line
    /// of help is at most 380 wide and the last line at most 560, and every project has its check.
    @Test(arguments: [true, false]) func theTabFitsTheWindowAndEveryProjectHasACheck(remoraOn: Bool) async throws {
        let rig = try await RemoraMemoryRig.withProjects(["loom", "second-brain", "backend-api", "website"])
        defer { rig.finish() }
        rig.model.setRemoraOn(remoraOn)
        let navigation = SettingsNavigation(section: .remora)
        let (window, hosting) = host(settingsView(rig.model, navigation: navigation))
        defer { window.close() }
        try await settle(window) { !self.labelled("website", in: hosting).isEmpty }

        let all = elements(in: hosting)
        let page = LoomTheme.Settings.bodyInset
        for element in all where element.accessibilityFrame().width > 0 {
            guard let role = element.accessibilityRole?(),
                  [.staticText, .popUpButton, .menuButton, .checkBox, .button].contains(role),
                  !(InkAX.value(element) ?? InkAX.label(element)).isEmpty else { continue }
            let place = local(element.accessibilityFrame(), in: window, height: size.height)
            // Tab buttons live in the band, centred; the page's own parts stay inside the inset.
            guard place.top > LoomTheme.Settings.bandHeight else { continue }
            #expect(place.minX >= page - 1 && place.maxX <= size.width - page + 1,
                    "\(InkAX.label(element)) runs from \(place.minX) to \(place.maxX)")
        }

        func width(of text: String) throws -> CGFloat {
            let match = try #require(all.first { $0.accessibilityRole?() == .staticText && (InkAX.value($0) ?? InkAX.label($0)) == text },
                                     "\(text.prefix(24))… is on the page")
            return match.accessibilityFrame().width
        }
        #expect(try width(of: RemoraSettingsText.switchDetail) <= LoomTheme.Settings.helpMaxWidth + 1)
        #expect(try width(of: RemoraSettingsText.lastLine(isOn: remoraOn)) <= LoomTheme.RemoraTab.noteMaxWidth + 1)

        for name in ["loom", "second-brain", "backend-api", "website"] {
            let box = labelled(name, in: hosting).first { $0.accessibilityRole?() == .checkBox }
            #expect(box != nil, "a check for \(name)")
            #expect(box.map { InkAX.value($0) == "1" } == true, "\(name) is read by default")
        }
    }

    /// The controls below the band that Off turns off: every popup, segment, check, button and the stepper, and not the switch.
    private func rowControls(in controller: NSViewController, window: NSWindow) -> [AnyObject] {
        elements(in: controller).filter { element in
            guard element.accessibilityFrame().width > 0,
                  local(element.accessibilityFrame(), in: window, height: size.height).top > LoomTheme.Settings.bandHeight else { return false }
            let role = element.accessibilityRole?()
            if role == .menuButton || role == .popUpButton { return InkAX.identifier(element).isEmpty }
            if role == .checkBox { return InkAX.label(element) != "Remora" }
            if role == .button { return !InkAX.label(element).isEmpty }
            return role == .unknown && InkAX.label(element) == RemoraSettingsText.thresholdTitle
        }
    }

    @Test func offDimsEveryRowButTheSwitch() async throws {
        let rig = try await RemoraMemoryRig.withProjects(["loom"])
        defer { rig.finish() }
        let navigation = SettingsNavigation(section: .remora)
        let (window, hosting) = host(settingsView(rig.model, navigation: navigation))
        defer { window.close() }
        try await settle(window) { !self.labelled("loom", in: hosting).isEmpty }
        let on = rowControls(in: hosting, window: window)
        // Four popups' worth are the model, effort and language (three), two segments, the project's check, Show…, Clear…, Choose…, Open,
        // the proposals switch and the stepper.
        #expect(on.count >= 12, "found \(on.count) controls")
        let answering = on.filter { isEnabled($0) }.count
        #expect(answering == on.count, "\(answering) of \(on.count) controls answer while Remora is on")
        rig.model.setRemoraOn(false)
        try await settle(window)
        let off = rowControls(in: hosting, window: window)
        let answeringOff = off.filter { isEnabled($0) }.map { "\(InkAX.label($0)) \(InkAX.value($0) ?? "")" }
        #expect(answeringOff.isEmpty, "these still answer while Remora is off: \(answeringOff)")
        let switches = labelled("Remora", in: hosting).filter { $0.accessibilityRole?() == .checkBox }
        #expect(!switches.isEmpty && switches.allSatisfy { isEnabled($0) }, "the switch stays")
    }

    // MARK: The memory sheet

    private func seededJournal(_ count: Int) -> [RemoraJournalEntry] {
        (0..<count).map { index in
            RemoraJournalEntry(id: String(format: "a%07x", index), date: Date().addingTimeInterval(-Double(index)), kind: .question,
                               question: "Which session touched the auth middleware, number \(index)?",
                               answer: "I named Migrate auth to JWT and Rate limiter tests, and the second one stopped at step 4.")
        }
    }

    /// The sheet comes down under the band, is centred and 560 wide, and never reaches the window's bottom edge: a pane taller than the
    /// room scrolls instead.
    @Test(arguments: RemoraMemoryTab.allCases) func theSheetSitsUnderTheBandAt560AndStaysInTheWindow(tab: RemoraMemoryTab) async throws {
        let rig = try await RemoraMemoryRig.withProjects(["loom", "second-brain", "backend-api"])
        defer { rig.finish() }
        try await rig.seed(journal: seededJournal(40), notes: ["The Ink sidebar port is at step 5 of 6 on ui/ink-sidebar.\nNext: the footer tokens.",
                                                               "Thesis outline finished.", "Migrate auth to JWT stopped."])
        let navigation = SettingsNavigation(section: .general)
        navigation.openRemoraMemory(tab: tab)
        let (window, hosting) = host(settingsView(rig.model, navigation: navigation))
        defer { window.close() }
        let marker = ["Asked “Which session", "The Ink sidebar port", "Open in Obsidian"][RemoraMemoryTab.allCases.firstIndex(of: tab)!]
        try await settle(window) {
            self.elements(in: hosting).contains { (InkAX.value($0) ?? InkAX.label($0)).contains(marker) }
        }
        let identifier = "settings-sheet-remora-memory"
        let sheet = try #require(elements(in: hosting).first { InkAX.identifier($0) == identifier }, "the sheet is in the tree")
        let place = local(sheet.accessibilityFrame(), in: window, height: size.height)
        #expect(abs((place.maxX - place.minX) - 560) <= 1, "\(place.maxX - place.minX) wide")
        #expect(abs((place.minX + place.maxX) / 2 - size.width / 2) <= 1, "centred")
        #expect(abs(place.top - LoomTheme.Settings.bandHeight) <= 1, "under the band: \(place.top)")
        #expect(place.bottom <= size.height - LoomTheme.MemorySheet.windowBottom + 1, "bottom at \(place.bottom) of \(size.height)")
        if tab == .journal { #expect(place.bottom - place.top > 300, "forty lines fill the room and scroll") }
        // The tabs and both buttons are there.
        for label in ["Journal", "Project notes", "Remora.md", "Clear Working Memory…", "Done"] {
            #expect(!labelled(label, in: hosting).isEmpty, "\(label) is in the sheet")
        }
    }

    /// A session deleted while the sheet is open leaves nothing of itself there: Remora forgets it before the deletion's record goes,
    /// and the sheet reads the memory again when the deletion ends (the product contract).
    @Test func aSessionDeletedWhileTheSheetIsOpenLeavesNoLineBehind() async throws {
        let rig = try RemoraMemoryRig()
        defer { rig.finish() }
        let deleted = UUID()
        try await rig.seed(journal: [
            RemoraJournalEntry(id: "aaaa0001", date: Date(), kind: .question, question: "What did the gone session do?", answer: "a",
                               sessions: [deleted]),
            RemoraJournalEntry(id: "bbbb0002", date: Date(), kind: .question, question: "What stays?", answer: "b"),
        ], notes: [])
        let navigation = SettingsNavigation(section: .general)
        navigation.openRemoraMemory(tab: .journal)
        let (window, hosting) = host(settingsView(rig.model, navigation: navigation))
        defer { window.close() }
        func shows(_ text: String) -> Bool { elements(in: hosting).contains { (InkAX.value($0) ?? InkAX.label($0)).contains(text) } }
        try await settle(window) { shows("What did the gone session do?") }
        try #require(shows("What did the gone session do?") && shows("What stays?"))

        // The deletion runs: its call is in flight, the forgetters run, then it ends.
        rig.model.deletions.inProgress.insert(deleted)
        try await settle(window)
        try await rig.host.forgetter.forget(sessionID: deleted, providerIDs: [])
        rig.model.deletions.inProgress.remove(deleted)
        try await settle(window) { !shows("What did the gone session do?") }
        #expect(!shows("What did the gone session do?"), "the deleted session's line is gone from the open sheet")
        #expect(shows("What stays?"))
    }

    @Test func theClearQuestionIsA420SheetOverTheTab() async throws {
        let rig = try await RemoraMemoryRig.withProjects(["loom"])
        defer { rig.finish() }
        let identifier = "settings-sheet-remora-clear"
        let navigation = SettingsNavigation(section: .remora)
        navigation.askToClearRemoraMemory(fromMemorySheet: false)
        let (window, hosting) = host(settingsView(rig.model, navigation: navigation))
        defer { window.close() }
        try await settle(window) { self.elements(in: hosting).contains { InkAX.identifier($0) == identifier } }
        let sheet = try #require(elements(in: hosting).first { InkAX.identifier($0) == identifier })
        let place = local(sheet.accessibilityFrame(), in: window, height: size.height)
        #expect(abs((place.maxX - place.minX) - 420) <= 1)
        for label in ["Cancel", "Clear Working Memory"] { #expect(!labelled(label, in: hosting).isEmpty, "\(label) is in the question") }
    }
}
