import Foundation
import Testing
@testable import LoomCatalogUI

/// I6b: the Changes tab's empty and waiting states (DESIGN §13 "Empty and waiting"): one sentence per empty scope, the quiet line
/// above it, and the branch's read with its command and time.
@Suite struct InkChangesEmptyTests {
    private func data(base: String? = "main", onBase: Bool = false) -> ChangesScopeData {
        ChangesScopeData(files: [], baseName: base, onBase: onBase)
    }

    @Test func anEmptyScopeSaysSoInOneSentence() {
        #expect(ChangesBodyWords.emptyText(scope: .lastTurn, data: data()) == "Claude has not edited files in the last turn.")
        #expect(ChangesBodyWords.emptyText(scope: .wholeSession, data: data()) == "Claude has not edited files in this session.")
        #expect(ChangesBodyWords.emptyText(scope: .branch, data: data(base: "develop")) == "No changes against develop.")
        #expect(ChangesBodyWords.emptyText(scope: .branch, data: data(base: "main", onBase: true)) == "No uncommitted changes.")
    }

    @Test func theQuietLineAboveSaysWhatWasRead() {
        let edits = "Claude's file edits. Shell commands and subagents show under Branch."
        #expect(ChangesBodyWords.note(scope: .lastTurn, state: .ready(data())) == edits)
        #expect(ChangesBodyWords.note(scope: .wholeSession, state: .ready(data())) == edits)
        let truncated = ChangesScopeData(files: [], truncated: true)
        #expect(ChangesBodyWords.note(scope: .lastTurn, state: .ready(truncated)) == edits + " Older edits were not read.")
        #expect(ChangesBodyWords.note(scope: .branch, state: .ready(data(base: "develop"))) == "Your working tree against develop.")
        #expect(ChangesBodyWords.note(scope: .branch, state: .ready(data(onBase: true)))
                == "You are on main. Showing the uncommitted changes.")
        // A scope that is off says only its reason.
        #expect(ChangesBodyWords.note(scope: .lastTurn, state: .off("Claude's file edits are read from Claude sessions")) == nil)
    }

    @Test func whileGitReadsTheBranchSaysWhatItRunsAndForHowLong() {
        #expect(ChangesBodyWords.readingBranch == "Reading the branch…")
        #expect(ChangesBodyWords.readingLine(elapsed: 0) == "git diff --numstat -M · 1 s")
        #expect(ChangesBodyWords.readingLine(elapsed: 0.9) == "git diff --numstat -M · 1 s")
        #expect(ChangesBodyWords.readingLine(elapsed: 2.4) == "git diff --numstat -M · 3 s")
        #expect(ChangesBodyWords.readingLine(elapsed: -1) == "git diff --numstat -M · 1 s", "a clock that steps back reads 1 s")
    }
}
