import Foundation
import AppKit
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI

@MainActor
private final class RecordingIntents: ConversationIntents {
    var starts: [(ManagedSession.Provider, UUID?)] = []
    func start(provider: ManagedSession.Provider, projectID: UUID?) { starts.append((provider, projectID)) }
    func resume(sessionID: UUID) {}
    func stop(sessionID: UUID) {}
    func answer(sessionID: UUID, requestID: String, accept: Bool) {}
    func viewed(sessionID: UUID) {}
    func terminalView(sessionID: UUID) -> NSView? { nil }
}

@MainActor
private func chaseViews(in view: NSView) -> [ChaseDots.LayerView] {
    (view as? ChaseDots.LayerView).map { [$0] } ?? view.subviews.flatMap(chaseViews(in:))
}

@MainActor
struct SidebarStatusTests {
    @Test func projectDotPriorityIsFailureThenAttentionThenUnviewed() {
        #expect(ProjectAttention.strongest(of: [.idle, .ready, .working, .ended]) == nil)
        #expect(ProjectAttention.strongest(of: [.unviewedCompletion, .working]) == .unviewed)
        #expect(ProjectAttention.strongest(of: [.unviewedCompletion, .waitingForInput]) == .attention)
        #expect(ProjectAttention.strongest(of: [.waitingForApproval, .unviewedCompletion, .failed("x")]) == .failure)
        #expect(ProjectAttention.strongest(of: [.stopUnverified("x"), .waitingForApproval]) == .failure)
        #expect(ProjectAttention.strongest(of: [.identityUnclear]) == .attention)
    }

    @Test func projectNameIsHiddenOnlyInTheProjectView() {
        #expect(SessionCardView.projectLabel(mode: .activity, name: "rocket") == "rocket")
        #expect(SessionCardView.projectLabel(mode: .projects, name: "rocket") == nil)
        // The user's own project/folder name must not come back in the project view.
        #expect(SessionCardView.projectLabel(mode: .projects, name: "light-work-doc-viewer") == nil)
        let untitled = CatalogSession(
            session: ManagedSession(provider: .codex, workingDirectory: "/tmp"), title: nil,
            createdAt: Date(timeIntervalSince1970: 0), lastUsedAt: Date(timeIntervalSince1970: 0),
            lifecycle: .idle, pinned: false, projectID: nil)
        #expect(untitled.displayTitle(projectName: "rocket") == "Codex · rocket")
        #expect(untitled.displayTitle(projectName: "rocket", repeatsProject: false) == "Codex session")
    }

