import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomRemora
@testable import LoomCatalogUI

/// L3b, the views: Home with Remora hosted in a window nobody sees (never ordered front, so nothing reaches the screen), read from
/// the accessibility tree and its frames. The look against the reference is the end batch's on-screen check; these pin what Home
/// reports, what stays out of the tree, and that the brief, the fold and the field fit their panes.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct RemoraHomeRenderTests {
    // MARK: Hosting

    private func identifiers(in view: NSView) -> [String] {
        accessibilityElements(in: view).compactMap { element in
            let id = element.accessibilityIdentifier?() ?? ""
            return id.isEmpty ? nil : id
        }
    }

    private func labels(in view: NSView) -> [String] {
        accessibilityElements(in: view).compactMap { element in
            let label = element.accessibilityLabel?() ?? ""
            return label.isEmpty ? nil : label
        }
    }

    /// What VoiceOver can read of the page: labels, and the values static text exposes.
    private func spoken(in view: NSView) -> [String] {
        accessibilityElements(in: view).flatMap { element -> [String] in
            [InkAX.text(element, "accessibilityLabel"), InkAX.value(element), InkAX.text(element, "accessibilityTitle")].compactMap { $0 }.filter { !$0.isEmpty }
        }
    }

    private func frames(of id: String, in view: NSView) -> [CGRect] {
        accessibilityElements(in: view).filter { $0.accessibilityIdentifier?() == id }.compactMap { $0.accessibilityFrame?() }
    }

    private func hostHome(_ model: CatalogModel, width: CGFloat, height: CGFloat) -> (NSWindow, NSHostingController<HomeView>) {
        let hosting = NSHostingController(rootView: HomeView(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: width, height: height))
        window.isReleasedWhenClosed = false
        return (window, hosting)
    }

    private func settle(_ window: NSWindow, until condition: () -> Bool) async throws {
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if condition() { return }
        }
    }

    /// Three projects with a session each, a brief of three entries (one with a line to put in the draft, one proposed fact) and a
    /// host set to When I ask, so nothing asks by itself.
    private func briefRig(briefAgo: TimeInterval = 600, preferences: RemoraPreferences? = nil) async throws -> RemoraHomeRig {
        let rig = try await RemoraHomeRig.make(
            projectNames: ["loom", "api", "docs"],
            seeds: [.init(title: "Billing webhook", project: 0, ago: 7_200), .init(title: "Rate limiter", project: 1, ago: 9_000),
                    .init(title: "Release notes", project: 2, ago: 12_000)],
            preferences: preferences ?? RemoraPreferences(briefMode: .whenIAsk))
        try rig.keepBrief(
            text: "You left off in **loom**, where the billing webhook waits for a review, and in api, where the rate limiter needs a test.",
            chips: [(0, "Waits for review"), (1, "Needs a test"), (2, "Draft is ready")],
            drafts: [(0, "Check the signature path first.")], facts: ["The webhook secret rotates monthly."], ago: briefAgo)
        rig.model.showHome()
        return rig
    }

    private func settleBrief(_ window: NSWindow, _ view: NSView) async throws {
        try await settle(window) { self.identifiers(in: view).filter { $0 == "home-remora-tile" }.count >= 3 }
    }

    // MARK: The brief

    @Test(arguments: [CGSize(width: 940, height: 760), CGSize(width: 520, height: 900)])
    func theBriefShowsEveryBlockAndFitsItsPane(size: CGSize) async throws {
        enableAccessibilityTree()
        let rig = try await briefRig()
        defer { Task { await rig.finish() } }
        rig.model.remora.proposedFacts = ["The webhook secret rotates monthly."]
        let (window, hosting) = hostHome(rig.model, width: size.width, height: size.height)
        defer { window.close() }
        try await settleBrief(window, hosting.view)

        let found = identifiers(in: hosting.view)
        for id in ["home-remora", "home-remora-heading", "home-remora-when", "home-remora-sentence", "home-remora-field",
                   "home-remora-field-bar", "home-remora-proposal", "home-remora-footer", "home-remora-sources"] {
            #expect(found.contains(id), "\(id) is on Home at \(Int(size.width)) pt")
        }
        #expect(found.filter { $0 == "home-remora-tile" }.count == 3)
        #expect(!found.contains("home-band") && !found.contains("home-remora-none"), "Remora takes the band's place")
        #expect(!found.contains { $0.hasSuffix("-place") || $0.hasSuffix("-arrival") || $0.hasSuffix("-fold-slot") },
                "the places the art will fill are out of VoiceOver's tree: \(found)")
        #expect(labels(in: hosting.view).contains("Remora"), "one group named Remora")

        // Fit: the sentence has its two lines' room, the tiles stand inside the pane, the field is its 46 pt.
        let pane = window.frame.insetBy(dx: -1, dy: -1)
        let sentence = try #require(frames(of: "home-remora-sentence", in: hosting.view).first)
        let tiles = frames(of: "home-remora-tile", in: hosting.view)
        #expect(sentence.height > 14.5, "the sentence is drawn: \(sentence)")
        for tile in tiles { #expect(sentence.maxY - tile.maxY >= LoomTheme.Remora.sentenceRoom, "the sentence has room for two lines above the tiles") }
        for tile in tiles { #expect(pane.contains(tile), "a tile at \(Int(size.width)) pt is outside the pane: \(tile) in \(window.frame)") }
        let bar = try #require(frames(of: "home-remora-field-bar", in: hosting.view).first)
        #expect(abs(bar.height - LoomTheme.Remora.fieldHeight) < 1.5, "the field is \(LoomTheme.Remora.fieldHeight) pt: \(bar)")
        #expect(pane.contains(bar))
        // The field stands under the tiles (screen frames: higher is further up).
        for tile in tiles { #expect(tile.minY >= bar.maxY - 1, "the field is under the tiles: \(tile) \(bar)") }
    }

    @Test func theFoldKeepsTheHeadTheLinesAndNoTiles() async throws {
        enableAccessibilityTree()
        // The brief began two hours ago and the loom session ran after it: that entry was picked up, so the brief folds.
        let rig = try await RemoraHomeRig.make(
            projectNames: ["loom", "api"],
            seeds: [.init(title: "Billing webhook", project: 0, ago: 600), .init(title: "Rate limiter", project: 1, ago: 9_000)],
            preferences: RemoraPreferences(briefMode: .whenIAsk))
        defer { Task { await rig.finish() } }
        try rig.keepBrief(text: "You left off in loom and api.", chips: [(0, "Waits for review"), (1, "Needs a test")], ago: 7_200)
        rig.model.showHome()
        let (window, hosting) = hostHome(rig.model, width: 940, height: 700)
        defer { window.close() }
        try await settle(window) { self.identifiers(in: hosting.view).contains("home-remora-fold-head") }

        let found = identifiers(in: hosting.view)
        #expect(found.contains("home-remora-fold-head") && found.contains("home-remora-fold-line"), "\(found)")
        #expect(!found.contains("home-remora-tile") && !found.contains("home-remora-sentence") && !found.contains("home-remora-proposal"))
        #expect(found.contains("home-remora-field"), "the field stays under the fold")
        #expect(found.contains("home-remora-show-brief"), "the fold can bring the whole brief back")
        let pane = window.frame.insetBy(dx: -1, dy: -1)
        for line in frames(of: "home-remora-fold-line", in: hosting.view) { #expect(pane.contains(line)) }
    }

    // MARK: The other states

    @Test func whenIAskShowsTheCatalogsTilesWithOpenOnlyAndCatchMeUp() async throws {
        enableAccessibilityTree()
        let rig = try await RemoraHomeRig.make(
            projectNames: ["loom", "api"],
            seeds: [.init(title: "Billing webhook", project: 0, ago: 600), .init(title: "Rate limiter", project: 1, ago: 9_000)],
            preferences: RemoraPreferences(briefMode: .whenIAsk))
        defer { Task { await rig.finish() } }
        rig.model.showHome()
        let (window, hosting) = hostHome(rig.model, width: 940, height: 700)
        defer { window.close() }
        try await settle(window) { self.identifiers(in: hosting.view).filter { $0 == "home-remora-tile" }.count >= 2 }
        let found = identifiers(in: hosting.view)
        #expect(found.filter { $0 == "home-remora-tile" }.count == 2)
        #expect(found.contains("home-remora-state") && found.contains("home-remora-state-action"))
        #expect(!found.contains("home-remora-put-in-draft") && !found.contains("home-remora-next"), "a catalog tile has Open only")
        #expect(labels(in: hosting.view).contains("Catch Me Up"))
        #expect(!rig.ranAProcess)
    }

    @Test func aMissingLoginAndAFailedBriefSayTheirOwnWords() async throws {
        enableAccessibilityTree()
        let rig = try await RemoraHomeRig.make(seeds: [.init(title: "Billing", project: 0, ago: 600)],
                                               preferences: RemoraPreferences(briefMode: .whenIAsk))
        defer { Task { await rig.finish() } }
        rig.model.showHome()
        let (window, hosting) = hostHome(rig.model, width: 940, height: 700)
        defer { window.close() }

        rig.model.remora.lastFailure = .notLoggedIn
        try await settle(window) { self.spoken(in: hosting.view).contains(HomeRemoraText.notLoggedIn) }
        #expect(spoken(in: hosting.view).contains(HomeRemoraText.notLoggedIn))
        #expect(!identifiers(in: hosting.view).contains("home-remora-state-action"), "logging in is not a button here")

        rig.model.remora.lastFailure = .apiError
        try await settle(window) { self.spoken(in: hosting.view).contains(HomeRemoraText.couldNotAnswer) }
        #expect(spoken(in: hosting.view).contains(HomeRemoraText.couldNotAnswer))
        #expect(labels(in: hosting.view).contains("Try Again"))
    }

    @Test func aWaitingBriefSaysSoAndOffersCatchMeUpAnyway() async throws {
        enableAccessibilityTree()
        let rig = try await RemoraHomeRig.make(seeds: [.init(title: "Billing", project: 0, ago: 600)],
                                               preferences: RemoraPreferences(briefMode: .whenIAsk))
        defer { Task { await rig.finish() } }
        rig.model.showHome()
        rig.model.remora.lastBriefDecision = .wait(.windowLow(remaining: 0.05))
        let (window, hosting) = hostHome(rig.model, width: 940, height: 700)
        defer { window.close() }
        try await settle(window) { self.labels(in: hosting.view).contains("Catch Me Up Anyway") }
        #expect(labels(in: hosting.view).contains("Catch Me Up Anyway"))
        #expect(!rig.ranAProcess, "the brief waited")
    }

    @Test func aStoppedBriefAndAReadingBriefHaveTheirOwnLines() async throws {
        enableAccessibilityTree()
        let rig = try await RemoraHomeRig.make(seeds: [.init(title: "Billing", project: 0, ago: 600)],
                                               preferences: RemoraPreferences(briefMode: .whenIAsk))
        defer { Task { await rig.finish() } }
        rig.model.showHome()
        let (window, hosting) = hostHome(rig.model, width: 940, height: 700)
        defer { window.close() }

        rig.model.remora.stopped = .brief
        try await settle(window) { self.spoken(in: hosting.view).contains(HomeRemoraText.stoppedBrief) }
        #expect(spoken(in: hosting.view).contains(HomeRemoraText.stoppedBrief))

        rig.model.remora.stopped = nil
        rig.model.remora.phase = .briefing
        rig.model.remora.reading = RemoraReading(sessions: 6, projectNotes: 3)
        try await settle(window) { self.identifiers(in: hosting.view).contains("home-remora-reading") }
        let reading = HomeRemoraText.readingLine(RemoraReading(sessions: 6, projectNotes: 3))
        #expect(labels(in: hosting.view).contains { $0.contains(reading) } || identifiers(in: hosting.view).contains("home-remora-reading"))
        #expect(identifiers(in: hosting.view).contains("home-remora-stop"), "a call that runs can be stopped")
        rig.model.remora.phase = .idle
    }

    // MARK: Off, and before any session

    @Test func remoraOffGivesTheBandBack() async throws {
        enableAccessibilityTree()
        let rig = try await RemoraHomeRig.make(seeds: [.init(title: "Billing", project: 0, ago: 600)],
                                               preferences: RemoraPreferences(isOn: false))
        defer { Task { await rig.finish() } }
        rig.model.showHome()
        let (window, hosting) = hostHome(rig.model, width: 940, height: 700)
        defer { window.close() }
        try await settle(window) { self.identifiers(in: hosting.view).contains("home-band") }
        let found = identifiers(in: hosting.view)
        #expect(found.contains("home-band"))
        #expect(!found.contains { $0.hasPrefix("home-remora") }, "nothing of Remora with Remora off: \(found)")
        #expect(!labels(in: hosting.view).contains("Remora"))
    }

    @Test func beforeAnySessionHomeKeepsTheBandAndOneLineAboutRemora() async throws {
        enableAccessibilityTree()
        let rig = try await RemoraHomeRig.make(seeds: [], preferences: RemoraPreferences(briefMode: .whenIAsk))
        defer { Task { await rig.finish() } }
        rig.model.showHome()
        let (window, hosting) = hostHome(rig.model, width: 940, height: 700)
        defer { window.close() }
        try await settle(window) { self.identifiers(in: hosting.view).contains("home-remora-none") }
        let found = identifiers(in: hosting.view)
        #expect(found.contains("home-band") && found.contains("home-remora-none"))
        #expect(!found.contains("home-remora-field") && !found.contains("home-remora-tile"), "no field before a session")
        #expect(spoken(in: hosting.view).contains(HomeRemoraText.beforeAnySession))
    }

    // MARK: Excluded projects and deleted sessions

    @Test func anExcludedProjectIsNeverNamedAndASessionThatIsGoneHasNoTile() async throws {
        enableAccessibilityTree()
        let rig = try await RemoraHomeRig.make(
            projectNames: ["loom", "api"],
            seeds: [.init(title: "Billing webhook", project: 0, ago: 7_200), .init(title: "Rate limiter", project: 1, ago: 9_000)],
            preferences: RemoraPreferences(briefMode: .whenIAsk))
        defer { Task { await rig.finish() } }
        // The brief names both sessions and one that the catalog no longer has (a deletion removed it).
        let gone = UUID()
        let brief = RemoraKeptBrief(
            startedAt: rig.base.addingTimeInterval(-600), text: "You left off in loom and api.", cited: [],
            chips: [RemoraChip(sessionID: rig.sessions[0].uuidString, why: "Waits for review"),
                    RemoraChip(sessionID: rig.sessions[1].uuidString, why: "Needs a test"),
                    RemoraChip(sessionID: gone.uuidString, why: "Was deleted")],
            drafts: [], proposedFacts: [], readSessionIDs: rig.sessions, footer: "")
        try RemoraKeptBriefFile(directory: rig.remoraDirectory).write(brief)
        rig.model.showHome()
        let (window, hosting) = hostHome(rig.model, width: 940, height: 760)
        defer { window.close() }
        try await settle(window) { self.identifiers(in: hosting.view).filter { $0 == "home-remora-tile" }.count >= 2 }
        #expect(identifiers(in: hosting.view).filter { $0 == "home-remora-tile" }.count == 2, "a session that is gone has no tile")
        #expect(!labels(in: hosting.view).contains { $0.contains("Was deleted") })

        // Excluding a project takes its tile away from the brief and from the catalog's list.
        var preferences = rig.model.remora.preferences
        preferences.excludedProjects = [rig.projects[1].id]
        rig.model.remora.install(preferences: preferences, persist: { _ in })
        try await settle(window) { self.identifiers(in: hosting.view).filter { $0 == "home-remora-tile" }.count == 1 }
        #expect(identifiers(in: hosting.view).filter { $0 == "home-remora-tile" }.count == 1)
        #expect(!labels(in: hosting.view).contains { $0.contains("Rate limiter") || $0.contains("Needs a test") }, "the excluded project is never named")
    }
}
