import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport

@MainActor
@Observable private final class B5bIndicatorState { var active = false }

private final class B5bFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set() { lock.lock(); stored = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
}

@MainActor
private struct B5bIndicators: View {
    let state: B5bIndicatorState
    let model: CatalogModel
    let request: OpenSessionRequest
    var body: some View {
        VStack {
            ChangesNote(text: "Reading the diff", busy: true)
            OpenRequestBox(model: model, request: request)
        }
        .environment(\.indicatorsAnimate, state.active)
    }
}

@MainActor
private struct B5bBranchClock: View {
    let state: B5bIndicatorState
    var body: some View { ChangesBranchReading().environment(\.indicatorsAnimate, state.active) }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct B5bSurfaceTests {
    private func host<V: View>(_ view: V, size: NSSize) async throws -> (NSWindow, NSHostingView<V>) {
        enableAccessibilityTree()
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        try await settle(window)
        #expect(!window.isVisible && !window.isKeyWindow)
        return (window, host)
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(140))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func temporaryModel() -> CatalogModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b5b-\(UUID()).json")
        return CatalogModel(catalog: nil, events: SessionEventHub(), preferences: UIPreferencesStore(url: url))
    }

    @Test func headerGroupAndSessionTabUseTwentyEightPointControls() {
        let group = NSHostingView(rootView: HeaderControlGroup(canStop: true, stop: {}, menuItems: { Text("Menu") }))
        group.layoutSubtreeIfNeeded()
        let tab = NSHostingView(rootView: ConversationTabItem(model: temporaryModel(), id: UUID()).frame(width: 180))
        tab.layoutSubtreeIfNeeded()
        #expect(abs(group.fittingSize.height - 28) < 0.5, "header group is \(group.fittingSize.height) high")
        #expect(abs(tab.fittingSize.height - 28) < 0.5, "session tab is \(tab.fittingSize.height) high")
    }

