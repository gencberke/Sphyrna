import AppKit
import Foundation
import LoomCore
import LoomTerminal
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// Fix round 3 F (D-69): the header's model segment, the model and the context fill on every face without the composer
/// bar. The words and the width rules first (pure), then the real `DetailHeader` and the inspector's Overview hosted in a
/// window that is never ordered front, read through their accessibility elements.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct HeaderModelSegmentTests {
    private nonisolated static let zone = TimeZone(identifier: "UTC")!
    private nonisolated static let now = Date(timeIntervalSince1970: 1_791_374_400)

    // MARK: The words

    @Test func theTextAndTheTooltipFollowTheReading() {
        let known = ContextUsage(tokens: 84_200, window: 200_000, model: "claude-opus-5-5-20261001")
        let content = HeaderModelContent(usage: known, launchModel: nil, catalog: ModelCatalog())
        #expect(content?.name == "Opus 5.5", "the composer bar's wording of the model id")
        #expect(content?.help == "Context \u{00B7} 84.2K of 200K (42%)\nclaude-opus-5-5-20261001")
        #expect(content?.accessibilityLabel.hasPrefix("Model Opus 5.5, Context, ") == true)

        // No window: the tokens only, never a share.
        let unknown = ContextUsage(tokens: 84_200, window: nil, model: "claude-sonnet-5")
        let open = HeaderModelContent(usage: unknown, launchModel: nil, catalog: ModelCatalog())
        #expect(open?.name == "Sonnet 5")
        #expect(open?.help == "Context \u{00B7} 84.2K\nclaude-sonnet-5")
        #expect(open?.help.contains("%") == false && unknown.percent == nil)

        // A reading is the model that answered; the launch choice does not override it.
        #expect(HeaderModelContent(usage: known, launchModel: "haiku", catalog: ModelCatalog())?.name == "Opus 5.5")
        // A reading that names no model still shows its ring, with the launch model if one was picked.
        let anonymous = ContextUsage(tokens: 1_000, window: 200_000, model: "")
        #expect(HeaderModelContent(usage: anonymous, launchModel: nil, catalog: ModelCatalog())?.name == nil)
        #expect(HeaderModelContent(usage: anonymous, launchModel: "sonnet", catalog: ModelCatalog())?.name == "Sonnet")
    }

    @Test func beforeAReadingItIsTheLaunchModelOrNothing() {
        let alias = HeaderModelContent(usage: nil, launchModel: "opus", catalog: ModelCatalog())
        #expect(alias?.name == "Opus" && alias?.usage == nil)
        #expect(alias?.help == "Model \u{00B7} Opus (chosen at launch)")
        #expect(HeaderModelContent(usage: nil, launchModel: "claude-sonnet-5", catalog: ModelCatalog())?.name == "Sonnet 5")
        // Never a guessed model: no choice, an empty one and Default (the CLI picks) say nothing.
        #expect(HeaderModelContent(usage: nil, launchModel: nil, catalog: ModelCatalog()) == nil)
        #expect(HeaderModelContent(usage: nil, launchModel: "", catalog: ModelCatalog()) == nil)
        #expect(HeaderModelContent(usage: nil, launchModel: "default", catalog: ModelCatalog()) == nil)
    }

    // MARK: The width rules (pure)

    private func plan(_ width: CGFloat, model: CGFloat? = 70) -> HeaderFlowPlan {
        HeaderFlowPlan.make(width: width, title: 235, status: HeaderFlowPlan.Status(ideal: 109),
                            chip: HeaderFlowPlan.Chip(full: 174, compact: 96), model: model, rule: 5, group: 87, spacing: 8)
    }

    @Test func theSegmentDropsBeforeTheBranchDoes() {
        // Everything fits: the segment sits after the chip, the title keeps its own width.
        let wide = plan(1_000)
        #expect(wide.model == 70 && wide.showsBranch && wide.chip == 174 && wide.title == 235)
        // The title shortens first, down to its 100 pt, with the segment and the branch both there.
        let edge: CGFloat = 100 + 8 + 109 + 8 + 174 + 8 + 70 + 8 + 5 + 8 + 87
        #expect(plan(edge).model == 70 && plan(edge).showsBranch && plan(edge).title == 100)
        // One point less: the segment goes, the branch stays whole, the title gets the room back.
        let dropped = plan(edge - 1)
        #expect(dropped.model == nil && dropped.showsBranch && dropped.chip == 174 && dropped.title >= 100)
        // The branch goes only where it would have gone without a segment (`plan(.., model: nil)`).
        for width in stride(from: edge, through: 300, by: -3) {
            let with = plan(width), without = plan(width, model: nil)
            #expect(with.showsBranch == without.showsBranch && with.chip == without.chip, "width \(width)")
            if with.model != nil { #expect(with.showsBranch, "the segment never shows without the branch (width \(width))") }
            #expect(with.status == 109, "the pill never shortens (width \(width))")
        }
        // No segment (width 0 or nil) changes nothing against the rules without it.
        #expect(plan(700, model: 0) == plan(700, model: nil))
    }

    @Test func aRowWithoutAChipPlacesTheSegmentAfterTheState() {
        func bare(_ width: CGFloat) -> HeaderFlowPlan {
            HeaderFlowPlan.make(width: width, title: 235, status: HeaderFlowPlan.Status(ideal: 109), chip: nil, model: 70,
                                rule: 5, group: 87, spacing: 8)
        }
        #expect(bare(700).model == 70)
        let edge: CGFloat = 100 + 8 + 109 + 8 + 70 + 8 + 5 + 8 + 87
        #expect(bare(edge).model == 70 && bare(edge - 1).model == nil)
    }

    // MARK: Fixture

    /// A Claude session in a repository inside a project, with a conversation id the usage index can be asked about; a Codex
    /// session; a session with a launch model; one without any.
    private struct Rig {
        let model: CatalogModel
        let catalog: SessionCatalog
        let root: URL
        let intents: Intents
        let index: ContextFakeIndex
        let usage: UsageModel
        /// "conv-main", in a project, launched with the `sonnet` alias.
        let main: UUID
        /// "conv-bare", no launch model.
        let bare: UUID
        let codex: UUID
    }

    @MainActor
    final class Intents: ConversationIntents {
        var terminals: [UUID: NSView] = [:]
        /// What the runtime's toolchain probe would answer.
        var version: String?
        func start(provider: ManagedSession.Provider, projectID: UUID?) {}
        func resume(sessionID: UUID) {}
        func stop(sessionID: UUID) {}
        func answer(sessionID: UUID, requestID: String, accept: Bool) {}
        func viewed(sessionID: UUID) {}
        func terminalView(sessionID: UUID) -> NSView? { terminals[sessionID] }
        func toolchainVersion(provider: ManagedSession.Provider) async -> String? { provider == .claude ? version : nil }
    }

    private func rig() async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-header-model-\(UUID())")
        let repo = root.appendingPathComponent("edd-backend", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/al-audit\n".utf8).write(to: repo.appendingPathComponent(".git/HEAD"))
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let project = try await catalog.addProject(path: repo.path).project
        func insert(_ provider: ManagedSession.Provider, _ conversation: String, _ title: String, at seconds: Double) async throws -> UUID {
            let session = ManagedSession(provider: provider, providerConversationID: conversation, workingDirectory: repo.path)
            try await catalog.insertSession(
                session, title: title, createdAt: Date(timeIntervalSince1970: seconds),
                lastUsedAt: Date(timeIntervalSince1970: seconds), lifecycle: .idle, projectID: project.id)
            return session.id
        }
        let main = try await insert(.claude, "conv-main", "AL contract denetimi ve tam review", at: 3_000)
        let bare = try await insert(.claude, "conv-bare", "A session nothing was picked for", at: 2_000)
        let codex = try await insert(.codex, "conv-codex", "A Codex session", at: 1_000)
        try await catalog.recordLaunchChoices(ClaudeLaunchChoices(permissionMode: "default", model: "sonnet", effort: "high"), sessionID: main)
        let index = ContextFakeIndex()
        let usage = UsageModel(index: index, clock: { Self.now }, timeZone: Self.zone,
                               debounce: .milliseconds(20), activationCooldown: .zero)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let intents = Intents()
        model.intents = intents
        model.usage = usage
        await model.start()
        await model.stopAndWait()
        await model.settle()
        return Rig(model: model, catalog: catalog, root: root, intents: intents, index: index, usage: usage,
                   main: main, bare: bare, codex: codex)
    }

    private func cleanup(_ rig: Rig) {
        rig.model.stop()
        try? FileManager.default.removeItem(at: rig.root)
    }

    private func sample(_ model: String = "claude-opus-5-5-20261001", cacheRead: Int64 = 80_000) -> SessionContextSample {
        SessionContextSample(model: model, timestamp: Self.now,
                             tokens: UsageTokens(input: 4_000, output: 1_500, cacheWrite5m: 200, cacheRead: cacheRead))
    }

    private func select(_ id: UUID, in rig: Rig, live: SessionViewState? = nil) async throws {
        rig.model.select(id)
        await rig.model.settle()
        try #require(rig.model.selectedRow).apply(live: live)
    }

    /// The chat face's run: driven by a pipe, no terminal.
    private func pipeRun() -> SessionViewState {
        SessionViewState(status: ProviderWorkState(activity: .atPrompt), runID: UUID(), runEndpoint: .pipe)
    }

    private func waitUntil(_ seconds: TimeInterval = 6, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    // MARK: Which faces

    @Test func theSegmentBelongsToTheTerminalAndTheReadOnlyChatNotToTheLiveChat() async throws {
        let rig = try await rig()
        defer { cleanup(rig) }
        rig.intents.terminals[rig.main] = TerminalSurface().view

        try await select(rig.main, in: rig, live: SessionViewState(status: ProviderWorkState(activity: .atPrompt), runID: UUID(),
                                                                    runEndpoint: .terminal))
        #expect(rig.model.detailRouteKind == "terminal")
        #expect(rig.model.headerShowsModelSegment(try #require(rig.model.selectedRow)))
        #expect(rig.model.inspectorContextSessions == ["conv-main"], "the header's ring is read for the selected session")

        // The read-only chat: no terminal, the Chat view on.
        rig.intents.terminals[rig.main] = nil
        rig.model.readOnlyChatEnabled = true
        try await select(rig.main, in: rig, live: nil)
        #expect(rig.model.detailRouteKind == "chat")
        #expect(rig.model.headerShowsModelSegment(try #require(rig.model.selectedRow)))
        #expect(rig.model.inspectorContextSessions == ["conv-main"])

        // The live chat has the composer bar's model chip and ring: no second copy.
        try await select(rig.main, in: rig, live: pipeRun())
        #expect(rig.model.detailRouteKind == "chat")
        #expect(!rig.model.headerShowsModelSegment(try #require(rig.model.selectedRow)))
        // Its ring is read all the same (the composer's fallback), as before.
        #expect(rig.model.inspectorContextSessions == ["conv-main"])

        // Codex's rollout carries its context (FB6-14): the segment is there and its ring is read for that session. With
        // no reading and no launch model yet, the segment says nothing.
        try await select(rig.codex, in: rig)
        #expect(rig.model.headerShowsModelSegment(try #require(rig.model.selectedRow)))
        #expect(rig.model.modelContent(of: try #require(rig.model.selectedRow).record) == nil)
        #expect(rig.model.inspectorContextSessions == ["conv-codex"])
    }

    // MARK: Hosted pictures

    private func host<Content: View>(_ content: Content, width: CGFloat) -> (NSWindow, NSHostingController<some View>) {
        let size = NSSize(width: width, height: LoomTheme.Layout.headerHeight)
        let hosting = NSHostingController(rootView: content
            .frame(width: width, height: LoomTheme.Layout.headerHeight, alignment: .top)
            .background(LoomTheme.Surface.panel)
            .preferredColorScheme(.dark))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        return (window, hosting)
    }

    private func settle(_ window: NSWindow, rounds: Int = 4) async throws {
        for _ in 0..<rounds {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    /// What the header shows at a width: the model segment (its label and frame), the chip's frame and whether the chip
    /// still carries its branch (its label says so).
    private struct Shown {
        var label: String?
        var segment: CGRect?
        var chip: CGRect?
        var chipHasBranch = false
        var menu: CGRect?
        var labels: [String] = []
    }

    private func header(_ rig: Rig, width: CGFloat) async throws -> Shown {
        enableAccessibilityTree()
        let (window, hosting) = host(DetailHeader(model: rig.model), width: width)
        defer { window.close() }
        try await settle(window)
        return read(hosting.view, window: window)
    }

    private func read(_ view: NSView, window: NSWindow) -> Shown {
        var shown = Shown()
        for element in accessibilityElements(in: view) {
            let role: Any? = element.accessibilityRole?()
            guard let frame = element.accessibilityFrame?(), frame.width > 0 else { continue }
            let local = CGRect(x: frame.minX - window.frame.minX, y: frame.minY, width: frame.width, height: frame.height)
            if (role as? NSAccessibility.Role) == .menuButton { shown.menu = shown.menu ?? local; continue }
            let labelValue: Any? = element.accessibilityLabel?()
            let valueValue: Any? = element.accessibilityValue?()
            guard let label = (labelValue as? String) ?? (valueValue as? String) else { continue }
            shown.labels.append(label)
            if label.hasPrefix("Project:") || label.hasPrefix("branch ") {
                shown.chip = shown.chip ?? local
                shown.chipHasBranch = label.contains("branch al-audit")
            } else if label.hasPrefix("Model ") || label.hasPrefix("Context, ") {
                shown.label = shown.label ?? label
                shown.segment = shown.segment ?? local
            }
        }
        return shown
    }

    @Test func theTerminalFaceShowsTheModelAndTheRingAfterTheChipAndNotTheLiveChat() async throws {
        let rig = try await rig()
        defer { cleanup(rig) }
        rig.intents.terminals[rig.main] = TerminalSurface().view
        rig.index.set(["conv-main": sample()])
        rig.usage.setContextWindow(200_000, forModel: "claude-opus-5-5")
        try await select(rig.main, in: rig, live: SessionViewState(status: ProviderWorkState(activity: .atPrompt), runID: UUID(),
                                                                    runEndpoint: .terminal))
        rig.model.trackInspectorContext()
        await rig.usage.settle()
        #expect(rig.usage.contexts["conv-main"]?.percent == 42)

        let wide = try await header(rig, width: 900)
        let label = try #require(wide.label, "labels \(wide.labels)")
        #expect(label.hasPrefix("Model Opus 5.5, Context, ") && label.contains("42 percent"), "label \(label)")
        let segment = try #require(wide.segment), chip = try #require(wide.chip), menu = try #require(wide.menu)
        #expect(segment.minX >= chip.maxX, "after the project and branch chip: \(segment) \(chip)")
        #expect(segment.maxX <= menu.minX, "before the control group")
        #expect(wide.chipHasBranch)

        // The live chat has its bar: the header carries no second copy.
        rig.intents.terminals[rig.main] = nil
        try await select(rig.main, in: rig, live: pipeRun())
        let live = try await header(rig, width: 900)
        #expect(live.segment == nil, "labels \(live.labels)")
    }

    @Test func beforeTheFirstReplyItShowsTheLaunchModelWithoutARingOrNothing() async throws {
        let rig = try await rig()
        defer { cleanup(rig) }
        rig.model.readOnlyChatEnabled = true

        try await select(rig.main, in: rig)
        rig.model.trackInspectorContext()
        await rig.usage.settle()
        #expect(rig.usage.contexts.isEmpty, "the index holds no reading yet")
        // The row reads the launch model on its own: the launch choice sits in the catalog, which the UI keeps no copy of.
        enableAccessibilityTree()
        let (window, hosting) = host(DetailHeader(model: rig.model), width: 900)
        defer { window.close() }
        try await settle(window, rounds: 2)
        var shown = read(hosting.view, window: window)
        for _ in 0..<20 where shown.label == nil {
            try await settle(window, rounds: 1)
            shown = read(hosting.view, window: window)
        }
        #expect(shown.label == "Model Sonnet, chosen at launch", "labels \(shown.labels)")
        #expect(!shown.labels.contains { $0.hasPrefix("Context, ") }, "no ring and no percent without a reading")

        // A session nothing was picked for says nothing, and no model is guessed.
        try await select(rig.bare, in: rig)
        let bare = try await header(rig, width: 900)
        #expect(bare.segment == nil, "labels \(bare.labels)")
        #expect(bare.chip != nil)
    }

    @Test func narrowerRowsDropTheSegmentBeforeTheBranch() async throws {
        let rig = try await rig()
        defer { cleanup(rig) }
        rig.intents.terminals[rig.main] = TerminalSurface().view
        rig.index.set(["conv-main": sample()])
        rig.usage.setContextWindow(200_000, forModel: "claude-opus-5-5")
        try await select(rig.main, in: rig, live: SessionViewState(status: ProviderWorkState(activity: .working), runID: UUID(),
                                                                    runEndpoint: .terminal))
        rig.model.trackInspectorContext()
        await rig.usage.settle()

        var wasThere = false, wentWhileBranchStayed = false
        for width in [900, 760, 680, 620, 580, 540, 500, 440] as [CGFloat] {
            let shown = try await header(rig, width: width)
            if shown.segment != nil {
                wasThere = true
                #expect(shown.chipHasBranch, "width \(width): the segment shows only with the whole chip")
            } else if shown.chipHasBranch {
                wentWhileBranchStayed = true
            }
            #expect(shown.menu != nil, "width \(width): the control group stays")
        }
        #expect(wasThere, "the segment shows at the wide widths")
        #expect(wentWhileBranchStayed, "somewhere the segment is gone and the branch is still there")
    }

    // MARK: Cost

    @Test(.renderProbe) func aReadingRedrawsTheSegmentAndNotTheRow() async throws {
        let rig = try await rig()
        defer { cleanup(rig) }
        rig.intents.terminals[rig.main] = TerminalSurface().view
        rig.index.set(["conv-main": sample(cacheRead: 10_000)])
        rig.usage.setContextWindow(200_000, forModel: "claude-opus-5-5")
        try await select(rig.main, in: rig, live: SessionViewState(status: ProviderWorkState(activity: .atPrompt), runID: UUID(),
                                                                    runEndpoint: .terminal))
        rig.model.trackInspectorContext()
        await rig.usage.settle()

        enableAccessibilityTree()
        RenderProbeExclusive.watchHeader([rig.main])
        defer { HeaderRenderProbe.watch([]) }
        let (window, _) = host(DetailHeader(model: rig.model), width: 900)
        defer { window.close() }
        try await settle(window)
        let (rows, segments) = (HeaderRenderProbe.rowBodies, HeaderRenderProbe.segmentBodies)
        #expect(rows >= 1 && segments >= 1)

        // The session's context grows: the index is asked again, as after every refresh.
        rig.index.set(["conv-main": sample(cacheRead: 90_000)])
        await rig.usage.refreshNow(reason: .manual)
        await rig.usage.settle()
        try await settle(window)
        #expect(rig.usage.contexts["conv-main"]?.tokens == 94_200)
        #expect(HeaderRenderProbe.segmentBodies > segments, "the segment follows its reading")
        #expect(HeaderRenderProbe.rowBodies == rows, "the row did not redraw for a reading")

        // Another session's reading is not asked for (only the selected one is tracked): nothing redraws at all.
        rig.index.set(["conv-main": sample(cacheRead: 90_000), "conv-bare": sample(cacheRead: 1_000)])
        let afterSegments = HeaderRenderProbe.segmentBodies
        await rig.usage.refreshNow(reason: .manual)
        await rig.usage.settle()
        try await settle(window, rounds: 2)
        #expect(rig.usage.contexts["conv-bare"] == nil)
        #expect(HeaderRenderProbe.segmentBodies == afterSegments && HeaderRenderProbe.rowBodies == rows)
    }

    // MARK: The inspector

    /// The labels and values of the Overview's elements, in order, hosted for `row`; with `waitingFor`, until that text shows.
    private func overviewTexts(_ rig: Rig, row: SessionRowModel, waitingFor wanted: String?) async throws -> [String] {
        enableAccessibilityTree()
        let size = NSSize(width: 320, height: 600)
        let hosting = NSHostingController(rootView: InspectorOverview(model: rig.model, row: row)
            .frame(width: size.width, height: size.height).background(LoomTheme.Surface.panel).preferredColorScheme(.dark))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        try await settle(window, rounds: 2)
        func texts() -> [String] {
            accessibilityElements(in: hosting.view).flatMap { element -> [String] in
                let label: Any? = element.accessibilityLabel?()
                let value: Any? = element.accessibilityValue?()
                return [label as? String, value as? String].compactMap { $0 }.filter { !$0.isEmpty }
            }
        }
        var found = texts()
        for _ in 0..<(wanted == nil ? 3 : 20) where !found.contains(where: { Self.isRow(wanted ?? "", $0) }) {
            try await settle(window, rounds: 1)
            found = texts()
        }
        return found
    }

    /// Whether an accessibility label is the Overview's row (or section) `name`: the name alone, or the name before its value.
    /// Without case: the section labels draw in capitals (Ink's label type), and the tree reads them so.
    private static func isRow(_ name: String, _ label: String) -> Bool {
        let (name, label) = (name.lowercased(), label.lowercased())
        return label == name || label.hasPrefix(name + ",") || label.hasPrefix(name + " ")
    }

    private func rows(_ names: [String], in texts: [String]) -> [String] {
        names.filter { name in texts.contains { Self.isRow(name, $0) } }
    }

    @Test func theInspectorOverviewHasTheRunRowInTheSessionSectionBeforeTheBranch() async throws {
        let rig = try await rig()
        defer { cleanup(rig) }
        rig.index.set(["conv-main": sample()])
        rig.usage.setContextWindow(200_000, forModel: "claude-opus-5-5")
        try await select(rig.main, in: rig)
        rig.model.trackInspectorContext()
        await rig.usage.settle()

        // The model is the third part of the run row (the harness's name: "Claude Code … · Opus 5.5 · effort), in Session, which
        // comes before Worktree and its Branch; the model's words are the header segment's.
        let row = try #require(rig.model.selectedRow)
        let texts = try await overviewTexts(rig, row: row, waitingFor: "Claude")
        let run = try #require(texts.firstIndex { Self.isRow("Claude", $0) }, "texts \(texts)")
        let branch = try #require(texts.firstIndex { Self.isRow("Branch", $0) }, "texts \(texts)")
        #expect(run < branch, "the run row is in Session, before Worktree's Branch: \(texts)")
        #expect(!texts.contains { Self.isRow("Model", $0) }, "the model is not a row of its own any more: \(texts)")
        #expect(rig.model.modelContent(of: row.record)?.name == "Opus 5.5")
    }

    @Test func theInspectorRunRowHoldsTheLaunchModelBeforeAReadingAndIsAbsentWithoutBoth() async throws {
        let rig = try await rig()
        defer { cleanup(rig) }
        try await select(rig.main, in: rig)
        let mainRow = try #require(rig.model.selectedRow)
        #expect(rig.model.modelContent(of: mainRow.record) == nil, "nothing is read until the view asks for the launch model")
        let launched = try await overviewTexts(rig, row: mainRow, waitingFor: "Claude")
        #expect(launched.contains { Self.isRow("Claude", $0) }, "the run row shows once the launch model is read: \(launched)")
        #expect(rig.model.modelContent(of: mainRow.record)?.name == "Sonnet")
        #expect(rig.model.modelContent(of: mainRow.record)?.usage == nil)
        // The stored effort and mode, until the run reports its own.
        #expect(rig.model.launchModels.effort(of: rig.main) == "high" && rig.model.launchModels.permissionMode(of: rig.main) == "default")
        #expect(launched.contains { Self.isRow("Mode", $0) }, "the stored mode shows before the run reports: \(launched)")

        try await select(rig.bare, in: rig)
        let none = try await overviewTexts(rig, row: try #require(rig.model.selectedRow), waitingFor: nil)
        #expect(!none.contains { Self.isRow("Claude", $0) }, "no model and no version: no run row: \(none)")
        #expect(!none.contains { Self.isRow("Mode", $0) }, "no mode was ever recorded for it: \(none)")
        #expect(none.contains { Self.isRow("Branch", $0) })
    }

    @Test func theOverviewDrawsItsSectionsInOrderForALiveTerminalSession() async throws {
        let rig = try await rig()
        defer { cleanup(rig) }
        rig.intents.version = "2.1.300"
        rig.intents.terminals[rig.main] = TerminalSurface().view
        rig.index.set(["conv-main": sample()])
        rig.usage.setContextWindow(200_000, forModel: "claude-opus-5-5")
        let live = SessionViewState(
            status: ProviderWorkState(activity: .working), runID: UUID(), subagents: [inspectorRecord("a1")], runEndpoint: .terminal,
            permissionMode: "acceptEdits", effort: "max")
        try await select(rig.main, in: rig, live: live)
        rig.model.trackInspectorContext()
        await rig.usage.settle()
        let row = try #require(rig.model.selectedRow)
        #expect(rig.model.launchModels.claudeVersion == nil, "the toolchain is not asked before the Overview is on screen")
        let texts = try await overviewTexts(rig, row: row, waitingFor: "Claude")

        let sections = ["Session", "Context", "Usage", "Worktree", "Changes", "Agents"]
        #expect(rows(sections, in: texts).count == 6, "the six sections: \(texts)")
        let order = sections.compactMap { name in texts.firstIndex { Self.isRow(name, $0) } }
        #expect(order == order.sorted() && order.count == 6, "in the reference's order: \(texts)")
        // The start time shares the State line, and the model and effort share the harness's row.
        let facts = rows(["State", "Started", "Claude", "Model", "Mode", "Project", "Branch", "Folder"], in: texts)
        #expect(facts == ["State", "Claude", "Mode", "Project", "Branch", "Folder"], "texts \(texts)")
        #expect(texts.contains("1 running"), "the Agents headline: \(texts)")
        #expect(rig.model.modelContent(of: row.record)?.name == "Opus 5.5")
        #expect(rig.model.launchModels.claudeVersion == "2.1.300")
        // The run's own words win over what was stored at launch (default, high).
        #expect(rig.model.launchModels.permissionMode(of: rig.main) == "default" && row.live?.permissionMode == "acceptEdits")
    }

    /// Codex's Overview has what its rollout carries (FB6-14): context, usage and the last turn's edits. Codex has no agents
    /// and reports no run settings, so neither the Agents section nor Claude's harness facts appear.
    @Test func aCodexSessionsOverviewHasWhatItsRolloutCarries() async throws {
        let rig = try await rig()
        defer { cleanup(rig) }
        rig.intents.version = "2.1.300"
        try await select(rig.codex, in: rig)
        let row = try #require(rig.model.selectedRow)
        let texts = try await overviewTexts(rig, row: row, waitingFor: "Folder")
        let sections = ["Session", "Context", "Usage", "Worktree", "Changes"]
        #expect(rows(sections, in: texts) == sections, "texts \(texts)")
        #expect(rows(["State", "Project", "Branch", "Folder"], in: texts) == ["State", "Project", "Branch", "Folder"])
        #expect(rows(["Claude", "Model", "Mode", "Effort"], in: texts).isEmpty, "no run settings for Codex: \(texts)")
        #expect(!texts.contains { $0.lowercased().hasPrefix("agents") }, "no Agents section: \(texts)")
        // Opened on Overview, the last turn's edits are read from the rollout.
        rig.model.setInspector(open: true, for: rig.codex)
        #expect(rig.model.changesTrigger?.scope == .lastTurn && rig.model.changesTrigger?.source?.kind == .codex)
    }

    @Test func aSessionWithoutAgentsHidesTheAgentsSectionAndSaysThereIsNoReading() async throws {
        let rig = try await rig()
        defer { cleanup(rig) }
        try await select(rig.bare, in: rig)
        let row = try #require(rig.model.selectedRow)
        let texts = try await overviewTexts(rig, row: row, waitingFor: "Folder")
        #expect(!texts.contains { $0.lowercased().hasPrefix("agents") }, "no agent ever: no section: \(texts)")
        #expect(rows(["Changes"], in: texts).count == 1, "a Claude session lists its last turn: \(texts)")
        #expect(texts.contains { $0.hasPrefix("No reading yet") }, "texts \(texts)")
    }
}
