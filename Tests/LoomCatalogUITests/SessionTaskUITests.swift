import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

@MainActor
@Suite(.serialized) struct SessionTaskUITests {
    @Test func nativeRowsUseTheirRoleWithoutShowingTheBrief() throws {
        let record = SubagentRecord(id: "native-1234", agentType: "reviewer", description: "Secret task brief",
                                    startedAt: Date())
        let tree = SubagentTreeContent(records: [record], now: Date(), finishedExpanded: false, runningExpanded: false)
        let branch = try #require(tree.rows.first)
        #expect(branch.title == "reviewer")
        #expect(branch.detail == nil)
        #expect(!branch.accessibilityLabel.contains("Secret task brief"))
        let agents = InspectorAgentsContent(records: [record], now: Date())
        let row = try #require(agents.running.first)
        #expect(row.title == "reviewer")
        #expect(row.detail == nil)
        #expect(!row.accessibilityLabel.contains("Secret task brief"))
    }
    private func task(parent: UUID, child: UUID, id: UUID, name: String = "Reviewer", requested: String? = "gpt-example") -> SessionTaskProjection {
        let binding = SessionTaskBinding(sessionID: parent, nativeSessionID: "parent-native", managedRunID: UUID(), generation: UUID())
        return SessionTaskProjection(id: id, parentSessionID: parent, childSessionID: child, harness: .codex, childName: name,
            requestedChoices: HarnessLaunchChoices(harness: .codex, model: requested),
            effectiveModel: nil, effectiveEffort: nil, effectiveMode: nil, parentBinding: binding, childBinding: nil,
            lifecycle: .active, expiresAt: Date().addingTimeInterval(3_600), childInputLimit: 3, parentWakeLimit: 6,
            childInputsUsed: 1, parentWakesUsed: 0, parentWakesConsumed: 0, uncertainChildEffects: 0,
            uncertainWakeEffects: 0, authorityEpoch: 0, activeRoundID: UUID(), pendingRoundID: nil,
            currentAttentionID: nil, nextOrdinal: 2, revision: 1)
    }

