import AppKit
import Foundation
import Testing
import LoomChat
import SwiftUI
@testable import LoomCatalogUI
import LoomTestSupport

/// What both halves of `ChatStreamFenceTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum ChatStreamFenceShared {
    /// The chunk size the texts below are written for (`ChatContent.fenceChunkLines`).
    @MainActor
    static let chunk = 40

    @MainActor
    static func codeLines(_ count: Int, from first: Int = 1) -> String {
        (first..<(first + count)).map { "let value\($0) = compute(\($0), limit: 64) // the line \($0) of the block" }
            .joined(separator: "\n")
    }

    /// The head and the tail of a fresh split, parsed whole.
    @MainActor
    static func reference(_ text: String) -> (head: [MarkdownBlock], tail: [MarkdownBlock]) {
        let split = ChatContent.stableSplit(text)
        let head = String(text[..<split]), tail = String(text[split...])
        return (head.isEmpty ? [] : ChatMarkdown.parse(head), tail.isEmpty ? [] : ChatMarkdown.parse(tail))
    }

    /// Streams `text` into one split, cut by cut, and checks every cut against a fresh split parsed whole: the head is the
    /// parse of the settled text and the tail, with an open fence's block after it, the parse of the rest. Returns how many
    /// cuts had an open fence in chunks.
    @MainActor
    @discardableResult
    static func expectWholeParse(_ text: String, id: String, step: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) -> Int {
        let characters = Array(text)
        var cuts = Set(stride(from: 0, through: characters.count, by: step))
        cuts.insert(characters.count)
        for (index, character) in characters.enumerated() where character == "\n" {
            cuts.insert(index + 1)
            cuts.insert(min(characters.count, index + 2))
        }
        var chunked = 0
        for cut in cuts.sorted() {
            let prefix = String(characters.prefix(cut))
            let parts = ChatContent.streamingBlocks(id: id, text: prefix)
            let expected = reference(prefix)
            let tail = parts.tail + (parts.fence.map { [$0.block] } ?? [])
            if parts.fence != nil { chunked += 1 }
            #expect(parts.head == expected.head, "\(id) cut \(cut): the head is not the parse of the settled text", sourceLocation: sourceLocation)
            #expect(tail == expected.tail, "\(id) cut \(cut): the tail is not the parse of the rest", sourceLocation: sourceLocation)
            let open = expected.head.contains { if case .code(_, _, false) = $0 { true } else { false } }
            #expect(parts.isComposable == !open, "\(id) cut \(cut): composable", sourceLocation: sourceLocation)
        }
        return chunked
    }

    /// Draws `view` in an off-screen window until its bodies have run.
    @MainActor
    static func draw(_ view: some View, width: CGFloat = 800) async {
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
}
