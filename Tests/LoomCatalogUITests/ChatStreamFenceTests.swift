import AppKit
import Foundation
import Testing
import LoomChat
import SwiftUI
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

extension ChatHosted {
    /// The streaming head parses only what settled (each piece once, a list's piece again with what follows it), and a long
    /// code fence open at the end settles in chunks of `ChatContent.fenceChunkLines` lines: drawn as one block, measured from
    /// its kept chunks, and the same blocks as a whole parse.
    @MainActor
    @Suite
    struct ChatStreamFenceTests {
        // MARK: A long fence settles in chunks

        @Test(.renderProbe) func theOpenFenceIsDrawnAsOneBlockWithNoCopyUntilItCloses() async {
            let scope = "fence-draw-\(UUID().uuidString)"
            let context = ChatRowContext(probeScope: scope)
            RenderProbeExclusive.watchChat(scope: scope)
            ChatSelectionProbe.reset()
            defer { ChatRenderProbe.stop(); ChatSelectionProbe.reset() }
            let id = "fence-draw-\(UUID().uuidString)"
            let open = "Intro.\n\n```swift\n" + ChatStreamFenceShared.codeLines(2 * ChatStreamFenceShared.chunk + 10)
            let parts = ChatContent.streamingBlocks(id: id, text: open, in: context)
            await ChatStreamFenceShared.draw(ChatStreamingMarkdownView(parts: parts, flags: [], rowID: id, context: context))
            // One card for the whole fence: its chunks and the open lines in it, no other code block, and no Copy yet.
            #expect(ChatSelectionProbe.codeBlocks == [1: ChatSelectionProbe.CodeBlock(chunks: 2, offersCopy: false)])
            ChatSelectionProbe.reset()
            let finished = ChatContent.blocks(id: id, text: open + "\n```", isStreaming: false, in: context)
            await ChatStreamFenceShared.draw(ChatMarkdownView(blocks: finished, flags: [], rowID: id, isStreaming: false, context: context))
            #expect(ChatSelectionProbe.codeBlocks == [1: ChatSelectionProbe.CodeBlock(chunks: 0, offersCopy: true)], "closed: whole, with Copy")
        }
    }
}
