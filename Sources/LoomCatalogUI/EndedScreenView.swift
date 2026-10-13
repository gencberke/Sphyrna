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
        view.show(snapshot, fontSize: fontSize)
    }
}

@MainActor
final class EndedScreenContainerView: NSView {
    let textView = NSTextView()
    private let scrollView = NSScrollView()
    private var shown: (id: UUID, fontSize: Double)?

    init() {
        super.init(frame: .zero)
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
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Draws `snapshot` unless it is already what is shown at this size.
    func show(_ snapshot: TerminalScreenSnapshot, fontSize: Double) {
        guard shown?.id != snapshot.captureID || shown?.fontSize != fontSize else { return }
        shown = (snapshot.captureID, fontSize)
        textView.textStorage?.setAttributedString(Self.attributedString(for: snapshot, fontSize: fontSize))
        // What happened last is at the bottom: a screen taller than the area opens there.
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.scrollToEndOfDocument(nil)
    }

    /// The runs as attributed text: one line per row, the terminal's font, each run's colours and decorations.
    static func attributedString(for snapshot: TerminalScreenSnapshot, fontSize: Double) -> NSAttributedString {
        let regular = TerminalSurface.font(size: fontSize)
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
        let result = NSMutableAttributedString()
        for (index, line) in snapshot.lines.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: [.font: regular, .paragraphStyle: paragraph])) }
            for run in line {
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font(for: run.style),
                    .foregroundColor: run.foreground.nsColor,
                    .paragraphStyle: paragraph,
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
