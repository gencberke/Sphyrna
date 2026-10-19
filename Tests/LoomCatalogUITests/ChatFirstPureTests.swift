import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore

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

    @Test func thePolicySignalAndWireDriftAreOneBannerWithTheRestBehindAPlus() {
        func items(policy: Bool = false, drift: Int = 0, records: Int = 0, canContinue: Bool = true) -> [ChatBannerItem] {
            ChatBanners.items(policySignal: policy, policyDismissed: false, canContinueInTerminal: canContinue,
                              wireDrift: drift, wireDriftDismissed: false, unknownRecords: records, recordsDismissed: false)
        }
        #expect(items().isEmpty)
        let both = items(policy: true, drift: 2, records: 1)
        // The blocker comes first, then the notices; the view shows the first and "+2" for the others.
        #expect(both.map(\.kind) == [.policy, .wireDrift, .unknownRecords])
        #expect(both[0].actionTitle == "Switch to Terminal")
        #expect(both[1].actionTitle == nil)
        // Without the way to move the session the policy banner only informs.
        let stuck = ChatBanners.items(policySignal: true, policyDismissed: false, canContinueInTerminal: false, owner: .terminal,
                                      wireDrift: 0, wireDriftDismissed: false, unknownRecords: 0, recordsDismissed: false)
        #expect(stuck[0].actionTitle == nil && stuck[0].message.contains("The terminal still runs this session."))
        // M5: a Chat-owned session never says the terminal runs it.
        let chatOwned = items(policy: true, canContinue: false)
        #expect(chatOwned[0].actionTitle == nil && !chatOwned[0].message.contains("terminal still runs"))
        // A dismissed one stays gone.
        let dismissed = ChatBanners.items(policySignal: true, policyDismissed: true, canContinueInTerminal: true,
                                          wireDrift: 1, wireDriftDismissed: false, unknownRecords: 0, recordsDismissed: false)
        #expect(dismissed.map(\.kind) == [.wireDrift])
    }

    // MARK: Where a terminal session stands for a handover

    /// B1: a terminal session resting at its prompt is idle, not "a request waiting". The `idle_prompt` reminder (S0, 60 s
    /// after a Stop) moves its activity to `.waitingForInput` and keeps the last message as the reason; the registry's
    /// `idle` does the same with no reason. Only an input request (the reason `.input`) refuses.
    @Test func aTerminalSessionAtItsPromptIsIdleNotARequest() {
        let run = UUID()
        func state(_ activity: AgentActivity, reason: StatusReason? = nil, pending: Int = 0) -> SessionViewState {
            SessionViewState(status: ProviderWorkState(activity: activity, pendingProviderWorkCount: pending), runID: run,
                             reason: reason)
        }
        // After the `idle_prompt` of the S0 fixture: waiting for input, the last answer kept as the reason.
        #expect(HandoverStanding(terminal: state(.waitingForInput, reason: StatusReason(.turnDone, detail: "done"))) == .idle)
        // The registry's idle after an interrupt: waiting for input with no reason.
        #expect(HandoverStanding(terminal: state(.waitingForInput)) == .idle)
        #expect(HandoverStanding(terminal: state(.atPrompt)) == .idle)
        #expect(HandoverStanding(terminal: state(.turnComplete)) == .idle)
        // A real input request (an MCP elicitation, `agent_needs_input`) refuses.
        #expect(HandoverStanding(terminal: state(.waitingForInput, reason: StatusReason(.input))) == .requestWaiting)
        #expect(HandoverStanding(terminal: state(.waitingForApproval)) == .requestWaiting)
        // Work.
        #expect(HandoverStanding(terminal: state(.working)) == .working)
        // S3: work the provider still has pending under a finished turn is background work.
        #expect(HandoverStanding(terminal: state(.turnComplete, pending: 1)) == .backgroundWork)
        #expect(HandoverStanding(terminal: state(.waitingForInput, pending: 2)) == .backgroundWork)
        // No run, no state: stopped.
        #expect(HandoverStanding(terminal: SessionViewState(status: ProviderWorkState(activity: .atPrompt))) == .stopped)
        #expect(HandoverStanding(terminal: nil) == .stopped)
    }

    /// D-69: the session's ⋯ menu holds no move to a face; the one item left ends a move that waits (the policy banner's).
    @Test func theHeaderMenuOffersNoMoveOnlyTheWayToCancelOneThatWaits() {
        #expect(CatalogModel.cancelMoveTitle(for: nil) == nil)
        #expect(CatalogModel.cancelMoveTitle(for: Handover(target: .terminal)) == "Cancel Continue in Terminal")
        #expect(CatalogModel.cancelMoveTitle(for: Handover(target: .chat)) == "Cancel Continue in Chat")
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

    @Test func onlyAPrintableKeyTypedInTheStreamGoesToTheComposer() {
        #expect(ChatTableView.printable("a") == "a")
        #expect(ChatTableView.printable("é") == "é")
        #expect(ChatTableView.printable("?") == "?")
        #expect(ChatTableView.printable(" ") == nil, "Space scrolls")
        #expect(ChatTableView.printable("\r") == nil)
        #expect(ChatTableView.printable("\u{1B}") == nil)
        #expect(ChatTableView.printable("\u{F700}") == nil, "an arrow key carries a private-use character")
        #expect(ChatTableView.printable("") == nil)
    }

    /// M7: Option and Shift make characters on other layouts (`@`, `[`, `{`, `|`); the stream gives the event itself to the
    /// composer (so the input method sees it), and ⌘ or ⌃ stay shortcuts.
    @Test func anOptionCharacterTypedInTheStreamReachesTheComposerAsTheEvent() throws {
        let table = ChatTableView()
        let controller = ChatStreamController(context: ChatRowContext())
        table.controller = controller
        var taken: [String] = []
        controller.onTypeToFocus = { taken.append($0.characters ?? "") }
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                          context: nil, characters: characters, charactersIgnoringModifiers: "q",
                                          isARepeat: false, keyCode: 12))
        }
        for characters in ["@", "[", "{", "|", "a"] { table.keyDown(with: try key(characters, [.option])) }
        #expect(taken == ["@", "[", "{", "|", "a"])
        table.keyDown(with: try key("a", [.command]))
        table.keyDown(with: try key("\u{F700}", []))
        #expect(taken.count == 5, "a shortcut or an arrow key is not typing")
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
