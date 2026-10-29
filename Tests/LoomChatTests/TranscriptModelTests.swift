import Foundation
import LoomCore
import Testing
@testable import LoomChat
@testable import LoomChatTestRigs

/// The same model fed from transcript lines: a turn ends at the next human prompt, rows keep the ids the live stream
/// gives them, and records Claude writes for other purposes are not mistaken for prompts.
@Suite(.timeLimit(.minutes(1)))
struct TranscriptModelTests: TranscriptModelFixtures {
    @Test func theRecordsExitLeavesAreNotShownAndNeitherAreTheQuietRecordTypes() {
        let model = build([Fixture.transcriptUser("hello", uuid: "p1")] + S2Transcript.exitRecords + S2Transcript.quietRecords)
        // Not the caveat, not "/exit" as a prompt that opens a turn, not the farewell; nothing raw either.
        #expect(model.prompts.map(\.text) == ["hello"] && model.turns.count == 1)
        #expect(model.markers.isEmpty && model.raws.isEmpty && model.entries.count == 1)
        // Hand-written stand-ins for the types whose real lines are too big to keep.
        let rest = build([Fixture.transcriptUser("hello", uuid: "p1")] + ["api-request", "api-request-blob", "api-request-shape", "file-history-delta", "continued-in"].map {
            Fixture.line(["type": .string($0), "sessionId": "s1"])
        })
        #expect(rest.entries.count == 1 && rest.raws.isEmpty)
        // Each farewell /exit prints is quiet; other command output is not.
        for farewell in ["Catch you later!", "See ya!", "Bye!", "Goodbye!"] {
            #expect(TurnModel.promptKind(of: userMessage("<local-command-stdout>\(farewell)</local-command-stdout>")) == .silent)
        }
        #expect(TurnModel.promptKind(of: userMessage("<local-command-stdout>Set model to Haiku</local-command-stdout>")) == .notice("Set model to Haiku"))
        #expect(TurnModel.promptKind(of: userMessage("<command-name>/model</command-name>\n   <command-message>model</command-message>"))
            == .prompt(text: "/model", command: UserPrompt.Command(name: "/model", arguments: "")))
    }

    private func userMessage(_ text: String) -> UserMessage {
        guard case let .user(message) = Fixture.message(Fixture.transcriptUser(text, uuid: "x")) else { fatalError("not a user record") }
        return message
    }
}
