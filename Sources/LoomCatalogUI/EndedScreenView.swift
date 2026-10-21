import AppKit
import LoomTerminal
import SwiftUI

/// The last screen of an ended run, drawn from its snapshot (FB4-3): the terminal's font, size and background,
/// the styled runs, text that can be selected and copied, and a vertical scroll when it is taller than the
/// area. No terminal engine, timer or display link: a text view that draws when it is shown.
struct EndedScreenView: NSViewRepresentable {
    let snapshot: TerminalScreenSnapshot
    let fontSize: Double

    func makeNSView(context: Context) -> EndedScreenContainerView {
        let view = EndedScreenContainerView()
        view.show(snapshot, fontSize: fontSize)
        return view
    }

    func updateNSView(_ view: EndedScreenContainerView, context: Context) {
        // The kept screen is dark in both appearances; a change of the main pane's tone repaints its background
        // (reading the tone here subscribes this update to it).
        _ = LoomTheme.ThemeState.shared.tone
        view.applyTheme()
        view.show(snapshot, fontSize: fontSize)
    }
}

@MainActor
final class EndedScreenContainerView: NSView {
    let textView = NSTextView()
    private let scrollView = NSScrollView()
    private var shown: (snapshot: TerminalScreenSnapshot, fontSize: Double, scale: CGFloat)?
    /// Set by `show` until the area has a size: the screen then opens at its bottom row, first column.
    private var opensAtBottom = false

    /// The terminal face is dark whatever the window's appearance is, scrollers included.
    func applyTheme() {
        scrollView.backgroundColor = TerminalTheme.background
        textView.backgroundColor = TerminalTheme.background
    }

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = TerminalTheme.background
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Rows never wrap: a screen wider than the area scrolls sideways, like the cells it came from.
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = TerminalTheme.background
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Last screen of the session")
        scrollView.documentView = textView

        addSubview(scrollView)
        let inset = LoomTheme.Space.terminalInset
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: LoomTheme.Space.terminalLeadingInset),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Draws `snapshot` unless it is already what is shown at this size and scale.
    func show(_ snapshot: TerminalScreenSnapshot, fontSize: Double) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if let shown, shown.snapshot.captureID == snapshot.captureID, shown.fontSize == fontSize, shown.scale == scale {
            return
        }
        shown = (snapshot, fontSize, scale)
        textView.textStorage?.setAttributedString(Self.attributedString(for: snapshot, fontSize: fontSize, scale: scale))
        opensAtBottom = true
        openAtBottomIfLaidOut()
    }

    override func layout() {
        super.layout()
        openAtBottomIfLaidOut()
    }

    /// A move to a screen of another scale changes the terminal's cell width, so the rows are laid out again.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let shown { show(shown.snapshot, fontSize: shown.fontSize) }
    }

    /// What happened last is at the bottom, so a screen taller than the area opens there; and at the rows'
    /// first column, so a row wider than the area never hides the start of every row.
    private func openAtBottomIfLaidOut() {
        let clip = scrollView.contentView
        guard opensAtBottom, clip.bounds.height > 0, let container = textView.textContainer else { return }
        opensAtBottom = false
        textView.layoutManager?.ensureLayout(for: container)
        clip.scroll(to: NSPoint(x: 0, y: max(0, textView.frame.height - clip.bounds.height)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The runs as attributed text: one line per row, the terminal's font, each run's colours and decorations,
    /// and every character one terminal cell wide. The engine snaps the font's advance to the pixel grid
    /// (`TerminalView.computeFontDimensions`), so at the font's own advance a full row would come out wider
    /// than the terminal it was taken from.
    static func attributedString(for snapshot: TerminalScreenSnapshot, fontSize: Double,
                                 scale: CGFloat = 2) -> NSAttributedString {
        let regular = TerminalSurface.font(size: fontSize)
        let advance = regular.advancement(forGlyph: regular.glyph(withName: "W")).width
        let kern = max(1, (advance * scale).rounded() / scale) - advance
        let manager = NSFontManager.shared
        let bold = manager.convert(regular, toHaveTrait: .boldFontMask)
        let italic = manager.convert(regular, toHaveTrait: .italicFontMask)
        let boldItalic = manager.convert(bold, toHaveTrait: .italicFontMask)
        func font(for style: TerminalScreenSnapshot.Style) -> NSFont {
            switch (style.contains(.bold), style.contains(.italic)) {
            case (true, true): boldItalic
            case (true, false): bold
            case (false, true): italic
            case (false, false): regular
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let newline = NSAttributedString(string: "\n", attributes: [.font: regular, .paragraphStyle: paragraph, .kern: kern])
        let result = NSMutableAttributedString()
        for (index, line) in snapshot.lines.enumerated() {
            if index > 0 { result.append(newline) }
            for run in line {
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font(for: run.style),
                    .foregroundColor: run.foreground.nsColor,
                    .paragraphStyle: paragraph,
                    .kern: kern,
                ]
                if let background = run.background { attributes[.backgroundColor] = background.nsColor }
                if run.style.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if run.style.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        return result
    }
}
