import Darwin
import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport
@testable import LoomChatTestRigs

// Pinned cards, driver side (V18): what each answer sends the CLI and what it leaves in the stream (pure), and the rules a
// card lives by on the fake provider: the driver never answers, a card retires only on its own id or `tool_use_id`, a CLI
// cancel or the process ending (never on a `result`), and Stop interrupts first.

private extension PermissionDecision {
    var fields: [String: JSONValue] { payload.object ?? [:] }
}

struct ChatRequestAnswerTests {
    @Test func theHubSummaryNamesWhatTheRequestIsAbout() {
        let approval = ChatRequestCardsShared.pending("Bash", ChatRequestCardsShared.bashInput).summary
        #expect(approval.kind == .approval)
        #expect(approval.toolName == "Bash")
        #expect(approval.summary == "rm -rf build")
        #expect(approval.note == nil)
        let question = ChatRequestCardsShared.pending("AskUserQuestion", ["questions": [["question": "Which database?", "header": "Database",
                                                                    "options": [["label": "SQLite"]]]]]).summary
        #expect(question.kind == .question)
        #expect(question.summary == "Database")
        #expect(ChatRequestCardsShared.pending("ExitPlanMode", ["plan": "x"]).summary.kind == .plan)
    }
}
