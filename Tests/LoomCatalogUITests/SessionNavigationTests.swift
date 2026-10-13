import AppKit
import Foundation
import LoomCore
import LoomTerminal
import Testing
@testable import LoomCatalogUI

private func candidate(_ indicator: SessionIndicator, _ seconds: Double, id: UUID = UUID()) -> AttentionCandidate {
    AttentionCandidate(id: id, indicator: indicator, lastActivityAt: Date(timeIntervalSince1970: seconds))
}

/// D-45 items 2 to 5, 7, 8 as pure rules: nothing here needs a model, a window or a process.
struct SessionNavigationRuleTests {
    // MARK: Which sessions need the user

    @Test func theAttentionSetIsExactlyWhatTheIndicatorCallsNeedsAttention() {
        let all: [SessionIndicator] = [
            .working, .waitingForApproval, .waitingForInput, .unknown, .failed(nil), .failed("x"),
            .stopUnverified("x"), .problem("x"), .identityUnclear, .unviewedCompletion, .ready, .idle,
            .stale, .ended,
        ]
        for indicator in all {
            #expect((AttentionOrder.rank(of: indicator) != nil) == indicator.needsAttention, "\(indicator)")
        }
    }

    @Test func failuresComeFirstThenApprovalThenWaitingThenFinished() {
        let failed = candidate(.failed("x"), 10), stop = candidate(.stopUnverified("x"), 20)
        let problem = candidate(.problem("x"), 30), unclear = candidate(.identityUnclear, 40)
        let approval = candidate(.waitingForApproval, 900), waiting = candidate(.waitingForInput, 800)
        let finished = candidate(.unviewedCompletion, 1000)
        let working = candidate(.working, 2000), ready = candidate(.ready, 3000)
        let order = AttentionOrder.ordered([ready, finished, waiting, working, approval, unclear, problem, stop, failed])
        // Within the failure class the most recent activity leads.
        #expect(order == [unclear, problem, stop, failed, approval, waiting, finished].map(\.id))
        #expect(AttentionOrder.count([ready, finished, waiting, working, approval, unclear, problem, stop, failed]) == 7)
        #expect(AttentionOrder.ordered([working, ready]).isEmpty)
    }