    @Test func projectContextMenuStartsTheRightProviderInThatProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let intents = RecordingIntents()
        model.intents = intents
        let project = UUID()
        #expect(NewConversationAction.startable(on: model).map(\.title) == ["New Claude Session", "New Codex Session"])
        for action in NewConversationAction.startable(on: model) {
            #expect(action.isEnabled(on: model, projectID: project))
            action.perform(on: model, projectID: project)
        }
        // Claude opens the project's draft (V07); Codex keeps its direct start.
        #expect(intents.starts.map(\.0) == [.codex] && intents.starts.allSatisfy { $0.1 == project })
        #expect(model.destination == .draft(projectID: project))
        // Unavailable (Quit started) behaves like every other new-conversation entry.
        model.quitting = true
        model.showHome()
        for action in NewConversationAction.startable(on: model) {
            #expect(!action.isEnabled(on: model, projectID: project))
            action.perform(on: model, projectID: project)
        }
        #expect(intents.starts.count == 1 && model.destination == .home)
    }

    @Test func productionModelOffersAndStartsOnlyClaude() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")),
                                 startableProviders: [.claude])
        let intents = RecordingIntents()
        model.intents = intents
        #expect(NewConversationAction.startable(on: model).map(\.title) == ["New Claude Session"])
        #expect(model.startableProviders == [.claude])
        #expect(!model.canStart(.codex, projectID: nil))
        model.startConversation(.codex, projectID: nil)
        #expect(intents.starts.isEmpty)
        #expect(model.canStart(.claude, projectID: nil))
        model.startConversation(.claude, projectID: nil)
        #expect(intents.starts.map(\.0) == [.claude])
    }

    /// D-69: 1.5.0 behaves as if Loom supports Codex. A build that cannot start it still lists the entry, disabled and
    /// with the reason; a build that can lists it as it always did, and nothing starts Codex in the first.
    @Test func aBuildWithoutCodexListsItDisabledWithTheReasonAndStartsNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ providers: Set<ManagedSession.Provider>) -> CatalogModel {
            CatalogModel(catalog: nil, events: SessionEventHub(),
                         preferences: UIPreferencesStore(url: root.appendingPathComponent("p-\(UUID()).json")),
                         startableProviders: providers)
        }
        let production = make([.claude])
        let intents = RecordingIntents()
        production.intents = intents
        let listed = NewConversationAction.listed(on: production)
        #expect(listed.map(\.title) == ["New Claude Session", "New Codex Session"])
        let codex = try #require(listed.last)
        #expect(codex.unavailableReason(on: production) == "Codex comes in a later version")
        #expect(!codex.isEnabled(on: production, projectID: nil))
        codex.perform(on: production, projectID: nil)
        #expect(intents.starts.isEmpty, "nothing starts Codex in a build that cannot")
        #expect(listed.first?.unavailableReason(on: production) == nil)

        // A build that starts Codex lists the same two entries, both enabled and without a reason.
        let dev = make([.claude, .codex])
        let devIntents = RecordingIntents()
        dev.intents = devIntents
        let devListed = NewConversationAction.listed(on: dev)
        #expect(devListed.map(\.title) == ["New Claude Session", "New Codex Session"])
        #expect(devListed.allSatisfy { $0.unavailableReason(on: dev) == nil && $0.isEnabled(on: dev, projectID: nil) })

        // The main menu is built before a model exists and asks the same question of the build's provider set.
        #expect(CatalogModel.newSessionUnavailableReason(.codex, startable: [.claude]) == CatalogModel.codexLaterReason)
        #expect(CatalogModel.newSessionUnavailableReason(.codex, startable: [.claude, .codex]) == nil)
        #expect(CatalogModel.newSessionUnavailableReason(.claude, startable: [.claude]) == nil)
        // Claude stays hidden where it cannot start (unchanged).
        #expect(NewConversationAction.listed(on: make([])).map(\.title) == ["New Codex Session"])
    }

    @Test(.timeLimit(.minutes(1)))
    func collapsedProjectShowsADotForAnUnviewedLiveSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ui-\(UUID())")
        let folder = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let project = try await catalog.addProject(path: folder.path).project
        let session = ManagedSession(provider: .claude, workingDirectory: folder.path)
        try await catalog.insertSession(session, title: "In project", lifecycle: .idle, projectID: project.id)
        try await catalog.setProjectCollapsed(id: project.id, collapsed: true)
        let hub = SessionEventHub()
        let model = CatalogModel(catalog: catalog, events: hub,
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        await model.start()
        await model.stopAndWait() // the test feeds frames itself
        model.setViewMode(.projects)
        await model.settle()
        // Collapsed: the project's rows are not loaded.
        #expect(model.list(for: .project(project.id)).rows.isEmpty)
        #expect(model.attention(forProject: project.id) == nil)

        let stream = await hub.subscribe()
        var iterator = stream.makeAsyncIterator()
        model.apply(try #require(await iterator.next()))
        await hub.publish(sessionID: session.id, change: .status(ProviderWorkState(activity: .turnComplete)))
        model.apply(try #require(await iterator.next()))
        for _ in 0..<50 where model.attention(forProject: project.id) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.attention(forProject: project.id) == .unviewed)
        #expect(model.list(for: .project(project.id)).rows.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func projectDotSurvivesRowPruningAfterSearchAndCollapse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ui-\(UUID())")
        let folder = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let project = try await catalog.addProject(path: folder.path).project
        let session = ManagedSession(provider: .claude, workingDirectory: folder.path)
        try await catalog.insertSession(session, title: "In project", lifecycle: .idle, projectID: project.id)
        let hub = SessionEventHub()
        let model = CatalogModel(catalog: catalog, events: hub,
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        // Projects view from the start: the activity list never holds the row.
        model.setViewMode(.projects)
        await model.start()
        await model.stopAndWait()
        #expect(model.list(for: .project(project.id)).rows.map(\.id) == [session.id])

        let stream = await hub.subscribe()
        var iterator = stream.makeAsyncIterator()
        model.apply(try #require(await iterator.next()))
        await hub.publish(sessionID: session.id, change: .status(ProviderWorkState(activity: .turnComplete)))
        model.apply(try #require(await iterator.next()))
        #expect(model.attention(forProject: project.id) == .unviewed)

        await model.toggleCollapsed(project.id)
        model.setSearchText("no-such-conversation")
        await model.settle()
        // The search emptied the list: the row model was pruned.
        #expect(model.list(for: .project(project.id)).rows.isEmpty)
        model.setSearchText("")
        await model.settle()
        #expect(model.attention(forProject: project.id) == .unviewed)
    }

    @Test(.timeLimit(.minutes(1)))
    func startingFromAProjectExpandsACollapsedProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ui-\(UUID())")
        let folder = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let project = try await catalog.addProject(path: folder.path).project
        try await catalog.setProjectCollapsed(id: project.id, collapsed: true)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let intents = RecordingIntents()
        model.intents = intents
        await model.start()
        await model.stopAndWait()
        #expect(model.projects.first?.collapsed == true)
        // Claude opens a draft, which starts nothing; the project opens when the session starts from it.
        NewConversationAction.startable(on: model)[0].perform(on: model, projectID: project.id)
        #expect(intents.starts.isEmpty && model.destination == .draft(projectID: project.id))
        // A direct start (Codex) shows its new card: the collapsed project opens.
        NewConversationAction.startable(on: model)[1].perform(on: model, projectID: project.id)
        await model.settle()
        for _ in 0..<40 where model.projects.first?.collapsed == true { try await Task.sleep(for: .milliseconds(50)) }
        #expect(intents.starts.count == 1)
        #expect(model.projects.first?.collapsed == false)
        // An already expanded project stays expanded.
        NewConversationAction.startable(on: model)[1].perform(on: model, projectID: project.id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.projects.first?.collapsed == false)
    }

    @Test func workingIndicatorIsStaticWhenInactiveOrNotWorking() {
        // Reduce Motion does not stop the small working indicator (user decision); only inactivity does.
        #expect(IndicatorView.isAnimating(.working, indicatorsAnimate: true))
        // Hidden or inactive window (model.windowIsActive == false) or collapsed sidebar.
        #expect(!IndicatorView.isAnimating(.working, indicatorsAnimate: false))
        #expect(!IndicatorView.isAnimating(.waitingForInput, indicatorsAnimate: true))
        #expect(IndicatorView.framesPerSecond <= 12)
    }

    @Test func sidebarIndicatorsAnimateOnlyForAnActiveWindowAndAnExpandedSidebar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        func sidebarAnimates() -> Bool { SidebarView.indicatorsAnimate(model) }
        #expect(!sidebarAnimates()) // window not active yet
        model.setWindowActive(true)
        #expect(sidebarAnimates())
        model.setSidebarCollapsed(true)
        #expect(!sidebarAnimates()) // collapsed sidebar: nothing visible to animate
        model.setSidebarCollapsed(false)
        model.setWindowActive(false) // hidden, occluded, minimized or app inactive
        #expect(!sidebarAnimates())
    }

    /// The wiring, not the predicate: a real hosting view in a real window.
    @Test func hostedWorkingIndicatorRunsOnlyWhenTheEnvironmentAllowsIt() async throws {
        func running(animate: Bool) async throws -> Bool {
            let view = IndicatorView(indicator: .working)
                .environment(\.indicatorsAnimate, animate)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            // The chase view exists, in the window, once SwiftUI has laid the hosting view out; how long that takes
            // depends on the load, so wait for it. Its animation is installed in the same pass that puts it there.
            var chase: ChaseDots.LayerView?
            for _ in 0..<500 where chase?.window == nil {
                try await Task.sleep(for: .milliseconds(20))
                chase = chaseViews(in: hosting).first
            }
            let dots = try #require(chase)
            #expect(dots.window != nil, "the chase view never reached the window")
            if animate {
                for _ in 0..<500 where !dots.isRunning { try await Task.sleep(for: .milliseconds(20)) }
                return dots.isRunning
            }
            // Not running must hold, not only at the first look.
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(20))
                if dots.isRunning { return true }
            }
            return false
        }
        #expect(try await running(animate: true))
        #expect(!(try await running(animate: false)))
    }

    @Test(.timeLimit(.minutes(1)))
    func realSidebarRunsAWorkingRowOnlyForAnActiveWindowAndExpandedSidebar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let session = ManagedSession(provider: .claude, workingDirectory: root.path)
        try await catalog.insertSession(session, title: "Busy", lifecycle: .idle)
        let hub = SessionEventHub()
        let model = CatalogModel(catalog: catalog, events: hub,
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        await model.start()
        await model.stopAndWait()
        let stream = await hub.subscribe()
        var iterator = stream.makeAsyncIterator()
        model.apply(try #require(await iterator.next()))
        await hub.publish(sessionID: session.id, change: .runStarted(UUID()))
        await hub.publish(sessionID: session.id, change: .status(ProviderWorkState(activity: .working)))
        model.apply(try #require(await iterator.next()))
        let row = try #require(model.list(for: .activity).rows.first)
        #expect(row.indicator == .working)

        let hosting = NSHostingController(rootView: SidebarView(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 300, height: 400))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func running() async throws -> Bool {
            try await Task.sleep(for: .milliseconds(400))
            return chaseViews(in: hosting.view).contains { $0.isRunning }
        }
        #expect(!(try await running()), "inactive window must be static")
        model.setWindowActive(true)
        #expect(try await running(), "active window with an expanded sidebar must animate")
        model.setSidebarCollapsed(true)
        #expect(!(try await running()), "collapsed sidebar must be static")
        model.setSidebarCollapsed(false)
        #expect(try await running())
        model.setWindowActive(false)
        #expect(!(try await running()), "deactivated window must be static again")
    }

    @Test func focusRingNeedsKeyboardNavigationAndFocus() {
        #expect(!ChromeButtonStyle.showsFocusRing(focused: true, keyboardNavigation: false))
        #expect(ChromeButtonStyle.showsFocusRing(focused: true, keyboardNavigation: true))
        #expect(!ChromeButtonStyle.showsFocusRing(focused: false, keyboardNavigation: true))
    }

    @Test func chaseHeadAdvancesOneDotPerStepWithAFadingTail() {
        #expect(ChaseDots.opacity(dot: 3, step: 3) == 1)
        #expect(ChaseDots.opacity(dot: 2, step: 3) == ChaseDots.trail[1])
        #expect(ChaseDots.opacity(dot: 7, step: 0) == ChaseDots.trail[1])
        #expect(ChaseDots.opacity(dot: 4, step: 3) == ChaseDots.rest)
        #expect(ChaseDots.opacity(dot: 1, step: 9) == 1)
    }
}
