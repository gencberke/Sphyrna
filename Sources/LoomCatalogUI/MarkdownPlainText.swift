import Foundation

/// The words of a Markdown text without its syntax, for the one-line places that quote a message (the
/// palette's session-text hits): emphasis marks, heading and list markers, quote marks, code fences, table
/// rules and link targets are dropped, and what they marked stays. Line breaks stay; the caller folds them.
/// Not a parser: a pass of line and inline patterns, good enough for a snippet and never throwing.
enum MarkdownPlainText {
    static func stripped(_ markdown: String) -> String {
        var lines: [String] = []
        for var line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.range(of: #"^\s*(```|~~~)"#, options: .regularExpression) != nil { continue }
            if line.range(of: #"^\s*([-*_]\s*){3,}$"#, options: .regularExpression) != nil { continue }
            if line.contains("|"), line.contains("-"),
               line.range(of: #"^\s*\|?[\s:|-]+\|?\s*$"#, options: .regularExpression) != nil { continue }
            line = line.replacingOccurrences(of: #"^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*>+\s?"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*([-*+]|\d{1,9}[.)])\s+(\[[ xX]\]\s+)?"#, with: "",
                                             options: .regularExpression)
            lines.append(line)
        }
        var text = lines.joined(separator: "\n")
        let inline: [(pattern: String, template: String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),                    // image: its alt text
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),                     // link: its text
            (#"`+([^`\n]*)`+"#, "$1"),                              // inline code
            (#"(\*\*|__|~~)(?=\S)(.+?)(?<=\S)\1"#, "$2"),           // bold and strike-through
            (#"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])"#, "$1"),  // italic with stars
            (#"(?<!\w)_(?=\S)([^_\n]+?)(?<=\S)_(?!\w)"#, "$1"),     // italic with underscores (not snake_case)
            (#"\s\|\s"#, "  "),                                     // table cells
        ]
        for (pattern, template) in inline {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text
    }
}
