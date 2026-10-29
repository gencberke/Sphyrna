import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport
@testable import LoomCatalogUITestRigs

// V19 pieces that need no process: the one reason wording, the one banner, the face-aware keys, the sidebar's New session
// row.

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ChatFirstPureTests {
    // MARK: Reason wording

    /// Regression: a Chat-face Bash request read "Allow: make step1" and a terminal-face one "Asks to run a command", on
    /// Home, in the sidebar and in the palette. A request is one `StatusReason`; every surface words it the same.
    @Test func aRequestReadsTheSameInBothFacesOnEverySurface() {
        let chat = SessionViewState(runEndpoint: .pipe, pendingRequests: [
            ProviderPendingRequest(requestID: "r1", toolUseID: "t1", kind: .approval, toolName: "Bash", summary: "make step1",
                                   arrivedAt: nil)])
        let terminal = SessionViewState(reason: StatusReason(.approval(tool: "Bash"), detail: "make step1"))
        for state in [chat, terminal] {
            let reason = state.displayReason
            #expect(SessionReasonLine(reason)?.text == "Asks to run: make step1")
            #expect(PaletteReasonText.line(reason: reason, indicator: .waitingForApproval, awaitingOpenApproval: false)
                == "Asks to run: make step1")
            #expect(reason.flatMap(InspectorReasonText.line) == "Asks to run: make step1")
        }
        // Without the command (a request that does not name it) both still agree.
        let bareChat = SessionViewState(runEndpoint: .pipe, pendingRequests: [
            ProviderPendingRequest(requestID: "r2", toolUseID: nil, kind: .approval, toolName: "Bash", summary: "Bash", arrivedAt: nil)])
        let bareTerminal = SessionViewState(reason: StatusReason(.approval(tool: "Bash")))
        #expect(SessionReasonLine(bareChat.displayReason)?.text == "Asks to run a command")
        #expect(SessionReasonLine(bareTerminal.displayReason)?.text == "Asks to run a command")
        // The path of an edit.
        let edit = StatusReason(.approval(tool: "Edit"), detail: "Sources/App.swift")
        #expect(SessionReasonLine(edit)?.text == "Asks to edit: Sources/App.swift")
        #expect(SessionReasonLine(StatusReason(.approval(tool: "mcp__linear__get")))?.text == "Asks to use mcp__linear__get")
    }

    // MARK: The banner

    /// D-69: the session's ⋯ menu holds no move to a face; the one item left ends a move that waits (the policy banner's).
    @Test func theHeaderMenuOffersNoMoveOnlyTheWayToCancelOneThatWaits() {
        #expect(CatalogModel.cancelMoveTitle(for: nil) == nil)
        #expect(CatalogModel.cancelMoveTitle(for: Handover(target: .terminal)) == "Cancel Continue in Terminal")
        #expect(CatalogModel.cancelMoveTitle(for: Handover(target: .terminal, phase: .switching)) == nil, "no Cancel after the point of no return")
    }

    // MARK: Face-aware keys

    @Test func controlOCyclesTheViewFromTheComposerOnlyInTheLiveChat() {
        let live = ComposerKeys.State()
        #expect(ComposerKeys.resolve(keyCode: ComposerKeys.letterO, modifiers: [.control], state: live) == .cycleView)
        #expect(ComposerKeys.resolve(keyCode: ComposerKeys.letterO, modifiers: [], state: live) == .passThrough)
        var draft = ComposerKeys.State()
        draft.mode = .draft
        #expect(ComposerKeys.resolve(keyCode: ComposerKeys.letterO, modifiers: [.control], state: draft) == .passThrough)
        var composing = ComposerKeys.State()
        composing.hasMarkedText = true
        #expect(ComposerKeys.resolve(keyCode: ComposerKeys.letterO, modifiers: [.control], state: composing) == .passThrough)
    }

    // MARK: The sidebar's New session row

    @Test func theSidebarHasANewSessionRowUnderHomeThatOpensTheDraft() async throws {
        enableAccessibilityTree()
        let rig = try await ListRig.make(projects: 2, perProject: 2, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let hosting = NSHostingController(rootView: SidebarView(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 300, height: 600))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        func ids() -> [String] {
            accessibilityElements(in: hosting.view).compactMap {
                let id = $0.accessibilityIdentifier?() ?? ""
                return id.isEmpty ? nil : id
            }
        }
        func labels() -> [String] { accessibilityElements(in: hosting.view).compactMap { $0.accessibilityLabel?() } }
        for _ in 0..<40 where !ids().contains("sidebar-new-session") {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        #expect(ids().contains("sidebar-new-session"))
        let said = labels()
        let home = try #require(said.firstIndex { $0.hasPrefix("Home") })
        let new = try #require(said.firstIndex(of: "New session"))
        #expect(home < new)
        // What the row does: the draft page in the most recently used project.
        let project = try #require(await model.recentProjectForNewSession())
        model.beginNewSessionInRecentProject()
        for _ in 0..<200 where model.destination != .draft(projectID: project) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.destination == .draft(projectID: project))
        #expect(model.detailRouteKind == "draft")
    }
}
