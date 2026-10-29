import AppKit
import LoomChat
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// The chat stream in Ink (DESIGN §7): the values that changed from Night Fleece 2, pinned as numbers and as measured heights of
/// the real row views (a hosting controller that is never ordered front: nothing appears on screen), and the tree's geometry as a
/// plain value. The stream's cost is the budget suites'.
@MainActor
struct ChatInkStreamTests: ChatInkStreamFixtures {
    private func hostedHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        return ceil(host.sizeThatFits(in: CGSize(width: width, height: 10_000)).height)
    }

    // MARK: Code block

    /// A code block's header is 30 pt, its text 12.5 on 20, padded 10 above, 14 aside and 12 below; a hairline under the header.
    @Test func aCodeBlockIsAThirtyPointHeaderAndLinesOfTwenty() {
        #expect(Chat.codeHeaderHeight == 30 && Chat.bodyLineHeight == 20 && Chat.codeRadius == 8)
        #expect(Chat.codePaddingTop == 10 && Chat.codePaddingH == 14 && Chat.codePaddingBottom == 12)
        let one = hostedHeight(ChatCodeBlockView(language: "swift", code: "let a = 1", isStreaming: false, wrapped: false,
                                                 context: ChatRowContext()) {}, width: 600)
        let two = hostedHeight(ChatCodeBlockView(language: "swift", code: "let a = 1\nlet b = 2", isStreaming: false, wrapped: false,
                                                 context: ChatRowContext()) {}, width: 600)
        #expect(abs(one - (30 + 1 + 10 + 20 + 12)) <= 2, "\(one)")
        #expect(abs((two - one) - 20) <= 1, "a line is 20 pt: \(two - one)")
    }

    // MARK: Copy

    /// The optical values that stay off the 4 pt grid, and are not in `HighlightTests`' list: the bubble's 9 × 14, the code
    /// block's 10 / 14, the tree's offsets and the diff's gutter.
    @Test func theOffGridTokensKeepTheirReferenceValues() {
        let optical: [(String, CGFloat, CGFloat)] = [
            ("Chat.userPaddingV", Chat.userPaddingV, 9), ("Chat.userPaddingH", Chat.userPaddingH, 14),
            ("Chat.codePaddingTop", Chat.codePaddingTop, 10), ("Chat.codePaddingH", Chat.codePaddingH, 14),
            ("Chat.outputPaddingBottom", Chat.outputPaddingBottom, 10), ("Chat.bodyTop", Chat.bodyTop, 3),
            ("Chat.Tree.groupLine", Chat.Tree.groupLine, 8), ("Chat.Tree.curveRadius", Chat.Tree.curveRadius, 6),
            ("Chat.Tree.arm", Chat.Tree.arm, 7), ("Chat.Tree.overhang", Chat.Tree.overhang, 7),
            ("Chat.Tree.foldGuide", Chat.Tree.foldGuide, 7), ("Chat.Tree.foldIndent", Chat.Tree.foldIndent, 22),
            ("Chat.thoughtInset", Chat.thoughtInset, 21), ("Chat.diffGutter", Chat.diffGutter, 22),
            ("Chat.changesFileHeight", Chat.changesFileHeight, 29),
        ]
        for (name, value, expected) in optical { #expect(value == expected, "\(name) is \(value)") }
    }
}
