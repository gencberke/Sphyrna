import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomCore

/// I6b: the review surfaces drawn offscreen, each hosted in a window nobody sees and never ordered front: the Agents list at 328,
/// a transcript at 556 (running, and finished with its Result), the Changes tab's empty and waiting states at 556, and the main
/// window's Delete sheet (ready, and blocked by a folder). With `LOOM_I6B_RENDER_DIR` set the pictures are written there as
/// `i6b-<name>-<ink|paper>.png`, in Ink and Paper, to be set beside the reference; without it each is drawn once in Ink and the test
/// only checks that something was drawn.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct InkReviewRenderTests {
    private var directory: URL? {
        ProcessInfo.processInfo.environment["LOOM_I6B_RENDER_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    private var looks: [Bool] { directory == nil ? [true] : [true, false] }

    /// Draws a view in a window nobody sees and returns what it drew; writes the picture when a folder is set. `after` runs once
    /// the view is on screen in that window (a transcript's batch arrives after its panel appeared).
    private func render<V: View>(_ view: V, name: String, size: NSSize, dark: Bool,
                                 after: (() -> Void)? = nil) async throws -> NSBitmapImageRep {
        let hosting = NSHostingController(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
                              defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        func settle() async throws {
            for _ in 0..<6 {
                try await Task.sleep(for: .milliseconds(100))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }
        try await settle()
        if let after {
            after()
            try await settle()
        }
        let bounds = hosting.view.bounds
        let rep = try #require(hosting.view.bitmapImageRepForCachingDisplay(in: bounds))
        hosting.view.cacheDisplay(in: bounds, to: rep)
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = "i6b-\(name)-\(dark ? "ink" : "paper").png"
            try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(file))
        }
        return rep
    }

    /// Something was drawn: the picture is the requested size and has more than a few distinct colours.
    private func expectDrawn(_ rep: NSBitmapImageRep, _ size: NSSize, _ name: String) {
        #expect(rep.pixelsWide >= Int(size.width) && rep.pixelsHigh >= Int(size.height), "\(name) is its size")
        var seen = Set<UInt32>()
        let step = max(1, rep.pixelsWide / 80)
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert(UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8
                            | UInt32(color.blueComponent * 255))
            }
        }
        #expect(seen.count > 6, "\(name) drew \(seen.count) colours")
    }

    private func pane<V: View>(_ view: V) -> some View {
        view.background(LoomTheme.Surface.inspector)
    }

    private static let brief = "Draw the subagent branches under a session row: one branch per row, the last one curving and ending, "
        + "and a subagent's own subagents one step further. Keep the offsets the reference uses."

    private static let stream: [SubagentTranscriptEntry] = [
        .text("I'll read the tree's current drawing first, then the tokens it uses."),
        .toolCall(name: "Read", argument: "Sources/LoomCatalogUI/SubagentTree.swift"),
        .toolResult(firstLine: "import SwiftUI", lineCount: 331, isError: false),
        .toolCall(name: "Grep", argument: "Branches\\."),
        .toolResult(firstLine: "Sources/LoomCatalogUI/LoomTheme+Tree.swift:9:        static let column: CGFloat = 22", lineCount: 14,
                    isError: false),
        .thought(milliseconds: 4_200),
        .toolCall(name: "Bash", argument: "swift build --target LoomCatalogUI"),
        .toolResult(firstLine: "error: cannot find 'curveRadius' in scope", lineCount: 3, isError: true),
        .text("The branch offsets are the reference's own; the curve token was renamed. Each branch now leaves the status column "
              + "at 22 and turns into its row with a 7 pt curve."),
    ]

    private func agentRecords(now: Date) -> [SubagentRecord] {
        [SubagentRecord(id: "a-impl", agentType: "implementer", description: "Draw the branch shape for subagent rows",
                        startedAt: now.addingTimeInterval(-95)),
         SubagentRecord(id: "a-wait", agentType: "explorer", description: "Check the tree colour's contrast in Paper",
                        startedAt: now.addingTimeInterval(-60), awaitsApproval: true),
         SubagentRecord(id: "a-done", agentType: "explorer", description: "Find every tree offset in the sidebar",
                        startedAt: now.addingTimeInterval(-400), endedAt: now.addingTimeInterval(-306)),
         SubagentRecord(id: "a-cut", agentType: "reviewer", description: "Review the branch tests", depth: 2,
                        startedAt: now.addingTimeInterval(-380), endedAt: now.addingTimeInterval(-339), wasInterrupted: true)]
    }

    @Test func theAgentsListAndTranscriptsDrawInBothLooks() async throws {
        let rig = try await InspectorRig.make()
        defer { rig.cleanup() }
        let model = rig.model
        let id = rig.ids[0]
        await rig.goLive(0, agentRecords(now: model.now))
        model.select(id)
        model.selectInspectorTab(.agents)
        let row = try #require(model.selectedRow)
        let list = NSSize(width: LoomTheme.Rhythm.inspectorWidth, height: 520)
        let review = NSSize(width: LoomTheme.Rhythm.inspectorWidthReview, height: 720)
        for dark in looks {
            model.closeSubagent()
            let rep = try await render(pane(InspectorAgents(model: model, row: row)), name: "agents-list", size: list, dark: dark)
            expectDrawn(rep, list, "agents-list")

            for (agent, name) in [("a-impl", "agents-transcript-running"), ("a-done", "agents-transcript-finished")] {
                model.openSubagent(agent, in: id)
                #expect(model.shownInspectorWidth == LoomTheme.Rhythm.inspectorWidthReview)
                let panel = try #require(model.subagentPanel)
                let transcript = try await render(pane(InspectorAgents(model: model, row: row)), name: name, size: review, dark: dark,
                                                  after: {
                    panel.apply(SubagentTranscriptBatch(entries: [.brief(Self.brief)] + Self.stream, replacesEarlier: true,
                                                        omitsEarlier: false))
                })
                #expect(panel.phase == .live)
                expectDrawn(transcript, review, name)
                model.closeSubagent()
            }
        }
    }

    @Test func aStoppedSessionsEmptyListDrawsItsSentence() async throws {
        let rig = try await InspectorRig.make()
        defer { rig.cleanup() }
        rig.model.select(rig.ids[0])
        let row = try #require(rig.model.selectedRow)
        let size = NSSize(width: LoomTheme.Rhythm.inspectorWidth, height: 260)
        for dark in looks {
            let rep = try await render(pane(InspectorAgents(model: rig.model, row: row)), name: "agents-empty", size: size, dark: dark)
            expectDrawn(rep, size, "agents-empty")
        }
    }

    @Test func theChangesTabsEmptyAndWaitingStatesDrawInBothLooks() async throws {
        let rig = try await InspectorRig.make()
        defer { rig.cleanup() }
        let model = rig.model
        let id = rig.ids[0]
        model.select(id)
        let row = try #require(model.selectedRow)
        let session = model.changes.session(for: id)
        let size = NSSize(width: LoomTheme.Rhythm.inspectorWidthReview, height: 300)
        for dark in looks {
            session.scope = .lastTurn
            session.setState(.ready(ChangesScopeData(files: [])), for: .lastTurn)
            expectDrawn(try await render(pane(ChangesTab(model: model, row: row)), name: "changes-empty-turn", size: size, dark: dark),
                        size, "changes-empty-turn")
            session.scope = .branch
            session.setState(.ready(ChangesScopeData(files: [], baseName: "main", onBase: true)), for: .branch)
            expectDrawn(try await render(pane(ChangesTab(model: model, row: row)), name: "changes-empty-base", size: size, dark: dark),
                        size, "changes-empty-base")
            session.setState(.loading, for: .branch)
            expectDrawn(try await render(pane(ChangesTab(model: model, row: row)), name: "changes-reading-branch", size: size,
                                         dark: dark), size, "changes-reading-branch")
            session.setState(.off("Not a Git repository"), for: .branch)
            expectDrawn(try await render(pane(ChangesTab(model: model, row: row)), name: "changes-off", size: size, dark: dark),
                        size, "changes-off")
        }
    }

    private func sheet(model: CatalogModel, confirmation: DeletionConfirmation) -> some View {
        ZStack(alignment: .top) {
            LoomTheme.Surface.canvas
            Rectangle().fill(LoomTheme.Surface.scrim)
            DeleteConversationSheet(model: model, confirmation: confirmation).padding(.top, LoomTheme.Sheet.defaultHeaderOffset)
        }
    }

    @Test func theDeleteSheetDrawsItsListsInBothLooks() async throws {
        let rig = try await InspectorRig.make()
        defer { rig.cleanup() }
        let size = NSSize(width: 720, height: 560)
        let home = NSHomeDirectory() + "/.claude"
        for dark in looks {
            let ready = DeletionConfirmation(id: rig.ids[0], title: "Port the sidebar to Ink tokens")
            var preview = ConversationDeletionPreview(sessionID: rig.ids[0], fileCount: 214, byteCount: 18_200_000,
                                                      configDirectory: home, isRunning: false, notRemoved: [], unreachable: [])
            preview.sideChatCount = 2
            ready.phase = .ready(preview)
            expectDrawn(try await render(sheet(model: rig.model, confirmation: ready), name: "sheet-delete", size: size, dark: dark),
                        size, "sheet-delete")
            let blocked = DeletionConfirmation(id: rig.ids[0], title: "Port the sidebar to Ink tokens")
            blocked.phase = .ready(ConversationDeletionPreview(sessionID: rig.ids[0], fileCount: 3, byteCount: 4_096,
                                                               configDirectory: home, isRunning: true, notRemoved: [],
                                                               unreachable: ["~/.claude/projects"]))
            expectDrawn(try await render(sheet(model: rig.model, confirmation: blocked), name: "sheet-delete-blocked", size: size,
                                         dark: dark), size, "sheet-delete-blocked")
        }
    }
}
