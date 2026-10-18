import Foundation
import Observation

/// What the user row does with a message's text. A pasted chip of up to 16 MB becomes the row's text (D-58), so nothing here
/// reads more of it than the row shows: the length test is bounded and the collapsed row takes a prefix.
enum ChatUserText {
    /// More bytes than this are long whatever they hold: a Character is at most a few bytes in practice, so such a text is
    /// well over `Chat.userCollapseCharacters` of them (a run of emoji sequences is the exception, and collapsing it is harmless).
    static let longBytes = 4 * LoomTheme.Chat.userCollapseCharacters

    /// The collapsed row shows `Chat.userCollapsedLines` lines of at most about 80 characters, so this many characters hold every
    /// line it can show with room to spare.
    static let collapsedCharacters = 2 * LoomTheme.Chat.userCollapseCharacters

    /// A development probe: how often the row of one watched entry evaluated its message (`bubble`, where `isLong` runs) and its
    /// footer. Other rows alive in the same process are not counted. A hover must move the second and not the first.
    nonisolated(unsafe) static var watchedID: String?
    nonisolated(unsafe) private(set) static var bubbleBodies = 0
    nonisolated(unsafe) private(set) static var footerBodies = 0

    /// More than 600 characters, or more than 8 lines. The UTF-8 length is O(1), an early exit ends a long text at once, and
    /// the scans that remain run over at most `longBytes` bytes.
    static func isLong(_ text: String) -> Bool {
        let utf8 = text.utf8
        if utf8.count > longBytes { return true }
        var newlines = 0
        for byte in utf8 where byte == 0x0A {
            newlines += 1
            if newlines + 1 > LoomTheme.Chat.userCollapseLines { return true }
        }
        return utf8.count > LoomTheme.Chat.userCollapseCharacters && text.count > LoomTheme.Chat.userCollapseCharacters
    }

    /// What a collapsed row draws: the start of the text, cut at `collapsedCharacters`. A short text is returned as it is.
    static func collapsedPrefix(_ text: String) -> Substring {
        text.utf8.count <= collapsedCharacters ? text[...] : text.prefix(collapsedCharacters)
    }

    static func bubbleEvaluated(_ id: String) { if watchedID == id { bubbleBodies += 1 } }
    static func footerEvaluated(_ id: String) { if watchedID == id { footerBodies += 1 } }

    static func resetProbe() {
        bubbleBodies = 0
        footerBodies = 0
    }
}

/// A row's hover, held outside the row's views: the pointer entering or leaving redraws only the view that reads `isOver` (the
/// time and Copy of the footer), not the message above it.
@MainActor
@Observable
final class ChatRowHover {
    var isOver = false
}