    @Test func headerModelReadoutCarriesItsHarnessMarkAndStaysReadOnly() async throws {
        let rig = try await InspectorRig.make(sessions: 1)
        defer { rig.cleanup() }
        let catalog = try #require(rig.model.catalog)
        try await catalog.recordLaunchChoices(ClaudeLaunchChoices(model: "sonnet"), sessionID: rig.ids[0])
        await rig.model.launchModels.load(rig.ids[0], from: catalog)
        rig.model.select(rig.ids[0])
        try #require(await inspectorWaitUntil { rig.model.selectedRow?.id == rig.ids[0] })
        let row = try #require(rig.model.selectedRow)
        let (window, host) = try await host(HeaderModelSegment(model: rig.model, row: row).frame(height: 28),
                                            size: NSSize(width: 180, height: 28))
        defer { window.close() }
        let segment = try #require(accessibilityElements(in: host).first { InkAX.label($0).contains("Model Sonnet") })
        let label = NSHostingView(rootView: Text("Sonnet").font(LoomTheme.Typography.small))
        label.layoutSubtreeIfNeeded()
        #expect(InkAX.frame(segment).width >= label.fittingSize.width + LoomTheme.Layout.harnessMarkRow + 4,
                "the readout leaves room for the harness mark")
        #expect(segment.accessibilityRole?() != .button, "the current-session model remains a readout")
    }

    @Test func overviewModelNameUsesTheReadingFace() throws {
        func bitmap<V: View>(_ view: V) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: view.frame(width: 100, height: 24, alignment: .leading)
                .environment(\.colorScheme, .dark))
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        let actual = try bitmap(OverviewRunValue(claudeCode: nil, model: "Sonnet", effort: nil))
        let sans = try bitmap(Text("Sonnet").font(LoomTheme.Overview.value.font)
            .foregroundStyle(LoomTheme.Text.primary).textSelection(.enabled))
        let mono = try bitmap(Text("Sonnet").font(LoomTheme.Overview.machine.font)
            .foregroundStyle(LoomTheme.Text.secondaryStyle).textSelection(.enabled))
        func error(_ actual: NSBitmapImageRep, _ reference: NSBitmapImageRep) -> Double {
            var result = 0.0
            for y in 0..<actual.pixelsHigh {
                for x in 0..<actual.pixelsWide {
                    let a = Double(actual.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                    let b = Double(reference.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                    result += (a - b) * (a - b)
                }
            }
            return result
        }
        let sansError = error(actual, sans), monoError = error(actual, mono)
        print("B5B_OVERVIEW_MODEL sans_error=\(sansError) mono_error=\(monoError)")
        #expect(sansError < monoError, "model names are reading text")
        let mixed = try bitmap(OverviewRunValue(claudeCode: nil, model: "Sonnet", effort: "high"))
        let name = Text("Sonnet").font(LoomTheme.Overview.value.font).foregroundStyle(LoomTheme.Text.primary)
        let separator = Text(" · ").font(LoomTheme.Overview.value.font).foregroundStyle(LoomTheme.Text.primary)
        let effort = Text("high").font(LoomTheme.Overview.machine.font).foregroundStyle(LoomTheme.Text.secondaryStyle)
        let expected = try bitmap(Text("\(name)\(separator)\(effort)").textSelection(.enabled))
        #expect(error(mixed, expected) < 0.01, "the effort keeps its mono voice after the reading-face model name")
    }

    @Test func idleProjectTabIsFlatAndStillNamesItsProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b5b-tab-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let project = try await catalog.addProject(path: folder.path).project
        let session = ManagedSession(provider: .claude, workingDirectory: folder.path)
        try await catalog.insertSession(session, title: "Example", lifecycle: .idle, projectID: project.id)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        await model.start()
        defer { model.stop() }
        for _ in 0..<100 where model.tabRow(session.id) == nil { try await Task.sleep(for: .milliseconds(10)) }
        let row = try #require(model.tabRow(session.id))
        #expect(model.projectMark(of: row.record)?.name == "project")
        let renderer = ImageRenderer(content: ConversationTabItem(model: model, id: session.id)
            .frame(width: 230).environment(\.colorScheme, .dark))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let blank = try #require(bitmap.colorAt(x: 180, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        print("B5B_IDLE_TAB alpha=\(blank.alphaComponent)")
        #expect(blank.alphaComponent < 0.01, "idle tab has no colored wash")

        func textBitmap(size: CGFloat) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: Text("Example").font(.system(size: size))
                .foregroundStyle(LoomTheme.Text.secondary).fixedSize().environment(\.colorScheme, .dark))
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        func alpha(_ image: NSBitmapImageRep) -> [Double] {
            (0..<image.pixelsHigh).flatMap { y in
                (0..<image.pixelsWide).map { x in Double(image.colorAt(x: x, y: y)?.alphaComponent ?? 0) }
            }
        }
        let pixels = alpha(bitmap)
        func bestError(_ sample: NSBitmapImageRep) -> Double {
            let target = alpha(sample)
            var best = Double.infinity
            for y in 0...(bitmap.pixelsHigh - sample.pixelsHigh) {
                for x in 0...(bitmap.pixelsWide - sample.pixelsWide) {
                    var sum = 0.0
                    for dy in 0..<sample.pixelsHigh {
                        for dx in 0..<sample.pixelsWide {
                            let delta = pixels[(y + dy) * bitmap.pixelsWide + x + dx] - target[dy * sample.pixelsWide + dx]
                            sum += delta * delta
                        }
                    }
                    best = min(best, sum / Double(sample.pixelsWide * sample.pixelsHigh))
                }
            }
            return best
        }
        let small = bestError(try textBitmap(size: 12)), old = bestError(try textBitmap(size: 12.5))
        print("B5B_TAB_TYPE 12_error=\(small) 12_5_error=\(old)")
        #expect(small < old, "session-tab titles use the 12 pt reading face")
    }

    @Test func overviewSectionsAreRaisedCards() async throws {
        let rig = try await InspectorRig.make(sessions: 1)
        defer { rig.cleanup() }
        rig.model.select(rig.ids[0])
        try #require(await inspectorWaitUntil { rig.model.selectedRow?.id == rig.ids[0] })
        let row = try #require(rig.model.selectedRow)
        for dark in [true, false] {
            let view = InspectorOverview(model: rig.model, row: row).frame(width: 328, height: 600)
                .background(LoomTheme.Surface.canvas).environment(\.colorScheme, dark ? .dark : .light)
            let (window, host) = try await host(view, size: NSSize(width: 328, height: 600))
            defer { window.close() }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await settle(window)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var cardPixels = 0
            let cardColors = PaneTone.allCases.map { LoomTheme.Surface.greys(.dark, tone: $0).raised1 }
            let x = (dark ? 300 : 14) * bitmap.pixelsWide / 328
            for y in 0..<bitmap.pixelsHigh {
                // The cached bitmap's calibrated components are the numeric RGB values written by the view;
                // converting those components a second time changes them before the token comparison.
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                if dark {
                    if cardColors.contains(where: {
                        abs(Double(color.redComponent) - $0.red) < 0.015
                            && abs(Double(color.greenComponent) - $0.green) < 0.015
                            && abs(Double(color.blueComponent) - $0.blue) < 0.015
                    }) {
                        cardPixels += 1
                    }
                } else if color.redComponent < 0.98 && color.greenComponent < 0.98 {
                    cardPixels += 1
                }
            }
            print("B5B_OVERVIEW \(dark ? "ink" : "paper") card_pixels=\(cardPixels) of \(bitmap.pixelsHigh)")
            #expect(cardPixels > 100, "the Overview has raised cards and a visible Paper edge")
            if let directory = ProcessInfo.processInfo.environment["LOOM_B5B_RENDER_DIR"],
               let variant = ProcessInfo.processInfo.environment["LOOM_B5B_VARIANT"] {
                let dir = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: dir.appendingPathComponent("overview-\(variant)-\(dark ? "ink" : "paper").png"))
            }
        }
    }

    @Test func changesAndOpeningUseTheGatedSharedSpinner() async throws {
        let state = B5bIndicatorState()
        let request = OpenSessionRequest(requesterID: UUID(), projectID: UUID(), projectName: "Project", title: "Next",
                                         message: "Do the next step", phase: .starting)
        let view = B5bIndicators(state: state, model: temporaryModel(), request: request)
        let (window, host) = try await host(view, size: NSSize(width: 520, height: 420))
        defer { window.close() }
        func spinners(_ view: NSView) -> [BrailleSpinner.LayerView] {
            (view as? BrailleSpinner.LayerView).map { [$0] } ?? view.subviews.flatMap(spinners)
        }
        let found = spinners(host)
        #expect(found.count == 2, "both in-flight surfaces use the shared spinner")
        guard found.count == 2 else { return }
        #expect(found.allSatisfy { !$0.isRunning })
        state.active = true
        try await settle(window)
        #expect(found.allSatisfy { $0.isRunning })
        state.active = false
        try await settle(window)
        #expect(found.allSatisfy { !$0.isRunning })
    }

    @Test func branchReadingClockDoesNotAdvanceInAnInactiveWindow() async throws {
        let state = B5bIndicatorState()
        let (window, host) = try await host(B5bBranchClock(state: state).frame(width: 400, height: 150),
                                            size: NSSize(width: 400, height: 150))
        defer { window.close() }
        func text() -> String {
            accessibilityElements(in: host).map { InkAX.label($0) + " " + (InkAX.value($0) ?? "") }
                .first { $0.contains(ChangesBodyWords.branchCommand) } ?? ""
        }
        func spinners(_ view: NSView) -> [BrailleSpinner.LayerView] {
            (view as? BrailleSpinner.LayerView).map { [$0] } ?? view.subviews.flatMap(spinners)
        }
        #expect(spinners(host).count == 1 && spinners(host).allSatisfy { !$0.isRunning },
                "the branch read uses the shared still indicator while inactive")
        let before = text()
        try #require(!before.isEmpty)
        try await Task.sleep(for: .milliseconds(1_400))
        try await settle(window)
        let after = text()
        print("B5B_BRANCH_CLOCK inactive before=\(before) after=\(after)")
        #expect(after == before, "the inactive view has no periodic clock")
        state.active = true
        try await Task.sleep(for: .milliseconds(1_400))
        try await settle(window)
        #expect(text() != after, "the visible active clock still advances")
        #expect(spinners(host).count == 1 && spinners(host).allSatisfy { $0.isRunning })
    }

    @Test func transcriptFoldsToolsAndKeepsTheMarkdownTableAndResult() async throws {
        let panel = SubagentTranscriptModel(agentID: "a1", transcriptPath: nil, isRunning: false, windowVisible: false,
                                             locate: { _ in nil })
        panel.apply(SubagentTranscriptBatch(entries: [
            .brief("Check the session surfaces"), .text("I checked **the rows**."),
            .toolCall(name: "Read", argument: "Example.swift"), .toolResult(lines: ["Found the row"], lineCount: 1, isError: false),
            .toolCall(name: "Bash", argument: "swift test"), .toolResult(lines: ["All passed"], lineCount: 1, isError: false),
            .text("Final report.\n\n| Surface | Rule |\n| --- | --- |\n| Tabs | Flat |")
        ], replacesEarlier: true, omitsEarlier: false))
        let view = SubagentTranscriptView(panel: panel, isFinished: true).frame(width: 556, height: 600)
        let (window, host) = try await host(view, size: NSSize(width: 556, height: 600))
        defer { window.close(); panel.close() }
        func text(_ element: AnyObject) -> String { InkAX.label(element) + " " + (InkAX.value(element) ?? "") }
        var elements = accessibilityElements(in: host)
        let fold = try #require(elements.first { $0.accessibilityRole?() == .button && text($0).contains("Ran 2 tools") },
                                "consecutive calls and their results form one collapsed button")
        #expect(!elements.contains { text($0).contains("Example.swift") }, "tool details start collapsed")
        #expect(fold.accessibilityPerformPress?() == true)
        try await settle(window)
        elements = accessibilityElements(in: host)
        #expect(elements.contains { text($0).contains("Example.swift") } && elements.contains { text($0).contains("All passed") })
        let surface = try #require(elements.first { text($0).trimmingCharacters(in: .whitespaces) == "Surface" })
        let rule = try #require(elements.first { text($0).trimmingCharacters(in: .whitespaces) == "Rule" })
        #expect(abs(InkAX.frame(surface).midY - InkAX.frame(rule).midY) < 2 && InkAX.frame(surface).minX < InkAX.frame(rule).minX,
                "the Markdown table has two columns in the same header row")
        #expect(elements.contains { text($0).contains("RESULT") })
    }

    @Test func aLiveToolGroupKeepsItsExpansionAsTheNextBatchArrives() async throws {
        let panel = SubagentTranscriptModel(agentID: "a1", transcriptPath: nil, isRunning: true, windowVisible: false,
                                             locate: { _ in nil })
        panel.apply(SubagentTranscriptBatch(entries: [
            .toolCall(name: "Read", argument: "First.swift"),
            .toolResult(lines: ["First read"], lineCount: 1, isError: false)
        ], replacesEarlier: true, omitsEarlier: false))
        let (window, host) = try await host(SubagentTranscriptView(panel: panel, isFinished: false)
            .frame(width: 556, height: 400), size: NSSize(width: 556, height: 400))
        defer { window.close(); panel.close() }
        func button(_ phrase: String) -> AnyObject? {
            accessibilityElements(in: host).first {
                $0.accessibilityRole?() == .button && InkAX.label($0).contains(phrase)
            }
        }
        let first = try #require(button("Ran 1 tool"))
        #expect(first.accessibilityPerformPress?() == true)
        try await settle(window)
        panel.apply(SubagentTranscriptBatch(entries: [
            .toolCall(name: "Read", argument: "Second.swift")
        ], replacesEarlier: false, omitsEarlier: false))
        try await settle(window)
        let pending = try #require(button("2 tools"))
        #expect(!InkAX.label(pending).contains("Ran"), "a call without a result is not reported as completed")
        #expect(accessibilityElements(in: host).contains { InkAX.label($0).contains("Second.swift") },
                "the live group stays open when the next call arrives")
        panel.apply(SubagentTranscriptBatch(entries: [
            .toolResult(lines: ["Second read"], lineCount: 1, isError: false)
        ], replacesEarlier: false, omitsEarlier: false))
        try await settle(window)
        let updated = try #require(button("Ran 2 tools"))
        let elements = accessibilityElements(in: host)
        #expect(elements.contains { InkAX.label($0).contains("First.swift") })
        #expect(elements.contains { InkAX.label($0).contains("Second.swift") }, "the open group did not collapse on update")
        #expect(updated.accessibilityPerformPress?() == true)
        try await settle(window)
        panel.apply(SubagentTranscriptBatch(entries: [
            .toolCall(name: "Bash", argument: "swift test"),
            .toolResult(lines: ["Build failed"], lineCount: 1, isError: true)
        ], replacesEarlier: false, omitsEarlier: false))
        try await settle(window)
        _ = try #require(button("Ran 3 tools"))
        #expect(accessibilityElements(in: host).contains { InkAX.label($0).contains("Error: Build failed") },
                "a newly failed tool opens its group")
    }

    @Test func anEmptyRunningTranscriptStillShowsItsLiveTail() async throws {
        let panel = SubagentTranscriptModel(agentID: "a1", transcriptPath: nil, isRunning: true, windowVisible: false,
                                             locate: { _ in nil })
        panel.apply(SubagentTranscriptBatch(entries: [], replacesEarlier: true, omitsEarlier: false))
        let (window, host) = try await host(SubagentTranscriptView(panel: panel).frame(width: 400, height: 150),
                                            size: NSSize(width: 400, height: 150))
        defer { window.close(); panel.close() }
        #expect(accessibilityElements(in: host).contains {
            InkAX.label($0).contains("Running…") || (InkAX.value($0) ?? "").contains("Running…")
        })
    }

    @Test func anUnchangedBatchDoesNotRepublishTheCachedTranscript() {
        let panel = SubagentTranscriptModel(agentID: "a1", transcriptPath: nil, isRunning: true, windowVisible: false,
                                             locate: { _ in nil })
        panel.apply(SubagentTranscriptBatch(entries: [.toolCall(name: "Read", argument: "First.swift")],
                                            replacesEarlier: true, omitsEarlier: false))
        let invalidated = B5bFlag()
        withObservationTracking({ _ = panel.lines }, onChange: { invalidated.set() })
        panel.apply(SubagentTranscriptBatch(entries: [], replacesEarlier: false, omitsEarlier: false))
        #expect(!invalidated.value, "a no-op batch publishes no new projection")
        panel.apply(SubagentTranscriptBatch(entries: [.toolResult(lines: ["Done"], lineCount: 1, isError: false)],
                                            replacesEarlier: false, omitsEarlier: false))
        #expect(invalidated.value, "a new result publishes the updated group")
        panel.close()
    }

    @Test func aRingBoundaryKeepsAnOrphanToolResultVisible() throws {
        let panel = SubagentTranscriptModel(agentID: "a1", transcriptPath: nil, isRunning: false, windowVisible: false,
                                             locate: { _ in nil })
        var entries: [SubagentTranscriptEntry] = [
            .toolCall(name: "Read", argument: "Dropped.swift"),
            .toolResult(lines: ["Kept output"], lineCount: 1, isError: false)
        ]
        entries += Array(repeating: .text("Intervening entry"), count: 397)
        entries += [.toolCall(name: "Read", argument: "Kept.swift"),
                    .toolResult(lines: ["Finished output"], lineCount: 1, isError: false)]
        panel.apply(SubagentTranscriptBatch(entries: entries, replacesEarlier: true, omitsEarlier: false))
        defer { panel.close() }
        #expect(panel.items.count == SubagentTranscriptModel.ringLimit && panel.omitsEarlier)
        let orphan = try #require(panel.lines.first { $0.kind == .result })
        #expect(orphan.text == "Kept output", "the result remains visible when its call fell out of the ring")
        let group = try #require(panel.lines.last { $0.kind == .tools })
        #expect(group.text == "Ran 1 tool" && group.children.map(\.kind) == [.call, .result])
    }

    @Test func anExtraResultDoesNotCompleteALaterCall() throws {
        let panel = SubagentTranscriptModel(agentID: "a1", transcriptPath: nil, isRunning: true, windowVisible: false,
                                             locate: { _ in nil })
        defer { panel.close() }
        panel.apply(SubagentTranscriptBatch(entries: [
            .toolCall(name: "Read", argument: "First.swift"),
            .toolResult(lines: ["First output"], lineCount: 1, isError: false),
            .toolResult(lines: ["Unmatched output"], lineCount: 1, isError: false),
            .toolCall(name: "Read", argument: "Second.swift")
        ], replacesEarlier: true, omitsEarlier: true))
        let pending = try #require(panel.lines.first { $0.kind == .tools })
        #expect(!pending.text.hasPrefix("Ran"), "an earlier unmatched output cannot finish a later call")
        #expect(pending.children.map(\.kind) == [.call, .result, .result, .call])
        panel.apply(SubagentTranscriptBatch(entries: [
            .toolResult(lines: ["Second output"], lineCount: 1, isError: false)
        ], replacesEarlier: false, omitsEarlier: false))
        #expect(panel.lines.first { $0.kind == .tools }?.text == "Ran 2 tools")
    }
}