    @Test func hostedMixedRowsUseTheirOwnIdentityAndNeverExposeNativeBriefs() async throws {
        enableAccessibilityTree()
        let parent = UUID(), child = UUID(), id = UUID()
        let native = SubagentRecord(id: id.uuidString, agentType: "Explorer", description: "Secret task brief", startedAt: Date())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-task-host-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(), preferences: UIPreferencesStore(url: root))
        let view = SubagentTreeView(sessionID: parent, records: [native], model: model,
                                    tasks: [task(parent: parent, child: child, id: id)], nativeHarness: .claude)
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 90), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 280, height: 90))
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let buttons = accessibilityElements(in: hosting.view).filter { $0.accessibilityRole?() == .button }
        let labels = buttons.compactMap { $0.accessibilityLabel?() }
        #expect(labels.contains { $0.contains("Explorer") && $0.contains("Claude") })
        #expect(labels.contains { $0.contains("Reviewer") && $0.contains("Codex") && $0.contains("requested model gpt-example") })
        #expect(!labels.contains { $0.contains("Secret task brief") })
        #expect(buttons.count == 2)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test func inspectorSeparatesNativeAndTaskRowsWithTheSameRawID() async throws {
        enableAccessibilityTree()
        let parent = UUID(), child = UUID(), id = UUID()
        let native = SubagentRecord(id: id.uuidString, agentType: "Explorer", description: "Secret task brief", startedAt: Date())
        var owned = task(parent: parent, child: child, id: id)
        owned.currentAttentionID = UUID()
        let content = InspectorAgentsContent(records: [native], now: Date(), waiting: [native.id], tasks: [owned],
                                             nativeHarness: .claude)
        let nativeRow = try #require(content.running.first)
        let taskRow = try #require(content.tasks.first)
        var nativePresses = 0, taskPresses = 0
        let hosting = NSHostingController(rootView: VStack {
            InspectorAgentRow(agent: nativeRow) { nativePresses += 1 }
            InspectorAgentRow(agent: taskRow) { taskPresses += 1 }
        }.frame(width: 328))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 328, height: 260), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 328, height: 260))
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let buttons = accessibilityElements(in: hosting.view).filter { $0.accessibilityRole?() == .button }
        let nativeButton = try #require(buttons.first { InkAX.label($0).hasPrefix("Explorer, Claude,") })
        let taskButton = try #require(buttons.first { InkAX.label($0).hasPrefix("Reviewer, Codex,") })
        let nativeID = InkAX.identifier(nativeButton), taskID = InkAX.identifier(taskButton)
        #expect(!nativeID.isEmpty && !taskID.isEmpty && nativeID != taskID,
                "both actual buttons need distinct accessibility identities, even for the same raw ID")
        #expect(nativeButton.accessibilityPerformPress?() == true)
        #expect(taskButton.accessibilityPerformPress?() == true)
        #expect(nativePresses == 1 && taskPresses == 1)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test func requestedReportedAndUnknownModelsKeepTheirProvenance() {
        let parent = UUID(), child = UUID(), id = UUID()
        var requested = task(parent: parent, child: child, id: id)
        #expect(SessionTaskPresentation.model(requested).text == "gpt-example · requested")
        #expect(SessionTaskPresentation.model(requested).spoken == "requested model gpt-example, actual model unknown")
        requested.effectiveModel = "gpt-reported"
        #expect(SessionTaskPresentation.model(requested).text == "gpt-reported")
        #expect(SessionTaskPresentation.model(requested).spoken == "reported model gpt-reported")
        let cliDefault = task(parent: parent, child: child, id: id, requested: nil)
        #expect(SessionTaskPresentation.model(cliDefault).spoken == "requested CLI default, actual model unknown")
        let unknown = task(parent: parent, child: child, id: id, requested: "")
        #expect(SessionTaskPresentation.model(unknown).text == "Model unknown")
        var later = requested
        later.activeRoundID = UUID()
        let firstRow = SubagentTreeContent(records: [], now: Date(), finishedExpanded: false, runningExpanded: false,
                                           tasks: [requested]).rows[0]
        let laterRow = SubagentTreeContent(records: [], now: Date(), finishedExpanded: false, runningExpanded: false,
                                           tasks: [later]).rows[0]
        #expect(firstRow.identity == laterRow.identity && requested.childSessionID == later.childSessionID)
        later.activeRoundID = nil
        #expect(SessionTaskPresentation.status(later) == "No active round")
        let overview = InspectorOverviewContent.agents(nil, now: Date(), tasks: [later])
        #expect(overview?.headline == nil, "no native running status can be inferred from task metadata")
        let legacy = SubagentRecord(id: "abcdefgh123456", agentType: "", description: "not a name", startedAt: Date())
        #expect(SessionTaskPresentation.nativeName(legacy) == "Subagent abcdefgh")
    }

    private final class TerminalIntents: ConversationIntents {
        let child: UUID
        let terminal = NSView()
        var starts = 0
        var stops = 0
        var resumes = 0
        init(child: UUID) { self.child = child }
        func start(provider: ManagedSession.Provider, projectID: UUID?) { starts += 1 }
        func resume(sessionID: UUID) { resumes += 1 }
        func stop(sessionID: UUID) { stops += 1 }
        func answer(sessionID: UUID, requestID: String, accept: Bool) {}
        func viewed(sessionID: UUID) {}
        func terminalView(sessionID: UUID) -> NSView? { sessionID == child ? terminal : nil }
    }

    private actor Reports {
        let records: [SessionTaskEvent]
        private var requests: [UUID] = []
        private var pageRequests: [UUID] = []
        private var continuation: AsyncStream<UInt64>.Continuation?
        init(_ records: [SessionTaskEvent]) { self.records = records }
        func latest(_ id: UUID, _ limit: Int) -> [SessionTaskEvent] {
            requests.append(id)
            return Array(records.filter { $0.taskID == id }.suffix(limit))
        }
        func asked() -> [UUID] { requests }
        func page(_ requested: UUID, parent: UUID, projection: SessionTaskProjection) -> SessionTaskUIBridge.Page {
            pageRequests.append(requested)
            return SessionTaskUIBridge.Page(items: requested == parent ? [projection] : [], next: nil)
        }
        func pages() -> [UUID] { pageRequests }
        func stream() -> AsyncStream<UInt64> {
            let pair = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
            continuation = pair.continuation
            return pair.stream
        }
        func signal(_ revision: UInt64) { continuation?.yield(revision) }
    }

    private struct Rig {
        let root: URL
        let model: CatalogModel
        let parent: UUID
        let child: UUID
        let task: SessionTaskProjection
        let native: SubagentRecord
        let intents: TerminalIntents
        let reports: Reports
    }

    private func rig(attention: Bool = false, liveParent: Bool = true) async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-task-ui-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let parent = UUID(), child = UUID(), id = UUID()
        try await catalog.insertSession(ManagedSession(id: parent, provider: .claude, workingDirectory: root.path),
                                        title: "Parent session", lifecycle: .idle)
        try await catalog.insertSession(ManagedSession(id: child, provider: .codex, workingDirectory: root.path),
                                        title: "Child session", lifecycle: .idle)
        let native = SubagentRecord(id: id.uuidString, agentType: "Explorer", description: "Secret task brief", startedAt: Date())
        let hub = SessionEventHub()
        if liveParent {
            await hub.publish(sessionID: parent, change: .runStarted(UUID()))
            await hub.publish(sessionID: parent, change: .subagents([native]))
        }
        var owned = task(parent: parent, child: child, id: id)
        let eventID = UUID()
        if attention { owned.currentAttentionID = eventID }
        else { owned.activeRoundID = nil }
        let event = SessionTaskEvent(id: eventID, taskID: id, roundID: owned.activeRoundID ?? UUID(), nativeTurnID: nil,
                                     execution: nil, kind: .needsParentInput, payload: "Clarify the fallback", occurredAt: Date())
        let result = SessionTaskEvent(id: UUID(), taskID: id, roundID: UUID(), nativeTurnID: nil, execution: nil,
                                      kind: .completed, payload: "Verified implementation", occurredAt: Date())
        let reports = Reports(attention ? [result, event] : [])
        let projection = owned
        let model = CatalogModel(catalog: catalog, events: hub,
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("preferences.json")))
        let intents = TerminalIntents(child: child)
        model.intents = intents
        model.setSessionTaskUIBridge(SessionTaskUIBridge(
            projections: { requested, _, _ in await reports.page(requested, parent: parent, projection: projection) },
            updates: { await reports.stream() }, latestEvents: { id, limit in await reports.latest(id, limit) }))
        await model.start()
        model.setWindowVisible(true)
        model.select(parent)
        let deadline = ContinuousClock.now + .seconds(5)
        while (model.selectedRow == nil || (liveParent && model.liveStates[parent]?.subagents.isEmpty != false))
                && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        _ = try #require(model.selectedRow)
        return Rig(root: root, model: model, parent: parent, child: child, task: projection, native: native,
                   intents: intents, reports: reports)
    }

    private func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test func actualSidebarChildrenHaveIndependentActionsAndKeepTheirSelectedSurface() async throws {
        enableAccessibilityTree()
        let rig = try await rig()
        defer { rig.model.setWindowVisible(false); rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        let row = try #require(rig.model.selectedRow)
        for width in [280.0, 300.0] {
            rig.model.select(rig.parent)
            let hosting = NSHostingController(rootView: ScrollView { SessionListEntry(row: row, model: rig.model) }
                .frame(width: width, height: 360))
            hosting.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 360), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: width, height: 360))
            defer { window.close() }
            func elements() -> [AnyObject] {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return accessibilityElements(in: hosting.view)
            }
            #expect(await wait { elements().contains { InkAX.label($0).hasPrefix("Reviewer, Codex,") } })
            let buttons = elements().filter { $0.accessibilityRole?() == .button }
            let native = try #require(buttons.first { InkAX.label($0).hasPrefix("Subagent Explorer, Claude,") })
            let owned = try #require(buttons.first { InkAX.label($0).hasPrefix("Reviewer, Codex,") })
            let card = try #require(buttons.first { InkAX.label($0).hasPrefix("Parent session,") })
            let nativeFrame = InkAX.frame(native), ownedFrame = InkAX.frame(owned), cardFrame = InkAX.frame(card)
            #expect(abs(nativeFrame.height - 24) < 1 && abs(ownedFrame.height - 24) < 1)
            #expect(!nativeFrame.intersects(ownedFrame) && !cardFrame.intersects(nativeFrame))
            #expect(nativeFrame.minX >= cardFrame.minX && ownedFrame.maxX <= cardFrame.maxX)
            #expect(!buttons.contains { InkAX.label($0).contains("Secret task brief") })
            #expect(owned.accessibilityPerformPress?() == true)
            #expect(await wait { rig.model.selectedSessionID == rig.child && rig.model.selectedRow?.id == rig.child })
            #expect(rig.model.faces.choice(for: rig.child) == .terminal)
            #expect(rig.model.detailRoute == .terminal(sessionID: rig.child))
            #expect(rig.intents.starts == 0 && rig.intents.stops == 0 && rig.intents.resumes == 0)
            try await Task.sleep(for: .milliseconds(250))
            func pixel(at point: NSPoint) throws -> NSColor {
                window.contentView?.layoutSubtreeIfNeeded()
                let image = try #require(hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds))
                hosting.view.cacheDisplay(in: hosting.view.bounds, to: image)
                let local = hosting.view.convert(window.convertFromScreen(NSRect(origin: point, size: .zero)), from: nil)
                let x = Int(local.minX * CGFloat(image.pixelsWide) / hosting.view.bounds.width)
                let y = hosting.view.isFlipped ? local.minY : hosting.view.bounds.height - local.minY
                return try #require(image.colorAt(x: x, y: Int(y * CGFloat(image.pixelsHigh) / hosting.view.bounds.height))?
                    .usingColorSpace(.sRGB))
            }
            func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
                max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                    abs(a.blueComponent - b.blueComponent))
            }
            let selectedFill = try pixel(at: NSPoint(x: cardFrame.minX + 8, y: cardFrame.midY))
            let childFill = try pixel(at: NSPoint(x: cardFrame.minX + 8, y: ownedFrame.midY))
            #expect(difference(selectedFill, childFill) < 0.006, "the selected surface extends behind the child")
            rig.model.showHome()
            try await Task.sleep(for: .milliseconds(250))
            let idleFill = try pixel(at: NSPoint(x: cardFrame.minX + 8, y: cardFrame.midY))
            #expect(difference(selectedFill, idleFill) > 0.015, "selecting the child selected its parent's whole surface")
            rig.model.select(rig.parent)
            let nativeAgain = try #require(elements().first { $0.accessibilityRole?() == .button
                && InkAX.label($0).hasPrefix("Subagent Explorer, Claude,") })
            #expect(nativeAgain.accessibilityPerformPress?() == true)
            #expect(rig.model.viewedSubagent?.agentID == rig.native.id)
            #expect(!window.isVisible && !window.isKeyWindow)
        }
    }

    @Test func inspectorShowsOnlyExplicitReportsAndOpensTheOwnedChild() async throws {
        enableAccessibilityTree()
        let rig = try await rig(attention: true)
        defer { rig.model.setWindowVisible(false); rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        let row = try #require(rig.model.selectedRow)
        let hosting = NSHostingController(rootView: InspectorAgents(model: rig.model, row: row).frame(width: 328, height: 700))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 328, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 328, height: 700))
        defer { window.close() }
        func elements() -> [AnyObject] {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return accessibilityElements(in: hosting.view)
        }
        #expect(await wait { elements().contains { InkAX.label($0).hasPrefix("Reviewer, Codex,") } })
        #expect(await rig.reports.asked().isEmpty)
        let rowButton = try #require(elements().first { $0.accessibilityRole?() == .button
            && InkAX.label($0).hasPrefix("Reviewer, Codex,") })
        #expect(InkAX.label(rowButton).contains("needs parent input"))
        #expect(rowButton.accessibilityPerformPress?() == true)
        let showsReport = await wait { elements().contains { [InkAX.value($0), InkAX.label($0)].compactMap { $0 }
            .contains { $0.contains("Clarify the fallback") } } }
        let words = elements().flatMap { [InkAX.value($0), InkAX.label($0)].compactMap { $0 } }
        #expect(showsReport, "the explicit report must be present in the detail: \(words)")
        #expect(words.contains { $0.contains("Result: Verified implementation") })
        #expect(await rig.reports.asked() == [rig.task.id])
        #expect(!elements().contains { (InkAX.value($0) ?? InkAX.label($0)).contains("Secret task brief") })
        #expect(!elements().contains { (InkAX.value($0) ?? InkAX.label($0)) == "Result" })
        let back = try #require(elements().first { $0.accessibilityRole?() == .button && InkAX.label($0) == "Back to Agents" })
        #expect(back.accessibilityPerformPress?() == true)
        #expect(await wait { elements().contains { InkAX.label($0).hasPrefix("Reviewer, Codex,") } })
        #expect(!elements().contains { (InkAX.value($0) ?? InkAX.label($0)).contains("Clarify the fallback") })
        let reopened = try #require(elements().first { $0.accessibilityRole?() == .button
            && InkAX.label($0).hasPrefix("Reviewer, Codex,") })
        #expect(reopened.accessibilityPerformPress?() == true)
        #expect(await wait { elements().contains { InkAX.label($0) == "Open Session" } })
        let open = try #require(elements().first { $0.accessibilityRole?() == .button && InkAX.label($0) == "Open Session" })
        #expect(open.accessibilityPerformPress?() == true)
        #expect(await wait { rig.model.selectedSessionID == rig.child && rig.model.selectedRow?.id == rig.child })
        #expect(rig.model.detailRoute == .terminal(sessionID: rig.child))
        #expect(rig.intents.starts == 0 && rig.intents.stops == 0 && rig.intents.resumes == 0)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test func hiddenSidebarReadsNoTasksAndCancelsItsInterest() async throws {
        let rig = try await rig()
        rig.model.setWindowVisible(false)
        defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        let row = try #require(rig.model.selectedRow)
        let hosting = NSHostingController(rootView: ScrollView { SessionListEntry(row: row, model: rig.model) }
            .frame(width: 280, height: 360))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 360), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 280, height: 360))
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await rig.reports.pages().isEmpty, "a hidden window must not read task metadata")
        rig.model.setWindowVisible(true)
        let deadline = ContinuousClock.now + .seconds(5)
        while (await rig.reports.pages()).isEmpty && ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await rig.reports.pages() == [rig.parent])
        rig.model.setWindowVisible(false)
        #expect(await wait { rig.model.sessionTasks.activeParentCount == 0 })
        let count = await rig.reports.pages().count
        await rig.reports.signal(99)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await rig.reports.pages().count == count, "an update while hidden starts no new read")
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test func anIdleTaskWithoutAReportDoesNotAppearFinished() async throws {
        enableAccessibilityTree()
        let rig = try await rig()
        defer { rig.model.setWindowVisible(false); rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        let row = try #require(rig.model.selectedRow)
        let hosting = NSHostingController(rootView: InspectorAgents(model: rig.model, row: row).frame(width: 328, height: 700))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 328, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 328, height: 700))
        defer { window.close() }
        func elements() -> [AnyObject] {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return accessibilityElements(in: hosting.view)
        }
        #expect(await wait { elements().contains { InkAX.label($0).hasPrefix("Reviewer, Codex,") } })
        let button = try #require(elements().first { $0.accessibilityRole?() == .button
            && InkAX.label($0).hasPrefix("Reviewer, Codex,") })
        #expect(InkAX.label(button).contains("no active round"))
        #expect(button.accessibilityPerformPress?() == true)
        #expect(await wait { elements().contains { [InkAX.value($0), InkAX.label($0)].compactMap { $0 }
            .contains { $0.contains("No reported result or request.") } } })
        let words = elements().flatMap { [InkAX.value($0), InkAX.label($0)].compactMap { $0 } }
        #expect(!words.contains { $0 == "Finished" || $0.hasPrefix("Result:") })
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test func stoppedParentStillShowsOwnedTaskAndItsReportedRequest() async throws {
        enableAccessibilityTree()
        let rig = try await rig(attention: true, liveParent: false)
        defer { rig.model.setWindowVisible(false); rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        let row = try #require(rig.model.selectedRow)
        #expect(row.live?.runID == nil)
        let hosting = NSHostingController(rootView: InspectorAgents(model: rig.model, row: row).frame(width: 328, height: 700))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 328, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 328, height: 700))
        defer { window.close() }
        func elements() -> [AnyObject] {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return accessibilityElements(in: hosting.view)
        }
        #expect(await wait { elements().contains { InkAX.label($0).hasPrefix("Reviewer, Codex,") } })
        #expect(await rig.reports.pages() == [rig.parent])
        let button = try #require(elements().first { $0.accessibilityRole?() == .button
            && InkAX.label($0).hasPrefix("Reviewer, Codex,") })
        #expect(button.accessibilityPerformPress?() == true)
        #expect(await wait { elements().contains { [InkAX.value($0), InkAX.label($0)].compactMap { $0 }
            .contains { $0.contains("Needs parent input: Clarify the fallback") } } })
        #expect(await rig.reports.asked() == [rig.task.id])
        #expect(!window.isVisible && !window.isKeyWindow)
    }

}
