import Foundation
import SwiftUI

/// Command output with basic ANSI colour (CHAT-SPEC → Not taken from T3 Code: no terminal model, just the colours of
/// the 16 standard colours, bold and reset). Everything else in an escape sequence is dropped, so a progress bar's
/// cursor moves do not show as garbage.
enum ChatANSI {
    static func containsEscape(_ text: String) -> Bool { text.contains("\u{1B}") }

    /// The text without escape sequences.
    static func stripped(_ text: String) -> String {
        guard containsEscape(text) else { return text }
        return text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
    }

    /// The text with colours, or plain when it has none.
    @MainActor
    static func attributed(_ text: String) -> AttributedString {
        guard containsEscape(text) else { return AttributedString(text) }
        var result = AttributedString()
        var color: Color?
        var bold = false
        var segment = ""
        func flush() {
            guard !segment.isEmpty else { return }
            var piece = AttributedString(segment)
            if let color { piece.foregroundColor = color }
            if bold { piece.inlinePresentationIntent = .stronglyEmphasized }
            result.append(piece)
            segment = ""
        }
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            if scalars[i] == "\u{1B}", i + 1 < scalars.count, scalars[i + 1] == "[" {
                var j = i + 2
                var parameters = ""
                while j < scalars.count, j - i < 64, !(scalars[j].value >= 0x40 && scalars[j].value <= 0x7E) {
                    parameters.unicodeScalars.append(scalars[j])
                    j += 1
                }
                // An escape that never ends (cut off, or not a sequence at all) loses only its two introducing characters.
                guard j < scalars.count, scalars[j].value >= 0x40, scalars[j].value <= 0x7E else {
                    i += 2
                    continue
                }
                if scalars[j] == "m" {
                    flush()
                    for code in parameters.split(separator: ";", omittingEmptySubsequences: false).map({ Int($0) ?? 0 }) {
                        switch code {
                        case 0: color = nil; bold = false
                        case 1: bold = true
                        case 22: bold = false
                        case 39: color = nil
                        case 30...37: color = Self.standard[code - 30]
                        case 90...97: color = Self.bright[code - 90]
                        default: break
                        }
                    }
                }
                i = j + 1
                continue
            }
            if scalars[i] == "\u{1B}" { i += 1; continue }
            segment.unicodeScalars.append(scalars[i])
            i += 1
        }
        flush()
        return result
    }

    private static let standard = LoomTheme.Chat.ansiStandard
    private static let bright = LoomTheme.Chat.ansiBright
}
