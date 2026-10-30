import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI

/// D-121's words in Settings → Sessions: the cleanup's Delete names the harness whose files go, and a row that did not finish
/// says why in words. Claude's words are pinned elsewhere and stay as they are.
struct CodexDeletionCopyTests {
    private func row(_ title: String, _ provider: ManagedSession.Provider) -> DeleteSheetText.Row {
        DeleteSheetText.Row(title: title, fileCount: 1, byteCount: 2_048, provider: provider)
    }

    @Test func theCleanupDeleteNamesCodexForCodexSessions() {
        let codex = DeleteSheetText.make(rows: [row("A Codex session", .codex)], folder: "~/.claude")
        #expect(codex.lead == "Sphyrna removes it from Sphyrna, and deletes Codex's local files for it. This can't be undone.")
        #expect(!codex.removed.joined().contains("transcript") && !codex.kept.joined().contains("Claude"))
        // The folder named is Claude's profile: it is not where Codex's files are.
        #expect(codex.totals == "1 file · \(DeleteSheetText.size(2_048))")

        let mixed = DeleteSheetText.make(rows: [row("Claude's", .claude), row("Codex's", .codex)], folder: "~/.claude")
        #expect(mixed.lead == "Sphyrna removes them from Sphyrna, and deletes Claude's and Codex's local files for them. This can't be undone.")
        #expect(mixed.removed.contains { $0.contains("Codex") } && mixed.removed.contains { $0.contains("transcript") })
        #expect(mixed.kept.contains { $0.contains("Anthropic") } && mixed.kept.contains { $0.contains("OpenAI") })
    }

    @Test func aCleanupRowThatDidNotFinishSaysWhyInWords() {
        let text = CleanupText.result(.incomplete("native_descendants"))
        #expect(text.hasPrefix("Not finished: ") && !text.contains("_"), "\(text)")
    }
}
