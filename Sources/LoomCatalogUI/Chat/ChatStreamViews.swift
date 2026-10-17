import AppKit
import SwiftUI

/// The table of the stream. It takes keys itself (arrows, Page Up/Down, Home/End scroll through the latch; ⌃O cycles the
/// view) instead of moving a row selection nobody draws.
@MainActor
final class ChatTableView: NSTableView {
    weak var controller: ChatStreamController?

    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .control, event.charactersIgnoringModifiers?.lowercased() == "o" {
            controller?.onCycleView?()
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
