import AppKit
import Foundation
import Testing
import SwiftUI
@testable import LoomCatalogUI

/// The open tail of a streaming message is drawn without text selection (every flush draws it again, and selection builds a
/// second text layout of it); the settled head and every finished message keep it. Seen through `ChatSelectionProbe`, which
/// records what each top-level block's body chose when it ran in a hosted view.
@MainActor
@Suite
struct ChatStreamSelectionTests {
    static let head = """
    The first paragraph is settled.

    ## A heading

    | a | b |
    |---|---|
    | 1 | 2 |

    ```swift
    let settled = true
    ```


    """

    /// Draws `view` in an off-screen window, `width` wide, until its bodies have run.
    static func draw(_ view: some View, width: CGFloat = 700) async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        await Task.yield()
        hosting.layoutSubtreeIfNeeded()
    }

    static func key(_ index: Int, _ block: MarkdownBlock) -> String { "\(index)#\(block.hashValue)" }

    @Test(.renderProbe, arguments: ["The open tail is still being", "```swift\nlet open = 1\nlet more"])
    func theStreamingTailHasNoSelectionAndTheSettledBlocksDo(tail: String) async {
        let scope = "selection-\(UUID().uuidString)"
        let context = ChatRowContext(probeScope: scope)
        RenderProbeExclusive.watchChat(scope: scope)
        ChatSelectionProbe.reset()
        defer { ChatRenderProbe.stop(); ChatSelectionProbe.reset() }
        let id = "m-\(UUID().uuidString)"
        let text = Self.head + tail
        let parts = ChatContent.streamingBlocks(id: id, text: text, in: context)
        #expect(parts.isComposable && parts.head.count == 4 && parts.tail.count == 1)
        await Self.draw(ChatStreamingMarkdownView(parts: parts, flags: [], rowID: id, context: context))
        let drawn = ChatSelectionProbe.selectable
        for (index, block) in parts.head.enumerated() {
            #expect(drawn[Self.key(index, block)] == true, "settled block \(index) is selectable")
        }
        #expect(drawn[Self.key(parts.head.count, parts.tail[0])] == false, "the open tail is not selectable")

        // The finished message: every block selectable, the last one included.
        ChatSelectionProbe.reset()
        let finished = ChatContent.blocks(id: id, text: tail.hasPrefix("```") ? text + "\n```" : text, isStreaming: false, in: context)
        await Self.draw(ChatMarkdownView(blocks: finished, flags: [], rowID: id, isStreaming: false, context: context))
        #expect(finished.count == 5)
        for (index, block) in finished.enumerated() {
            #expect(ChatSelectionProbe.selectable[Self.key(index, block)] == true, "finished block \(index) is selectable")
        }
    }
}
