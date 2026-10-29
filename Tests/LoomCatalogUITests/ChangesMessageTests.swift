import Foundation
import LoomCore
import Testing
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// F11: the message a terminal session reads with `inbox`, its 16 KiB bound, and when the footer offers Send.
@MainActor
struct ChangesMessageTests {
    private func comment(_ path: String, _ line: Int?, _ lineText: String, _ text: String,
                         removed: Bool = false) -> ChangeComment {
        ChangeComment(id: UUID(), anchor: ChangeAnchor(fileID: "/w/" + path, line: line, removed: removed, text: lineText),
                      displayPath: path, text: text)
    }

    @Test func eachFileListsItsCommentsWithTheirLineNumberAndTheLinesText() {
        let comments = [
            comment("src/auth/token.py", 44, "    return self._issue(id)", "Why was this dropped?\nIt looked right.", removed: true),
            comment("src/auth/token.py", 49, "    expires = now() + days(30)", "Use REFRESH_TTL."),
            comment("tests/test_rotation.py", 7, "def test_reuse():", "Name it for the 401."),
            comment("notebook.ipynb", nil, "x = 1", "Should this be a function?"),
        ]
        let text = ChangesMessage.terminalText(scopeName: "Branch vs main", comments: comments,
                                               oldestFirst: comments.reversed().map(\.id))
        #expect(text == """
        Comments on the changes (Branch vs main):

        src/auth/token.py
          line 44 (removed): >     return self._issue(id)
          Why was this dropped?
          It looked right.

          line 49: >     expires = now() + days(30)
          Use REFRESH_TTL.

        tests/test_rotation.py
          line 7: > def test_reuse():
          Name it for the 401.

        notebook.ipynb
          > x = 1
          Should this be a function?
        """)
    }

    @Test func aMessageOverTheBoundLeavesOutTheOldestCommentsAndSaysHowMany() {
        let body = String(repeating: "word ", count: 200)
        // Reading order is by file; the age order is the order they were written, newest last.
        let comments = (0..<40).map { comment("src/f\($0 % 4).swift", $0, "let v = \($0)", "#\($0) " + body) }
        let oldestFirst = comments.map(\.id)
        let text = ChangesMessage.terminalText(scopeName: "Last turn", comments: comments.sorted { $0.displayPath < $1.displayPath },
                                               oldestFirst: oldestFirst)
        #expect(text.utf8.count <= SessionTaskLimits.payloadBytes)
        #expect(text.utf8.count > SessionTaskLimits.payloadBytes - 1_200, "as many comments as fit stay")
        let kept = (0..<40).filter { text.contains("#\($0) word") }
        let left = 40 - kept.count
        #expect(left > 0 && kept == Array((40 - kept.count)..<40), "the newest stay, the oldest go: kept \(kept)")
        #expect(text.hasSuffix("(\(left) older comments were left out: a message holds at most 16 KiB.)"))
        #expect(ChangesMessage.terminalText(scopeName: "Last turn", comments: Array(comments.prefix(2)),
                                            oldestFirst: oldestFirst).contains("left out") == false)
    }

    @Test func aSingleCommentLongerThanTheBoundIsCutToFit() {
        let long = comment("a.swift", 1, "let a = 1", String(repeating: "é", count: 20_000))
        let text = ChangesMessage.terminalText(scopeName: "Last turn", comments: [long], oldestFirst: [long.id])
        #expect(text.utf8.count <= SessionTaskLimits.payloadBytes)
        #expect(text.hasPrefix("Comments on the changes (Last turn):\n\na.swift\n  line 1: > let a = 1\n  éé"))
        #expect(text.hasSuffix("…"))
        #expect(!text.utf8.contains(0), "the mailbox takes it")
    }

    @Test func sendIsAbsentWithoutCommentsAndForAStoppedSessionAndNamesTheHarnessOfALiveRun() async throws {
        let rig = try await InspectorRig.make()
        defer { rig.cleanup() }
        let model = rig.model, id = rig.ids[0]
        rig.intents.terminals[id] = nil // the rig's attached terminal would read as a run
        model.select(id)
        let session = model.changes.session(for: id)
        #expect(model.changesSendTitle(for: id) == nil, "no comments, no button")
        session.saveComment("Name this better.", at: ChangeAnchor(fileID: "/w/a.swift", line: 3, removed: false, text: "x"),
                            displayPath: "a.swift", in: .lastTurn)

        // Stopped: no run, so nothing takes the comments, whatever an older answer said.
        session.messageRun = UUID()
        #expect(model.changesSendAvailability(for: id) == .unavailable)
        #expect(model.changesSendTitle(for: id) == nil, "a stopped session has no Send")
        #expect(model.changesSendNote(for: id) == "Comments are sent while the session runs")

        let run = UUID()
        await rig.hub.publish(sessionID: id, change: .runStarted(run))
        await rig.hub.publish(sessionID: id, change: .runEndpoint(run, .terminal))
        #expect(await inspectorWaitUntil { model.rowModels[id]?.live?.runEndpoint == .terminal }, "the model sees the terminal run")
        #expect(model.changesSendTitle(for: id) == nil, "a run the runtime has not confirmed has no Send")
        #expect(model.changesSendNote(for: id) == nil)
        session.messageRun = run
        #expect(model.changesSendAvailability(for: id) == .terminal)
        #expect(model.changesSendTitle(for: id) == "Send to Claude")

        session.sendStatus = .sent(UUID(), title: "Session 0")
        #expect(session.sendStatus.holdsSend && session.sendStatus.line == "Sent · waiting for Session 0 to be ready")
        session.sendStatus = .delivered
        #expect(!session.sendStatus.holdsSend && session.sendStatus.line == "Delivered")

        await rig.hub.publish(sessionID: id, change: .runEnded(run, .processExited))
        #expect(await inspectorWaitUntil { model.rowModels[id]?.live?.runID == nil }, "the model sees the run end")
        #expect(model.changesSendTitle(for: id) == nil, "the button goes with the run")
    }
}
