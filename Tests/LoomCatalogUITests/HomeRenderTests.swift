import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// V05, the views: Home hosted in a window nobody sees, at the two panel widths of the evidence screenshots,
/// reports every block it should and no block it should not (read from the accessibility tree).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct HomeRenderTests {
    typealias HomeIntents = HomeTests.HomeIntents

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

    private func frame(of id: String, in view: NSView) -> CGRect? {
        accessibilityElements(in: view).first { $0.accessibilityIdentifier?() == id }.flatMap { $0.accessibilityFrame?() }
    }

    /// Hosts `HomeView` unshown. The window is never ordered front, so no test puts anything on screen.
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

    private func settle(_ window: NSWindow, until condition: () -> Bool = { true }) async throws {
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if condition() { return }
        }
    }

    /// A project with sessions in the states Home lists, one session Quit cut short and plan limits.
    private func populated(intents: HomeIntents) async throws -> ListRig {
        let rig = try await ListRig.make(projects: 1, perProject: 4, unassigned: 0, mode: .activity)
        rig.model.intents = intents // weak: the test holds it
        let ids = try #require(rig.ids[rig.projects[0].id])
        for id in ids.prefix(3) { try await rig.feed(.runStarted(UUID()), for: id) }
        try await rig.feed(.status(ProviderWorkState(activity: .waitingForApproval)), for: ids[0])
        try await rig.feed(.reason(StatusReason(.approval(tool: "Bash"), detail: "git push origin fix/webhook-sig")), for: ids[0])
        try await rig.feed(.reason(StatusReason(.turnDone, detail: "12 tests added")), for: ids[1])
        try await rig.feed(.status(ProviderWorkState(activity: .turnComplete)), for: ids[1])
        let leader = ProcessIdentity(pid: 7, startSeconds: 1, startMicroseconds: 2)
        let cut = ManagedSession(provider: .claude, workingDirectory: rig.projects[0].path)
        let now = Date()
        try await rig.catalog.insertSession(cut, title: "Backfill script", createdAt: now.addingTimeInterval(-7_200),
                                            lastUsedAt: now.addingTimeInterval(-3_600), lifecycle: .idle,
                                            projectID: rig.projects[0].id)
        let run = ManagedRun(id: UUID(), leader: leader, startedAt: now.addingTimeInterval(-7_000), state: .running,
                             exitStatus: nil, descendants: [leader])
        try await rig.catalog.startRun(run, sessionID: cut.id)
        try await rig.catalog.finishRun(run.id, endedAt: now.addingTimeInterval(-3_600), reason: .applicationQuit, exitStatus: nil)

        let limits = FakeLimits()
        limits.setAnswer(PlanLimits(
            fiveHour: PlanLimitWindow(usedPercent: 38, resetsAt: now.addingTimeInterval(3 * 3_600)),
            weekly: PlanLimitWindow(usedPercent: 59, resetsAt: now.addingTimeInterval(4 * 86_400)), fetchedAt: now))
        let index = FakeUsageIndex()
        index.setTokens(1_200_000)
        let usage = UsageModel(index: index, limits: limits, timeZone: TimeZone(identifier: "UTC")!)
        rig.model.usage = usage
        usage.refresh(reason: .launch)
        await usage.settle()
        rig.model.showHome()
        return rig
    }

    @Test(arguments: [CGSize(width: 940, height: 740), CGSize(width: 520, height: 900)])
    func homeShowsEveryBlockAtBothPanelWidths(size: CGSize) async throws {
        enableAccessibilityTree()
        let intents = HomeIntents()
        let rig = try await populated(intents: intents)
        defer { rig.cleanup(); withExtendedLifetime(intents) {} }
        let (window, hosting) = hostHome(rig.model, width: size.width, height: size.height)
        defer { window.close() }
        try await settle(window) { self.identifiers(in: hosting.view).contains("home-continue") }

        let found = Set(identifiers(in: hosting.view))
        for id in ["home", "home-needs-you", "home-finished", "home-limits", "home-today", "home-continue"] {
            #expect(found.contains(id), "\(id) is on Home at \(Int(size.width)) pt")
        }
        #expect(!found.contains("home-start"), "Home has no start box any more (V19)")
        #expect(!found.contains("home-nothing-waiting") && !found.contains("home-connect-notice") && !found.contains("home-empty-catalog"))
        let said = labels(in: hosting.view)
        #expect(said.contains("Needs you, 1") && said.contains("Finished, not read, 1"))
        #expect(said.contains { $0.hasPrefix("Plan limits, 5-hour window") && $0.contains("Weekly") }, "the plan limits card is one element")
        #expect(!said.contains { $0.hasPrefix("5-hour window") }, "its meters are not read one by one")
        #expect(said.contains { $0.hasPrefix("Today, ") }, "today's figures are one line")

        // The band says the state in one sentence, from the same counts as the lists and the menu bar.
        let board = rig.model.homeBoard()
        let sentence = HomeBandText.Sentence(working: rig.model.homeWorkingCount(), needsYou: board.count).text
        #expect(board.count == 2 && said.contains(sentence), "the band reads '\(sentence)'")
        #expect(found.contains("home-band") && found.contains("home-date") && found.contains("home-sentence"))

        // Continue is the lists' first card in both layouts; the side cards sit beside the lists, or under them when narrow.
        let continueFrame = try #require(frame(of: "home-continue", in: hosting.view))
        let needsFrame = try #require(frame(of: "home-needs-you", in: hosting.view))
        let limitsFrame = try #require(frame(of: "home-limits", in: hosting.view))
        #expect(continueFrame.midY > needsFrame.midY, "Continue is above Needs you at \(Int(size.width)) pt")
        if HomeLayout.isWide(paneWidth: size.width) {
            #expect(limitsFrame.minX >= needsFrame.maxX && limitsFrame.midY > needsFrame.minY, "beside the lists: \(limitsFrame) \(needsFrame)")
        } else {
            #expect(limitsFrame.midY < needsFrame.midY, "under the lists: \(limitsFrame) \(needsFrame)")
        }

        // The actions show on hover and focus only, and are the rows' accessibility actions at all times.
        func actions(_ id: String) -> [Set<String>] {
            accessibilityElements(in: hosting.view).filter { $0.accessibilityIdentifier?() == id }.map { element in
                Set((element.accessibilityCustomActions?() ?? []).map(\.name))
            }
        }
        #expect(actions("home-entry").contains(["Open Session", "Mark as Read"] as Set), "a finished turn: \(actions("home-entry"))")
        #expect(actions("home-entry").contains(["Open Session"] as Set), "a session that waits has nothing to mark read")
        #expect(actions("home-continue-entry") == [["Resume"] as Set], "\(actions("home-continue-entry"))")
    }

    @Test func homeWithNothingToReportKeepsTheNeedsYouCardEmptyAndSaysSoInTheBand() async throws {
        enableAccessibilityTree()
        let rig = try await ListRig.make(projects: 1, perProject: 2, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        rig.model.showHome()
        let (window, hosting) = hostHome(rig.model, width: 940, height: 740)
        defer { window.close() }
        try await settle(window) { self.identifiers(in: hosting.view).contains("home-needs-you") }
        let found = Set(identifiers(in: hosting.view))
        // The "Nothing needs you" card went (DESIGN §9): the Needs you card stays, empty, with the line that says what appears there.
        #expect(found.contains("home-needs-you") && found.contains("home-needs-you-empty") && !found.contains("home-start"))
        #expect(!found.contains("home-nothing-waiting") && !found.contains("home-finished") && !found.contains("home-continue"))
        #expect(!found.contains("home-limits") && !found.contains("home-no-claude"), "no usage model, no plan limits")
        let said = labels(in: hosting.view)
        #expect(said.contains("Needs you"), "the empty card's heading has no count")
        #expect(said.contains("Nothing is working or waiting."), "the band says it")
    }

    @Test func anEmptyCatalogShowsTheAddProjectStateAndNoStartBox() async throws {
        enableAccessibilityTree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-home-empty-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: try SessionCatalog(url: root.appendingPathComponent("c.sqlite3")),
                                 events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        await model.start()
        await model.stopAndWait()
        await model.settle()
        model.showHome()
        let (window, hosting) = hostHome(model, width: 940, height: 740)
        defer { window.close(); model.stop() }
        try await settle(window) { self.identifiers(in: hosting.view).contains("home-add-project") }
        let found = Set(identifiers(in: hosting.view))
        // The state is the add-project action beside a new-session action; no start box, no notice.
        #expect(found.contains("home-add-project") && found.contains("home-new-session"))
        let mainAction = try #require(frame(of: "home-add-project", in: hosting.view))
        #expect(abs(mainAction.height - 36) <= 0.5, "the empty state's main action is \(mainAction.height) pt")
        #expect(!found.contains("home-start") && !found.contains("home-no-claude") && !found.contains("home-check-again"))
    }

    /// D-69: the first-run Home lists Codex in every build. Where the build cannot start it the button is disabled and
    /// the reason is on screen; where it can, the button works as before and no reason is drawn.
    @Test func theEmptyHomeShowsCodexDisabledWithItsReasonInABuildThatCannotStartIt() async throws {
        enableAccessibilityTree()
        let intents = HomeIntents()
        defer { withExtendedLifetime(intents) {} }
        func state(_ providers: Set<ManagedSession.Provider>) async throws -> (enabled: Bool?, reason: Bool, mark: Bool) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-home-codex-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = CatalogModel(catalog: try SessionCatalog(url: root.appendingPathComponent("c.sqlite3")),
                                     events: SessionEventHub(),
                                     preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")),
                                     startableProviders: providers)
            model.intents = intents // weak: the test holds it
            await model.start()
            await model.stopAndWait()
            await model.settle()
            model.showHome()
            let (window, hosting) = hostHome(model, width: 940, height: 740)
            defer { window.close(); model.stop() }
            try await settle(window) { self.identifiers(in: hosting.view).contains("home-new-codex-session") }
            let codex = accessibilityElements(in: hosting.view).first { $0.accessibilityIdentifier?() == "home-new-codex-session" }
            let reason = accessibilityElements(in: hosting.view).first { $0.accessibilityIdentifier?() == "home-new-codex-reason" }
            return (codex.flatMap { $0.isAccessibilityEnabled?() }, reason != nil, // the words are `CatalogModel.codexLaterReason`, checked in SidebarStatusTests
                    HomeEmptyCatalog.showsMark(connectCards: model.homeConnect.showsCards))
        }
        let production = try await state([.claude])
        #expect(production.enabled == false, "listed, disabled")
        #expect(production.reason, "with the reason")
        #expect(production.mark, "the first run carries the app icon")
        let dev = try await state([.claude, .codex])
        #expect(dev.enabled == true && !dev.reason)
        // The cards take the mark's place.
        #expect(!HomeEmptyCatalog.showsMark(connectCards: true))
    }

    @Test func theFirstRunPanelIsHomeWithItsEmptyStateNotTheOldStartScreen() async throws {
        enableAccessibilityTree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-home-firstrun-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: try SessionCatalog(url: root.appendingPathComponent("c.sqlite3")),
                                 events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        await model.start()
        await model.stopAndWait()
        await model.settle()
        // No destination was ever chosen: this is what a first launch draws.
        #expect(model.destination == nil && model.detailRoute == .home)
        let hosting = NSHostingController(rootView: DetailContent(model: model, route: model.detailRoute))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 740), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 940, height: 740))
        window.isReleasedWhenClosed = false
        defer { window.close(); model.stop() }
        try await settle(window) { self.identifiers(in: hosting.view).contains("home-add-project") }
        let found = Set(identifiers(in: hosting.view))
        #expect(found.contains("home-add-project") && found.contains("home-new-session"), "\(found.sorted())")
        #expect(!found.contains("home-start") && !found.contains("home-no-claude"))
        #expect(!labels(in: hosting.view).contains("Add a project to begin"))
    }

    @Test func withoutClaudeAnEmptyCatalogSaysConnectYourAgentsAndOffersSetupAndCheckAgain() async throws {
        enableAccessibilityTree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-home-noclaude-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: try SessionCatalog(url: root.appendingPathComponent("c.sqlite3")),
                                 events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let rig = ConnectionsTests.Rig(claude: nil, claudeFound: false, codex: nil, codexFound: false)
        var copied: String?
        rig.model.copyToPasteboard = { copied = $0 }
        model.installHarnessHealth(rig.model)
        rig.model.checkAll()
        await rig.model.settle()
        await model.start()
        await model.stopAndWait()
        await model.settle()
        model.showHome()
        let (window, hosting) = hostHome(model, width: 940, height: 740)
        defer { window.close(); model.stop() }
        try await settle(window) { self.identifiers(in: hosting.view).contains("home-check-again") }
        let found = Set(identifiers(in: hosting.view))
        #expect(found.contains("home-connect") && found.contains("home-connect-claude") && found.contains("home-connect-codex"))
        #expect(found.contains("home-check-again") && found.contains("home-add-project"))
        let copy = try #require(accessibilityElements(in: hosting.view).first {
            $0.accessibilityIdentifier?() == "home-connect-action-claude"
        })
        #expect(copy.accessibilityPerformPress?() == true)
        #expect(copied == HarnessCatalogue.descriptor(for: .claude)?.install?.command)
        #expect(!found.contains("setup-open-terminal-claude"), "Home has one action; the full setup block is in Settings")
        #expect(!found.contains("home-new-session") && !found.contains("home-start") && !found.contains("home-app-icon"))
        let said = labels(in: hosting.view)
        #expect(said.contains { $0.hasPrefix("Claude,") && $0.contains("Not found on this Mac") },
                "\(said.filter { $0.contains("Claude") })")
    }

    @Test func withSessionsButNoClaudeACompactCardGivesWayToTheOldNotice() async throws {
        enableAccessibilityTree()
        let rig = try await ListRig.make(projects: 1, perProject: 2, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let health = ConnectionsTests.Rig(claude: nil, claudeFound: false, codex: ConnectionsTests.max, codexFound: true)
        rig.model.installHarnessHealth(health.model)
        health.model.checkAll()
        await health.model.settle()
        rig.model.showHome()
        let (window, hosting) = hostHome(rig.model, width: 940, height: 740)
        defer { window.close() }
        try await settle(window) { self.identifiers(in: hosting.view).contains("home-connect-notice") }
        let found = Set(identifiers(in: hosting.view))
        #expect(found.contains("home-connect-notice") && found.contains("home-check-again") && found.contains("home-connect-set-up"))
        #expect(!found.contains("home-start") && !found.contains("home-add-project") && !found.contains("home-connect"))
    }

    /// A picture of Home on the panel colour, written when `LOOM_HOME_RENDER_DIR` is set (a quick look while
    /// working on the views; the screenshots of record come from the running app).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOOM_HOME_RENDER_DIR"] != nil),
          arguments: [CGSize(width: 940, height: 760), CGSize(width: 520, height: 900)])
    func homeRendersToAPicture(size: CGSize) async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["LOOM_HOME_RENDER_DIR"])
        let intents = HomeIntents()
        let rig = try await populated(intents: intents)
        defer { rig.cleanup(); withExtendedLifetime(intents) {} }
        let (window, hosting) = hostHome(rig.model, width: size.width, height: size.height)
        defer { window.close() }
        try await settle(window) { false }
        let view = hosting.view
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("home-\(Int(size.width)).png"))
    }
}
