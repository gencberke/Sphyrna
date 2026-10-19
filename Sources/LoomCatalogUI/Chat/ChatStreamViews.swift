import AppKit
import SwiftUI

/// The table of the stream. It takes keys itself (arrows, Page Up/Down, Home/End scroll through the latch; ⌃O cycles the
/// view) instead of moving a row selection nobody draws.
@MainActor
final class ChatTableView: NSTableView {
    weak var controller: ChatStreamController?

    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }

    /// Rows reloaded through the table since it was made (the budget tests): a row that is on screen is updated in place.
    private(set) var rowReloads = 0

    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
        rowReloads += 1
        super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
    }

    /// The text a key press types, when it is printable: no control character, no function or arrow key (those carry
    /// private-use characters), not a space (Space scrolls a table) and nothing while an input method composes.
    static func printableText(of event: NSEvent) -> String? {
        guard let characters = event.characters, !characters.isEmpty else { return nil }
        return printable(characters)
    }

    static func printable(_ characters: String) -> String? {
        guard !characters.isEmpty, characters != " ", characters.unicodeScalars.allSatisfy({ scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
        }) else { return nil }
        return characters
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .control, event.charactersIgnoringModifiers?.lowercased() == "o" {
            controller?.onCycleView?()
            return
        }
        // Type to focus [T3]: a printable key typed in the stream goes to the composer, as the event (Option and Shift
        // make characters on other layouts: `@`, `[`, `{`, `|`; ⌘ and ⌃ make shortcuts).
        if flags.intersection([.command, .control]).isEmpty, Self.printableText(of: event) != nil,
           let take = controller?.onTypeToFocus {
            take(event)
            return
        }
        guard flags.isEmpty else { return super.keyDown(with: event) }
        let key: ChatScrollLatch.Key? = switch event.keyCode {
        case 126: .up
        case 125: .down
        case 116: .pageUp
        case 121: .pageDown
        case 115: .home
        case 119: .end
        default: nil
        }
        if let key, let controller {
            controller.handleKey(key)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// The scroll view: it tells the controller when the reader uses the wheel or trackpad, so only those moves change the
/// latch (a layout-driven change of the bounds never does).
@MainActor
final class ChatScrollView: NSScrollView {
    weak var controller: ChatStreamController?

    override func scrollWheel(with event: NSEvent) {
        controller?.noteWheel(event)
        super.scrollWheel(with: event)
    }

    /// Every layout pass of the scroll view ends with the table's one column as wide as the visible area. The table
    /// keeps its column widths when its container shrinks after having been wider (a window that grew, an inspector
    /// that opened over it), so a row would stay as wide as it was and be cut at the right edge.
    override func tile() {
        super.tile()
        controller?.fitColumnToView()
    }
}

/// The scroller: dragging it leaves Following at once.
@MainActor
final class ChatScroller: NSScroller {
    weak var controller: ChatStreamController?

    override func mouseDown(with event: NSEvent) {
        controller?.scrollerDragBegan()
        super.mouseDown(with: event) // tracks the drag and returns when the button is released
        controller?.scrollerDragEnded()
    }
}

/// A table cell: one row's SwiftUI view.
@MainActor
final class ChatRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ChatRowCell")
    private let hosting: NSHostingView<ChatRowView>

    init(context: ChatRowContext) {
        hosting = NSHostingView(rootView: ChatRowView(row: ChatRow(id: "-", kind: .empty), context: context))
        super.init(frame: .zero)
        identifier = Self.identifier
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = bounds
        addSubview(hosting)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: ChatRow, context: ChatRowContext, fadeIn: Bool) {
        ChatRenderProbe.configure(row.id)
        hosting.rootView = ChatRowView(row: row, context: context)
        if fadeIn, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = LoomTheme.Chat.fadeDuration
                animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
        }
    }
}

/// Hosts the controller's scroll view in SwiftUI.
struct ChatStreamHost: NSViewRepresentable {
    let controller: ChatStreamController

    func makeNSView(context: Context) -> NSScrollView { controller.scrollView }
    func updateNSView(_ view: NSScrollView, context: Context) {}
}
