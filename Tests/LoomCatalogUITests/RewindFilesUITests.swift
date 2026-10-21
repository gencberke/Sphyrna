import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomChat
import LoomCore
@testable import LoomCatalogUI

/// Rewind files (V21), the parts of the UI that are rules: which rows offer the action and when it is on, what the sheet
/// says and when it confirms, the keys, the marker's wording, and the footer as an unshown view draws it. No window is shown.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct RewindFilesUITests {
    private let promptID = "5b2f0c7e-2a43-4f6c-9d6e-0a1b2c3d4e5f"
    private let secondID = "6c3a1d8f-3b54-4a7d-8e7f-1b2c3d4e5f60"

    /// A transcript with two prompts, an answer with a tool, a task notification, a meta record and a marker.
    private func entries() -> [ChatEntry] {
        var model = ChatFixture.model([
            ChatFixture.user("fix the login", uuid: promptID, at: 0),
            ChatFixture.assistant("m1", uuid: "a1", blocks: [ChatFixture.tool("t1", "Bash", ["command": "ls"])], at: 1),
            ChatFixture.result("t1", "ok", at: 2),
            ChatFixture.assistant("m2", uuid: "a2", blocks: [ChatFixture.text("done")], at: 3),
            ChatFixture.line(["type": "user", "uuid": "n1", "sessionId": "s1", "timestamp": .string(ChatFixture.time(4)),
                              "isSidechain": false, "origin": ["kind": "task-notification"],
                              "message": ["role": "user", "content": "<task-notification><summary>Build done</summary></task-notification>"]]),
            ChatFixture.line(["type": "user", "uuid": "m3", "sessionId": "s1", "timestamp": .string(ChatFixture.time(5)),
                              "isSidechain": false, "isMeta": true,
                              "message": ["role": "user", "content": "<system-reminder>be brief</system-reminder>"]]),
            ChatFixture.user("and now the tests", uuid: secondID, at: 6),
        ])
        model.appendMarker(.rewound(RewindMarker(rewindID: "r1", title: "fix the login")))
        model.appendMarker(.notice("A local command printed this"))
        return model.entries
    }

    // MARK: Which rows

    @Test func onlyUserPromptsOfTheSessionOfferTheAction() throws {
        let all = entries()
        let offered = all.filter(ChatRewindAction.offers).map(\.id)
        // Typed or sent by Loom: the two prompts. Not the answer, the tool, the task notification (a notice), Loom's markers
        // or the meta record (which has no row at all).
        #expect(offered == [promptID, secondID])
        #expect(all.contains { if case .marker(.notice) = $0.body { true } else { false } })
        #expect(all.filter { if case .user = $0.body { true } else { false } }.count == 2)

        // A prompt Claude did not read has no checkpoint to go back to; a subagent's brief is no prompt of the session; a
        // row without a message uuid (a record that had none) cannot be named.
        var prompt = try #require(all.first { $0.id == promptID })
        guard case var .user(body) = prompt.body else { return }
        for delivery in [UserPrompt.Delivery.pending, .queued, .cancelled, .notDelivered] {
            body.delivery = delivery
            prompt.body = .user(body)
            #expect(!ChatRewindAction.offers(prompt))
        }
        body.delivery = .read
        body.isBrief = true
        prompt.body = .user(body)
        #expect(!ChatRewindAction.offers(prompt))
        body.isBrief = false
        prompt.body = .user(body)
        prompt.id = "user:@120"
        #expect(!ChatRewindAction.offers(prompt))
    }

    @Test func theActionIsOffInEachStateWithItsReasonAndAbsentWhereNoLiveChatStandsBehindTheStream() throws {
        let prompt = try #require(entries().first { $0.id == promptID })
        #expect(ChatRewindAction.state(for: prompt, availability: .available) == .enabled)
        #expect(ChatRewindAction.state(for: prompt, availability: .notIdle) == .disabled("Rewind works while the session waits for you"))
        #expect(ChatRewindAction.state(for: prompt, availability: .stopped) == .disabled("Resume the session to rewind its files"))
        // A transcript's stream (the terminal face's session, an ended one) has no composer: no action at all.
        #expect(ChatRewindAction.state(for: prompt, availability: nil) == .hidden)
        let answer = try #require(entries().first { if case .assistantText = $0.body { true } else { false } })
        #expect(ChatRewindAction.state(for: answer, availability: .available) == .hidden)
        #expect(ChatRewindAction.title == "Rewind Files to Before This Message")
    }

    @Test func theNewestPromptIsTheOneWhoseTurnTheRewindLosesForGood() {
        let all = entries()
        #expect(RewindMessagePlace.isNewestPrompt(secondID, in: all))
        #expect(!RewindMessagePlace.isNewestPrompt(promptID, in: all))
    }

    // MARK: The availability rule

    @Test func theAvailabilityRuleIsOneLivePromptAndNothingElse() {
        func rule(_ phase: ChatDriverPhase, turn: Bool = false, requests: Int = 0, handover: Bool = false, busy: Bool = false) -> RewindAvailability {
            .of(phase: phase, turnRunning: turn, requestCount: requests, handoverHolds: handover, rewinding: busy)
        }
        #expect(rule(.ready) == .available)
        #expect(rule(.working, turn: true) == .notIdle)
        #expect(rule(.needsYou, turn: true, requests: 1) == .notIdle)
        #expect(rule(.ready, requests: 1) == .notIdle)
        #expect(rule(.ready, turn: true) == .notIdle)
        #expect(rule(.ready, handover: true) == .notIdle)
        #expect(rule(.ready, busy: true) == .notIdle)
        #expect(rule(.starting) == .notIdle && rule(.stopping) == .notIdle)
        #expect(rule(.stopped) == .stopped && rule(.failed(.ended)) == .stopped)
    }

    // MARK: The sheet

    private func preview(files: [String], copy: ChatRewindStore.CopyVerdict = .ok(totalBytes: 10)) -> RewindPreview {
        RewindPreview(userMessageID: promptID, files: files, insertions: 12, deletions: 3, copy: copy)
    }

    @Test func theSheetShowsPathsRelativeToTheFolderWithTheTotalsAndTheMarks() {
        let content = RewindSheetContent(
            preview: preview(files: ["/work/app/src/a.swift", "/work/app/b.swift", "/elsewhere/c.txt"]),
            marks: ["/work/app/b.swift": .changedSinceClaude], workingDirectory: "/work/app", newestTurn: false)
        #expect(content.files.map(\.displayPath) == ["src/a.swift", "b.swift", "/elsewhere/c.txt"])
        #expect(content.files.map(\.mark) == [nil, .changedSinceClaude, nil])
        #expect(content.totals == "+12 \u{2212}3")
        #expect(content.canConfirm)
        #expect(RewindCopy.title == "Rewind files to before this message?")
        #expect(RewindCopy.honestLabel == "Restores the files Claude changed with its file tools to how they were before this message. "
            + "Changes made by shell commands and subagents stay. Loom keeps a copy of these files, so you can undo this.")
        #expect(RewindCopy.newestTurnNote == "This turn\u{2019}s file changes can only come back through Undo.")
    }

    @Test func rewindIsOffWhenLoomCannotKeepACopyOrNothingWouldChange() {
        func content(_ files: [String], _ copy: ChatRewindStore.CopyVerdict) -> RewindSheetContent {
            RewindSheetContent(preview: preview(files: files, copy: copy), marks: [:], workingDirectory: nil, newestTurn: true)
        }
        #expect(content(["/w/a"], .ok(totalBytes: 1)).canConfirm)
        #expect(!content(["/w/a"], .tooLarge).canConfirm)
        #expect(!content(["/w/a"], .cannotCopy(["/w/a"])).canConfirm)
        #expect(!content([], .ok(totalBytes: 0)).canConfirm)
        #expect(RewindCopy.copyProblem(.tooLarge) == "These files are too large to keep a copy for Undo")
        #expect(RewindCopy.copyProblem(.ok(totalBytes: 1)) == nil)
        #expect(content(["/w/a"], .ok(totalBytes: 1)).newestTurn)
    }

    @Test func theSheetHoldsCancelAsTheOnlyExitWhileTheRewindRuns() async throws {
        let rig = try await LiveRig.make()
        let sheet = RewindSheetState(title: "fix the login", userMessageID: promptID,
                                     driver: ChatSessionDriver(sessionID: UUID(), runtime: rig.runtime))
        #expect(sheet.phase == .loading && !sheet.canConfirm && sheet.canCancel)
        sheet.phase = .ready(RewindSheetContent(preview: preview(files: ["/w/a"]), marks: [:], workingDirectory: nil, newestTurn: false))
        #expect(sheet.canConfirm && sheet.canCancel)
        sheet.phase = .rewinding
        #expect(!sheet.canConfirm && !sheet.canCancel)
        sheet.phase = .cannot("No file checkpoint for this message")
        #expect(!sheet.canConfirm && sheet.canCancel)
        await rig.finish()
    }

    @Test func everyRefusalHasPlainWords() {
        #expect(RewindCopy.message(for: .notAvailable(.notIdle)) == "Rewind works while the session waits for you")
        #expect(RewindCopy.message(for: .notAvailable(.stopped)) == "Resume the session to rewind its files")
        #expect(RewindCopy.message(for: .cannot(.noCheckpoint)) == "No file checkpoint for this message")
        #expect(RewindCopy.message(for: .cannot(.notEnabled)) == "File rewinding is off for this run")
        #expect(RewindCopy.message(for: .tooLarge) == "These files are too large to keep a copy for Undo")
        #expect(RewindCopy.message(for: .nothingToChange) == "No files would change.")
        #expect(RewindCopy.message(for: .failed("disk full")).contains("nothing changed"))
        #expect(RewindCopy.message(for: .noAnswer).contains("Undo on the marker puts back the copy Loom kept"))
    }

    // MARK: The marker

    @Test func theMarkerNamesTheMessageAndTheTimeAndReadsRewindUndoneAfterUndo() {
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let marker = RewindMarker(rewindID: "r1", title: "fix the login")
        let text = ChatRewoundMarkerView.text(marker, date: time)
        #expect(text.hasPrefix("Files rewound to before \u{201C}fix the login\u{201D} \u{00B7} "))
        #expect(ChatRewoundMarkerView.text(marker, date: nil) == "Files rewound to before \u{201C}fix the login\u{201D}")
        var undone = marker
        undone.undo = .undone
        #expect(ChatRewoundMarkerView.text(undone, date: time) == "Rewind undone")
        #expect(ChatMarkerText.text(.rewound(undone)) == "Rewind undone")
        #expect(ChatMarkerText.text(.rewound(marker)) == "Files rewound to before \u{201C}fix the login\u{201D}")
    }

    // MARK: The footer, drawn

    private func footerIdentifiers(entry: ChatEntry, availability: RewindAvailability?) async -> (ids: [String], enabled: Bool?) {
        enableAccessibilityTree()
        let context = ChatRowContext()
        context.rewind.source = { availability }
        let hover = ChatRowHover()
        hover.isOver = true
        let hosting = NSHostingController(rootView: ChatUserMessageView(entry: entry, open: false, context: context, hover: hover)
            .frame(width: 600, height: 120))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 120), styleMask: [.borderless], backing: .buffered,
                              defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 600, height: 120))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var found: AnyObject?
        for _ in 0..<30 {
            hosting.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            found = accessibilityElements(in: hosting.view).first { $0.accessibilityIdentifier?() == "chat-row-rewind-files" }
            if found != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let ids = accessibilityElements(in: hosting.view).compactMap { $0.accessibilityIdentifier?() }.filter { !$0.isEmpty }
        return (ids, found.flatMap { $0.isAccessibilityEnabled?() })
    }

    @Test func theHoverFooterDrawsTheActionOnAPromptOnOrOffAndNotWithoutALiveChat() async throws {
        let prompt = try #require(entries().first { $0.id == promptID })
        let on = await footerIdentifiers(entry: prompt, availability: .available)
        #expect(on.ids.contains("chat-row-rewind-files") && on.enabled == true)
        let busy = await footerIdentifiers(entry: prompt, availability: .notIdle)
        #expect(busy.ids.contains("chat-row-rewind-files") && busy.enabled == false)
        let stopped = await footerIdentifiers(entry: prompt, availability: .stopped)
        #expect(stopped.ids.contains("chat-row-rewind-files") && stopped.enabled == false)
        let none = await footerIdentifiers(entry: prompt, availability: nil)
        #expect(!none.ids.contains("chat-row-rewind-files"))
    }
}
