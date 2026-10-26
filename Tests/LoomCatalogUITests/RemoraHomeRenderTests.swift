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

        // The failures of a brief (Home's brief area shows only those).
        rig.model.remora.call = RemoraModelState.Call(kind: .brief, door: .home)
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

    // MARK: Reading, and the answer under the field

    /// Where the pictures go: `LOOM_HOME_RENDER_DIR`, as `home-remora-<reading|answer>-<ink|paper>.png`, to be set beside the
    /// reference's `#brief` document. Without it the tests only check the tree and the frames.
    private var renderDirectory: URL? {
        ProcessInfo.processInfo.environment["LOOM_HOME_RENDER_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    /// Any view in a window nobody sees, on the canvas, in Ink (dark) or Paper (light).
    private func host<Content: View>(_ content: Content, size: CGSize, dark: Bool) -> (NSWindow, NSView) {
        let hosting = NSHostingController(rootView: content.frame(width: size.width, height: size.height, alignment: .top)
            .background(LoomTheme.Surface.canvas).environment(\.colorScheme, dark ? .dark : .light))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        return (window, hosting.view)
    }

    private func picture(_ view: NSView, name: String, dark: Bool) throws {
        guard let directory = renderDirectory else { return }
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("home-remora-\(name)-\(dark ? "ink" : "paper").png"))
    }

    /// The fake's morning brief over the rig's three sessions: a short sentence and a chip for each. It streams slowly enough that
    /// Home is seen reading.
    private func slowBriefScript(_ sessions: [UUID]) -> [String: String] {
        let s = sessions.map(\.uuidString)
        let whys = ["Waits for review", "Needs a test", "Draft is ready"]
        let nexts = ["the signature path.", "the burst test.", "the changelog."]
        let chips = (0..<3).map { "{\"session\":\"\(s[$0])\",\"why\":\"\(whys[$0])\",\"next\":\"\(nexts[$0])\"}" }.joined(separator: ",")
        let answer = "You left off in **loom**, where the billing webhook waits for a review.\n\n```remora\n"
            + "{\"cited\":[\"\(s[0])\"],\"chips\":[\(chips)],\"drafts\":[],\"facts\":[]}\n```\n"
        return ["LOOM_FAKE_REMORA_ANSWER": answer, "LOOM_FAKE_REMORA_DELAY_MS": "40"]
    }

    /// While Remora writes a brief Home shows three empty frames in the tiles' places, none of the catalog's tiles and none of an
    /// older brief's (DESIGN §9 Reading and writing); the brief's own tiles then take the frames' places, and the field under them
    /// does not move.
    @Test(arguments: [false, true])
    func readingShowsFramesAndTheBriefsTilesTakeTheirPlaces(olderBrief: Bool) async throws {
        enableAccessibilityTree()
        let rig = try await RemoraHomeRig.make(
            projectNames: ["loom", "api", "docs"],
            seeds: [.init(title: "Billing webhook", project: 0, ago: 7_200), .init(title: "Rate limiter", project: 1, ago: 9_000),
                    .init(title: "Release notes", project: 2, ago: 12_000)],
            preferences: RemoraPreferences(briefMode: .whenIAsk), scriptFor: slowBriefScript)
        defer { Task { await rig.finish() } }
        if olderBrief { try rig.keepBrief(text: "An older brief.", chips: [(0, "Older"), (1, "Older"), (2, "Older")], ago: 3_600) }
        rig.model.showHome()
        let (window, hosting) = hostHome(rig.model, width: 940, height: 900)
        defer { window.close() }
        try await settle(window) { self.identifiers(in: hosting.view).filter { $0 == "home-remora-tile" }.count >= 3 }
        #expect(identifiers(in: hosting.view).filter { $0 == "home-remora-tile" }.count == 3, "the catalog's or the older brief's tiles")

        #expect(HomeRemoraCalls.catchMeUp(rig.model, ui: HomeRemoraUI()))
        try await settle(window) { self.identifiers(in: hosting.view).contains("home-remora-stop") }
        #expect(rig.model.remora.phase == .briefing, "the brief is still being written")
        let found = identifiers(in: hosting.view)
        #expect(!found.contains("home-remora-tile") && !found.contains("home-remora-open"), "no tile while reading: \(found)")
        let readingBar = try #require(frames(of: "home-remora-field-bar", in: hosting.view).first)
        let sentence = try #require(frames(of: "home-remora-reading", in: hosting.view).first
                                    ?? frames(of: "home-remora-sentence", in: hosting.view).first)
        // The frames hold the tiles' room: the field stands a tile's height and the grid's top gap under the sentence's room.
        #expect(sentence.maxY - readingBar.maxY >= LoomTheme.Remora.sentenceRoom + LoomTheme.Remora.tilesTop
                + LoomTheme.Remora.readingFrameHeight, "the frames keep the tiles' room: \(sentence) \(readingBar)")

        await rig.model.remora.settle()
        try await settle(window) {
            self.identifiers(in: hosting.view).filter { $0 == "home-remora-tile" }.count >= 3
                && self.identifiers(in: hosting.view).filter { $0 == "home-remora-next" }.count >= 3
        }
        let landed = identifiers(in: hosting.view)
        #expect(landed.filter { $0 == "home-remora-tile" }.count == 3 && landed.filter { $0 == "home-remora-next" }.count == 3,
                "the brief's own tiles, each with its Next: \(landed)")
        #expect(!spoken(in: hosting.view).contains { $0.contains("An older brief") }, "nothing of the older brief")
        let tiles = frames(of: "home-remora-tile", in: hosting.view)
        for tile in tiles {
            #expect(abs(tile.height - LoomTheme.Remora.readingFrameHeight) < 1, "a frame is a tile's height: \(tile.height)")
        }
        let bar = try #require(frames(of: "home-remora-field-bar", in: hosting.view).first)
        #expect(abs(bar.minY - readingBar.minY) < 1, "the field does not move when the tiles land: \(readingBar) → \(bar)")
    }

    /// The pictures of the reading frames, in Ink and Paper (the phase held, no call made).
    @Test func theReadingFramesDrawInInkAndPaper() async throws {
        enableAccessibilityTree()
        let rig = try await RemoraHomeRig.make(
            projectNames: ["loom", "api"],
            seeds: [.init(title: "Billing webhook", project: 0, ago: 600), .init(title: "Rate limiter", project: 1, ago: 9_000)],
            preferences: RemoraPreferences(briefMode: .whenIAsk))
        defer { Task { await rig.finish() } }
        rig.model.showHome()
        rig.model.remora.phase = .briefing
        rig.model.remora.reading = RemoraReading(sessions: 6, projectNotes: 3)
        defer { rig.model.remora.phase = .idle }
        for dark in [true, false] {
            let (window, view) = host(HomeView(model: rig.model), size: CGSize(width: 1_100, height: 760), dark: dark)
            defer { window.close() }
            try await settle(window) { self.identifiers(in: view).contains("home-remora-reading") }
            #expect(identifiers(in: view).contains("home-remora-reading") && !identifiers(in: view).contains("home-remora-tile"))
            try picture(view, name: "reading", dark: dark)
        }
        #expect(!rig.ranAProcess)
    }

    /// Home's section as `HomeView` holds it, with the test's own `HomeRemoraUI`, reading for itself as Home does.
    private struct SectionHost: View {
        let model: CatalogModel
        let ui: HomeRemoraUI
        let reads: HomeRemoraReads

        var body: some View {
            ScrollView {
                HomeRemoraSection(model: model, paneWidth: 1_100, ui: ui, reads: reads)
            }
            .task(id: model.homeRemoraReadKey) { await reads.read(model: model) }
        }
    }

    private func answerRig() async throws -> RemoraHomeRig {
        try await RemoraHomeRig.make(
            projectNames: ["loom", "backend-api"],
            seeds: [.init(title: "Migrate auth to JWT", project: 1, ago: 20_000), .init(title: "Port the sidebar to Ink tokens", project: 0, ago: 3_600)],
            preferences: RemoraPreferences(briefMode: .whenIAsk),
            scriptFor: { sessions in
                let id = sessions[0].uuidString
                return ["LOOM_FAKE_REMORA_ANSWER": "**Migrate auth to JWT** moved the token check into `middleware/auth.py` yesterday at 22:40; nothing in loom touched it.\n\n```remora\n{\"cited\":[\"\(id)\"],\"chips\":[{\"session\":\"\(id)\",\"why\":\"Moved the token check\"}],\"drafts\":[],\"facts\":[]}\n```\n"]
            })
    }

    /// A question from Home's field (`HomeRemoraCalls.ask` with the section's `HomeRemoraUI`) is answered under the field: the card
    /// with the answer's text and its chip (DESIGN §20 The answer under the field), in Ink and Paper.
    @Test func aFieldQuestionIsAnsweredInTheCardWithItsChip() async throws {
        enableAccessibilityTree()
        let rig = try await answerRig()
        defer { Task { await rig.finish() } }
        rig.model.showHome()
        let ui = HomeRemoraUI()
        let reads = HomeRemoraReads(baselineUndo: rig.model.remora.lastUndo)
        #expect(HomeRemoraCalls.ask(rig.model, ui: ui, "which session touched the auth middleware?"))
        await rig.model.remora.settle()
        #expect(rig.model.remora.lastAnswer?.question == "which session touched the auth middleware?")
        for dark in [true, false] {
            let (window, view) = host(SectionHost(model: rig.model, ui: ui, reads: reads), size: CGSize(width: 1_100, height: 760), dark: dark)
            defer { window.close() }
            try await settle(window) { self.identifiers(in: view).contains("home-remora-chip") }
            let found = identifiers(in: view)
            #expect(found.contains("home-remora-answer") && found.contains("home-remora-answer-text"), "\(found)")
            #expect(found.contains("home-remora-chip") && labels(in: view).contains("Open Migrate auth to JWT"), "the answer's chip: \(found)")
            #expect(found.contains("home-remora-answer-footer"))
            #expect(spoken(in: view).contains { $0.contains("moved the token check into") }, "the answer's text")
            let card = try #require(frames(of: "home-remora-answer", in: view).first)
            let bar = try #require(frames(of: "home-remora-field-bar", in: view).first)
            #expect(card.maxY <= bar.minY + 1, "the card stands under the field: \(card) \(bar)")
            try picture(view, name: "answer", dark: dark)
        }
    }

    /// An answer's chip with a draft always has the Put in Draft button, never a label that stands in for it: a result left from
    /// before Home's read is gone, and the button says what it does (a session that runs in the terminal: Copy to Clipboard).
    @Test func anAnswersChipKeepsItsButtonAfterAResult() async throws {
        enableAccessibilityTree()
        let rig = try await RemoraHomeRig.make(
            projectNames: ["loom"], seeds: [.init(title: "Migrate auth to JWT", project: 0, ago: 3_600)],
            preferences: RemoraPreferences(briefMode: .whenIAsk),
            scriptFor: { sessions in
                let id = sessions[0].uuidString
                return ["LOOM_FAKE_REMORA_ANSWER": "**Migrate auth to JWT** waits.\n\n```remora\n{\"cited\":[\"\(id)\"],\"chips\":[{\"session\":\"\(id)\",\"why\":\"Waits\"}],\"drafts\":[{\"session\":\"\(id)\",\"text\":\"Run the checks.\"}],\"facts\":[]}\n```\n"]
            })
        defer { Task { await rig.finish() } }
        rig.model.showHome()
        let ui = HomeRemoraUI()
        let reads = HomeRemoraReads(baselineUndo: rig.model.remora.lastUndo)
        #expect(HomeRemoraCalls.ask(rig.model, ui: ui, "what waits?"))
        await rig.model.remora.settle()
        ui.placed[rig.sessions[0]] = HomeRemoraUI.Placed(result: .copied(.terminal), line: "Run the checks.", read: reads.generation)
        let (window, view) = host(SectionHost(model: rig.model, ui: ui, reads: reads), size: CGSize(width: 1_100, height: 760), dark: true)
        defer { window.close() }
        try await settle(window) { self.identifiers(in: view).contains("home-remora-put-in-draft") }
        #expect(identifiers(in: view).contains("home-remora-put-in-draft"), "the chip's button: \(identifiers(in: view))")
        #expect(labels(in: view).contains("Copy to Clipboard"), "\(labels(in: view))")
    }

    /// A question asked through the model alone (⌘K's ↵, the evidence command `remora-ask`) is no question from Home's field: Home
    /// draws no card for it.
    @Test func aQuestionAskedOnlyThroughTheModelShowsNoCardOnHome() async throws {
        enableAccessibilityTree()
        let rig = try await answerRig()
        defer { Task { await rig.finish() } }
        rig.model.showHome()
        let (window, hosting) = hostHome(rig.model, width: 940, height: 760)
        defer { window.close() }
        try await settle(window) { self.identifiers(in: hosting.view).contains("home-remora-field") }
        #expect(rig.model.askRemora("which session touched the auth middleware?"))
        await rig.model.remora.settle()
        #expect(rig.model.remora.lastAnswer?.question == "which session touched the auth middleware?", "the model answered")
        try await settle(window) { false }
        let found = identifiers(in: hosting.view)
        #expect(found.contains("home-remora-field"))
        #expect(!found.contains("home-remora-answer") && !found.contains("home-remora-chip"), "no card for a model-only question: \(found)")
    }
}
