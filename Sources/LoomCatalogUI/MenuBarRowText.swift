import AppKit

/// The text of a session row in the menu bar menu: the title, and the project at the right edge in
/// secondary text, joined by a tab stop. The project keeps up to 112 pt; a long title is cut at its end
/// (a menu does not truncate attributed text itself).
public enum MenuBarRowText {
    static var titleFont: NSFont { .systemFont(ofSize: LoomTheme.MenuBar.titleFontSize) }
    static var projectFont: NSFont { .systemFont(ofSize: LoomTheme.MenuBar.projectFontSize) }

    /// The two pieces as printed: each cut with an ellipsis to the room it has.
    static func fit(title: String, project: String?) -> (title: String, project: String?) {
        let theme = LoomTheme.MenuBar.self
        let flatTitle = single(title)
        guard let project, !project.isEmpty else {
            return (cut(flatTitle, font: titleFont, width: theme.rowTextWidth), nil)
        }
        let shownProject = cut(single(project), font: projectFont, width: theme.projectMaxWidth)
        let room = theme.rowTextWidth - theme.titleProjectGap - width(shownProject, font: projectFont)
        return (cut(flatTitle, font: titleFont, width: room), shownProject)
    }

    public static func attributed(title: String, project: String?) -> NSAttributedString {
        let theme = LoomTheme.MenuBar.self
        let shown = fit(title: title, project: project)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: theme.rowTextWidth)]
        style.lineBreakMode = .byClipping
        let text = NSMutableAttributedString(
            string: shown.title,
            attributes: [.font: titleFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        if let project = shown.project {
            text.append(NSAttributedString(
                string: "\t" + project,
                attributes: [.font: projectFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]))
        }
        return text
    }

    private static func single(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }

    private static func width(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// The longest start of `text` that fits `width` with an ellipsis after it; the whole text when it fits.
    static func cut(_ text: String, font: NSFont, width limit: CGFloat) -> String {
        guard Self.width(text, font: font) > limit else { return text }
        let characters = Array(text)
        var low = 0, high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            let candidate = String(characters[..<middle]).trimmingCharacters(in: .whitespaces) + "…"
            if Self.width(candidate, font: font) <= limit { low = middle } else { high = middle - 1 }
        }
        return String(characters[..<low]).trimmingCharacters(in: .whitespaces) + "…"
    }
}