    @Test func equalSessionsKeepAStableOrder() {
        let a = candidate(.waitingForInput, 5, id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        let b = candidate(.waitingForInput, 5, id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
        #expect(AttentionOrder.ordered([b, a]) == [a.id, b.id])
        #expect(AttentionOrder.ordered([a, b]) == [a.id, b.id])
    }

    @Test func repeatedJumpsWalkTheOrderAndWrap() {
        let ids = (0..<3).map { _ in UUID() }
        var current: UUID?
        var visited: [UUID] = []
        for _ in 0..<4 {
            current = AttentionOrder.neighbor(of: current, in: ids, .next)
            visited.append(current!)
        }
        #expect(visited == [ids[0], ids[1], ids[2], ids[0]])
        #expect(AttentionOrder.neighbor(of: ids[0], in: ids, .previous) == ids[2])
        #expect(AttentionOrder.neighbor(of: ids[1], in: ids, .previous) == ids[0])
        // Nothing selected, or a session that no longer needs the user: the walk starts at an end.
        #expect(AttentionOrder.neighbor(of: nil, in: ids, .previous) == ids[2])
        #expect(AttentionOrder.neighbor(of: UUID(), in: ids, .next) == ids[0])
        #expect(AttentionOrder.neighbor(of: ids[0], in: [], .next) == nil)
        #expect(AttentionOrder.neighbor(of: ids[0], in: [ids[0]], .next) == ids[0])
    }

    // MARK: Next and previous in the list

    @Test func stepsThroughTheListAsDrawnAndDoesNotWrap() {
        let ids = (0..<3).map { _ in UUID() }
        #expect(VisibleOrder.neighbor(of: ids[0], in: ids, .next) == ids[1])
        #expect(VisibleOrder.neighbor(of: ids[1], in: ids, .previous) == ids[0])
        #expect(VisibleOrder.neighbor(of: ids[2], in: ids, .next) == nil)
        #expect(VisibleOrder.neighbor(of: ids[0], in: ids, .previous) == nil)
        // Nothing selected, or the selection is not in the list: the first / last card.
        #expect(VisibleOrder.neighbor(of: nil, in: ids, .next) == ids[0])
        #expect(VisibleOrder.neighbor(of: UUID(), in: ids, .previous) == ids[2])
        #expect(VisibleOrder.neighbor(of: nil, in: [], .next) == nil)
    }

    // MARK: Dock badge

    @Test func theBadgeShowsTheCountAndClearsAtZero() {
        #expect(DockBadge.label(count: 0) == nil)
        #expect(DockBadge.label(count: -1) == nil)
        #expect(DockBadge.label(count: 3) == "3")
    }

    // MARK: Resume command

    @Test func theResumeCommandQuotesTheFolderForAPosixShell() {
        let id = "8b2c1a52-0f6f-4a43-9c11-5d3f8e0c7a10"
        #expect(SessionCommandText.resumeCommand(directory: "/Users/me/work", providerConversationID: id)
                == "cd '/Users/me/work' && claude --resume \(id)")
        #expect(SessionCommandText.resumeCommand(directory: "/Users/me/my project", providerConversationID: id)
                == "cd '/Users/me/my project' && claude --resume \(id)")
        // A single quote ends the quoting, is written escaped, and the quoting resumes.
        #expect(SessionCommandText.resumeCommand(directory: "/tmp/it's here", providerConversationID: id)
                == "cd '/tmp/it'\\''s here' && claude --resume \(id)")
        #expect(SessionCommandText.shellQuoted("a'b'c") == "'a'\\''b'\\''c'")
        #expect(SessionCommandText.shellQuoted("$HOME `x` \"y\" ; &") == "'$HOME `x` \"y\" ; &'")
        // An id with anything a shell reads is quoted too.
        #expect(SessionCommandText.resumeCommand(directory: "/", providerConversationID: "a b;c")
                == "cd '/' && claude --resume 'a b;c'")
        #expect(SessionCommandText.resumeCommand(directory: "/", providerConversationID: "-x")
                == "cd '/' && claude --resume '-x'")
    }

    @MainActor @Test func onlyAClaudeRowWithAnIdOffersTheCopyEntries() {
        func row(_ provider: ManagedSession.Provider, id: String?) -> SessionRowModel {
            SessionRowModel(
                record: CatalogSession(
                    session: ManagedSession(provider: provider, providerConversationID: id, workingDirectory: "/tmp/a b"),
                    title: nil, createdAt: Date(), lastUsedAt: Date(), lifecycle: .idle, pinned: false),
                live: nil)
        }
        #expect(row(.claude, id: "abc").claudeSessionID == "abc")
        #expect(row(.claude, id: "abc").resumeCommand == "cd '/tmp/a b' && claude --resume abc")
        #expect(row(.claude, id: nil).claudeSessionID == nil)
        #expect(row(.claude, id: "").resumeCommand == nil)
        #expect(row(.codex, id: "abc").claudeSessionID == nil)
        #expect(row(.codex, id: "abc").resumeCommand == nil)
        #expect(row(.synthetic, id: "abc").resumeCommand == nil)
    }

    // MARK: Quit

    @Test func quitAsksOnlyForAUserQuitWithWorkInFlight() throws {
        let prompt = try #require(QuitConfirmation.prompt(busySessions: 3, systemInitiated: false))
        #expect(prompt.title == "Quit Loom and stop 3 working sessions?")
        #expect(prompt.text == "Loom stops every session it started. You can resume each one later.")
        #expect(prompt.confirmTitle == "Quit" && prompt.cancelTitle == "Cancel")
        #expect(QuitConfirmation.prompt(busySessions: 1, systemInitiated: false)?.title
                == "Quit Loom and stop 1 working session?")
        #expect(QuitConfirmation.prompt(busySessions: 0, systemInitiated: false) == nil)
        // Logout, restart and shutdown never wait for an answer.
        #expect(QuitConfirmation.prompt(busySessions: 3, systemInitiated: true) == nil)
    }

    @Test func onlyWorkingAndNeedsApprovalSessionsCountForTheQuitQuestion() {
        let counted = [candidate(.working, 1), candidate(.waitingForApproval, 2)]
        let notCounted = [
            candidate(.ready, 3), candidate(.waitingForInput, 4), candidate(.unviewedCompletion, 5),
            candidate(.idle, 6), candidate(.stale, 7), candidate(.ended, 8), candidate(.unknown, 9),
        ]
        #expect(QuitConfirmation.busyCount(counted + notCounted) == 2)
        #expect(QuitConfirmation.busyCount(notCounted) == 0)
    }

    @Test func theSystemsOwnQuitIsToldApartFromTheUsers() {
        func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
        #expect(QuitConfirmation.reasonKeyword == code("why?"))
        for reason in ["logo", "rlgo", "rrst", "rest", "rsdn", "shut"] {
            #expect(QuitConfirmation.isSystemInitiated(reason: code(reason)), "\(reason)")
        }
        #expect(!QuitConfirmation.isSystemInitiated(reason: nil), "Cmd+Q and the Dock carry no reason")
        #expect(!QuitConfirmation.isSystemInitiated(reason: code("quit")))
        #expect(!QuitConfirmation.isSystemInitiated(reason: 0))
    }

    @Test func quitAnywayIsDescribedAsNotConfirmedNeverAsSuccess() {
        let text = QuitConfirmation.failedShutdownText(remaining: "2", errors: ["err-a", "err-b", "err-c", "err-d"])
        #expect(text.contains("Remaining: 2. Errors: err-a; err-b; err-c"))
        #expect(!text.contains("err-d"))
        #expect(text.contains("without confirming that every session process stopped"))
        #expect(text.contains("may keep running"))
        #expect(!text.lowercased().contains("success"))
    }

    // MARK: Ended screens

    /// A snapshot of a real surface, so its size is the real one.
    @MainActor private func screen(_ word: String, rows: Int = 3) -> TerminalScreenSnapshot {
        let surface = TerminalSurface()
        surface.view.feed(text: (0..<rows).map { "\(word) row \($0)" }.joined(separator: "\r\n"))
        return surface.captureVisibleScreen()!
    }

    @MainActor @Test func theEndedScreenStoreKeepsAtMostSixteenAndTheLeastRecentlyUsedGoFirst() {
        let ids = (0..<20).map { _ in UUID() }
        var store = EndedScreenStore()
        #expect(EndedScreenStore.maxCount == 16)
        for id in ids.prefix(16) { store.put(screen("s"), for: id) }
        #expect(store.count == 16)
        // Showing the oldest makes it the newest: the next one in line goes instead.
        #expect(store.use(ids[0]) != nil)
        store.put(screen("s"), for: ids[16])
        #expect(store.count == 16 && store.use(ids[1]) == nil && store.use(ids[0]) != nil)
        for id in ids.suffix(3) { store.put(screen("s"), for: id) }
        #expect(store.count == 16)
        #expect(Set(store.sessionIDs) == Set([ids[0]] + ids[5...19]), "the three least recently used went, not the used one")
        // A newer screen of the same session replaces the old one.
        let again = screen("again")
        store.put(again, for: ids[19])
        #expect(store.use(ids[19]) == again && store.count == 16)
    }

    @MainActor @Test func theEndedScreenStoreIsCappedByTotalBytesToo() throws {
        let small = screen("a"), big = screen("b", rows: 20)
        #expect(big.approximateBytes > small.approximateBytes * 3)
        var store = EndedScreenStore(maxCount: 16, maxBytes: big.approximateBytes * 2 + small.approximateBytes)
        let first = UUID(), second = UUID(), third = UUID(), fourth = UUID()
        store.put(big, for: first)
        store.put(big, for: second)
        store.put(small, for: third)
        #expect(store.count == 3 && store.totalBytes <= store.maxBytes)
        store.put(big, for: fourth)
        #expect(store.use(first) == nil && store.use(fourth) != nil, "the least recently used went to make room")
        #expect(store.totalBytes <= store.maxBytes)
        // One screen alone is never dropped, whatever its size.
        var tiny = EndedScreenStore(maxCount: 16, maxBytes: 1)
        tiny.put(big, for: first)
        #expect(tiny.count == 1)
    }

    @MainActor @Test func removingAndClearingTheEndedScreenStoreLeavesNothing() {
        var store = EndedScreenStore()
        let id = UUID(), other = UUID()
        store.put(screen("x"), for: id)
        store.put(screen("y"), for: other)
        #expect(store.remove(id) && !store.remove(id) && store.use(id) == nil && store.count == 1)
        store.removeAll()
        #expect(store.count == 0 && store.totalBytes == 0 && store.sessionIDs.isEmpty && store.use(other) == nil)
    }

    // MARK: Shortcuts

    @Test func aKeyPressDecidesTheJumpDirectionByItsOwnShift() {
        // AppKit may fire either J item for either key press; the press itself says which was meant.
        for item in [StepDirection.next, .previous] {
            #expect(SessionShortcut.attentionDirection(fromKeyDown: true, shift: false, item: item) == .next)
            #expect(SessionShortcut.attentionDirection(fromKeyDown: true, shift: true, item: item) == .previous)
        }
        // A click on a menu item keeps the item's direction, whatever keys are held.
        #expect(SessionShortcut.attentionDirection(fromKeyDown: false, shift: true, item: .next) == .next)
        #expect(SessionShortcut.attentionDirection(fromKeyDown: false, shift: false, item: .previous) == .previous)
    }

    @Test func theWindowMenuShortcutsAreTheSpecifiedKeys() {
        #expect(SessionShortcut.jumpToNextAttention.keyEquivalent == "j")
        #expect(SessionShortcut.jumpToNextAttention.modifiers == [.command])
        #expect(SessionShortcut.jumpToPreviousAttention.keyEquivalent == "j")
        #expect(SessionShortcut.jumpToPreviousAttention.modifiers == [.command, .shift])
        #expect(SessionShortcut.selectNextSession.keyEquivalent == String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!))
        #expect(SessionShortcut.selectNextSession.modifiers == [.command, .option])
        #expect(SessionShortcut.selectPreviousSession.keyEquivalent == String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!))
        #expect(SessionShortcut.selectPreviousSession.modifiers == [.command, .option])
        #expect(SessionShortcut.jumpToNextAttention.title == "Jump to Next Session That Needs You")
        #expect(SessionShortcut.selectPreviousSession.title == "Select Previous Session")
    }
}
