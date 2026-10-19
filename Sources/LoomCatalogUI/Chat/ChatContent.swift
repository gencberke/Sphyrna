import Foundation
import SwiftUI

/// Inline markdown to attributed text, and the caches around parsing: a block list per finished message (keyed by the
/// row id and the text, so a streaming block is parsed again, a settled one never), and the inline text of each block.
@MainActor
enum ChatContent {
    // MARK: Inline

    /// Inline markdown (emphasis, code, links) as attributed text. Links open only when they are web or mail links.
    static func inline(_ source: String) -> AttributedString {
        let key = source as NSString
        if let cached = inlineCache.object(forKey: key) { return cached.value }
        ChatRenderProbe.inlineParsed()
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        var result = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        var codeRanges: [Range<AttributedString.Index>] = []
        var linkRanges: [Range<AttributedString.Index>] = []
        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.code) == true { codeRanges.append(run.range) }
            if run.link != nil { linkRanges.append(run.range) }
        }
        for range in codeRanges {
            result[range].font = LoomTheme.Chat.readingMono
            result[range].backgroundColor = LoomTheme.Chat.inlineCodeFill
            result[range].foregroundColor = LoomTheme.Chat.inlineCode
        }
        for range in linkRanges {
            result[range].foregroundColor = LoomTheme.Accent.high
        }
        inlineCache.setObject(Box(result), forKey: key, cost: source.utf8.count * 8)
        return result
    }

    private final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let inlineCache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 4_000
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    /// Only web and mail links are followed (a transcript is not a trusted source of `file:` or app URLs).
    static func isFollowable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "mailto"
    }

    // MARK: Blocks

    private final class Blocks {
        let value: [MarkdownBlock]
        init(_ value: [MarkdownBlock]) { self.value = value }
    }

    private static let blockCache: NSCache<NSString, Blocks> = {
        let cache = NSCache<NSString, Blocks>()
        cache.countLimit = 600
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    /// The parsed blocks of a message. While it streams, everything up to the last blank line outside a fence is parsed
    /// once and kept, and only the tail is parsed again.
    static func blocks(id: String, text: String, isStreaming: Bool) -> [MarkdownBlock] {
        if !isStreaming {
            let key = "\(id)#\(text.hashValue)#\(text.utf8.count)" as NSString
            if let cached = blockCache.object(forKey: key) { return cached.value }
            let parsed = parse(text)
            blockCache.setObject(Blocks(parsed), forKey: key, cost: text.utf8.count * 4)
            return parsed
        }
        let split = stableSplit(text)
        let head = String(text[..<split])
        let tail = String(text[split...])
        var blocks: [MarkdownBlock] = []
        if !head.isEmpty {
            let key = "\(id)#head#\(head.hashValue)#\(head.utf8.count)" as NSString
            if let cached = blockCache.object(forKey: key) {
                blocks = cached.value
            } else {
                blocks = parse(head)
                blockCache.setObject(Blocks(blocks), forKey: key, cost: head.utf8.count * 4)
            }
        }
        return blocks + parse(tail)
    }

    private static func parse(_ text: String) -> [MarkdownBlock] {
        ChatRenderProbe.markdownParsed(characters: text.utf8.count)
        return ChatMarkdown.parse(text)
    }

    /// The index after the last paragraph break that is outside a code fence: everything before it is complete.
    static func stableSplit(_ text: String) -> String.Index {
        var inFence = false
        var lastBreak = text.startIndex
        var lineStart = text.startIndex
        var previousBlank = false
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            let trimmed = line.drop(while: { $0 == " " })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            let blank = trimmed.isEmpty
            if blank, !previousBlank, !inFence, lineEnd < text.endIndex { lastBreak = text.index(after: lineEnd) }
            previousBlank = blank
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        return lastBreak
    }
}
