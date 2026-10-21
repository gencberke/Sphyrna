import AppKit
import Observation
import SwiftUI

// Ink's popover and menu host (V2-PLAN §13 I4; DESIGN §3 Depth, §6 Controls → Menus and pickers, §6 Motion). One window-level layer
// per window, like the command palette's: it answers no hit while nothing is open, draws one popover or menu at a time on the
// popover surface (radius 12, the hairline ring and the popover's shadow, no arrow), and does itself what the system popover did:
// it places the surface against its control (`InkPlacement`), dismisses it on an outside click, Esc and the window losing key,
// takes the keyboard while open and gives it back, and enters with opacity and a 3 pt rise.
//
// A control presents through `inkPopover(...)`; the host keeps the content and the key handler fresh as the control re-renders.
// This file draws no Esc binding of its own through SwiftUI (`cancelAction`, `onExitCommand` and the like): the host's view reads
// the key event and takes Esc only while a popover is open, so a pinned card's Esc and default keys stay the card's.

/// The control a popover hangs from. It holds the control's view weakly and answers the control's rect in the host's space.
@MainActor
final class InkAnchor {
    weak var view: NSView?

    init(view: NSView? = nil) { self.view = view }

    /// The control's frame in `host`'s coordinates (flipped, like SwiftUI's), or nil while the control is not in the host's window.
    func rect(in host: NSView) -> CGRect? {
        guard let view, view.window != nil, view.window === host.window else { return nil }
        return host.convert(view.bounds, from: view)
    }
}

/// What the host shows and when. One popover is open at a time; opening another closes the first (its owner is told).
@MainActor @Observable
final class InkHostState {
    /// One open popover or menu.
    struct Open {
        /// Who opened it (the control's anchor), so a control only ever closes its own.
        let owner: ObjectIdentifier
        let id: String
        let anchor: InkAnchor
        let side: InkPlacement.Side
        let alignment: InkPlacement.Alignment
        /// What VoiceOver calls the popover.
        let label: String
        /// Read while the host draws, so it follows whatever model it reads.
        let content: () -> AnyView
        /// A key other than Esc; true when it was used.
        let keys: ((InkKey) -> Bool)?
        /// Whether the host takes the keyboard while this is open. A hover-opened popover leaves it where it is, so typing goes on.
        let takesKeyboard: Bool
        /// Where the keyboard goes when it closes; else the responder it came from.
        let restoreFocus: (() -> Void)?
        /// Called when the host closes it (an outside click, Esc, the window losing key), so the owner lets go of its flag.
        let onClose: () -> Void
    }

    private(set) var active: Open?
    /// Counts fresh opens, so each one draws a new surface (and enters again); a refresh keeps it.
    private(set) var openCount = 0
    /// The popover's measured size; zero until it has been laid out.
    private(set) var contentSize: CGSize = .zero
    private(set) var bounds: CGRect = .zero
    private(set) var anchorRect: CGRect?
    @ObservationIgnored weak var view: InkHostView?

    var isOpen: Bool { active != nil }

    /// Where the popover sits now, once its size is known.
    var frame: CGRect? {
        guard let active, let anchorRect, contentSize.width > 0, contentSize.height > 0 else { return nil }
        return InkPlacement.frame(anchor: anchorRect, size: contentSize, bounds: bounds, side: active.side, alignment: active.alignment)
    }

    // MARK: Opening and closing

    /// Opens `spec`, or refreshes it when its owner already has it open. Another owner's popover is closed and its owner told.
    func present(_ spec: Open) {
        if let current = active, current.owner == spec.owner {
            active = spec
            refreshGeometry()
            return
        }
        let previous = active
        let wasOpen = previous != nil
        active = spec
        openCount += 1
        contentSize = .zero
        refreshGeometry()
        if !wasOpen, spec.takesKeyboard { view?.willOpen() }
        previous?.onClose()
    }

    /// The owner closes its own popover (a pick, a flag turned off). The owner is not called back.
    func close(owner: ObjectIdentifier) {
        guard active?.owner == owner else { return }
        finish(callOwner: false)
    }

    /// The user dismisses the popover (an outside click, Esc, the window losing key). The owner is told.
    func dismiss() { finish(callOwner: true) }

    private func finish(callOwner: Bool) {
        guard let closing = active else { return }
        active = nil
        contentSize = .zero
        anchorRect = nil
        view?.didClose(restoreFocus: closing.restoreFocus)
        if callOwner { closing.onClose() }
    }

    // MARK: Keys

    /// Offers a key to the open popover. Esc closes it; nothing is taken while none is open, so a pinned card or the composer keeps
    /// its Esc.
    func handle(_ key: InkKey) -> Bool {
        guard let active else { return false }
        if key == .escape {
            dismiss()
            return true
        }
        return active.keys?(key) ?? false
    }

    // MARK: Geometry

    func setContentSize(_ size: CGSize) {
        guard size != contentSize else { return }
        contentSize = size
    }

    /// Reads the window's bounds and the control's rect again.
    func refreshGeometry() {
        guard let view else { return }
        if view.bounds != bounds { bounds = view.bounds }
        let rect = active?.anchor.rect(in: view)
        if rect != anchorRect { anchorRect = rect }
    }
}

// MARK: The view

/// The layer over the window: it draws only while a popover is open and lets every click through while none is.
final class InkHostView: NSHostingView<InkHostOverlay> {
    private let state: InkHostState
    /// What had the keyboard when the popover opened, to give it back.
    private weak var previousResponder: NSResponder?
    private var resignObserver: (any NSObjectProtocol)?

    @MainActor init(state: InkHostState) {
        self.state = state
        super.init(rootView: InkHostOverlay(state: state))
        // Nothing the overlay draws may size the window: an empty (closed) overlay would otherwise ask for 0 × 0.
        sizingOptions = []
        state.view = self
    }

    @MainActor @preconcurrency required init(rootView: InkHostOverlay) { fatalError("init(rootView:) is not used") }
    @MainActor @preconcurrency required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    // MARK: Hits

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard state.isOpen else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let frame = state.frame, frame.contains(local) { return super.hitTest(point) }
        return self
    }

    private func insidePopover(_ event: NSEvent) -> Bool {
        guard let frame = state.frame else { return false }
        return frame.contains(convert(event.locationInWindow, from: nil))
    }

    // A click outside the popover closes it and goes no further, as a menu's does: a second click on the control that opened it
    // is the toggle.
    override func mouseDown(with event: NSEvent) {
        if state.isOpen, !insidePopover(event) { state.dismiss() } else { super.mouseDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if state.isOpen, !insidePopover(event) { state.dismiss() } else { super.rightMouseDown(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if state.isOpen, !insidePopover(event) { state.dismiss() } else { super.otherMouseDown(with: event) }
    }

    // MARK: Keys and focus

    override var acceptsFirstResponder: Bool { state.isOpen }

    override func keyDown(with event: NSEvent) {
        guard state.isOpen else {
            super.keyDown(with: event)
            return
        }
        // Keys that mean nothing here are taken too: typing must not leak into the composer behind the popover.
        if let key = InkKey(event: event) { _ = state.handle(key) }
    }

    // A text field inside a popover (the branch name) sends Esc up the responder chain as `cancelOperation:`; it ends here.
    override func cancelOperation(_ sender: Any?) {
        if state.isOpen { state.dismiss() } else { super.cancelOperation(sender) }
    }

    /// True for the host itself and for anything inside it that holds the keyboard (a text field's editor).
    private func holdsKeyboard(_ responder: NSResponder?) -> Bool {
        responder === self || (responder as? NSView)?.isDescendant(of: self) == true
    }

    func willOpen() {
        if let responder = window?.firstResponder, responder !== self { previousResponder = responder }
        window?.makeFirstResponder(self)
    }

    func didClose(restoreFocus: (() -> Void)?) {
        defer { previousResponder = nil }
        guard let window, holdsKeyboard(window.firstResponder) else { return }
        if let restoreFocus {
            restoreFocus()
        } else if let previous = previousResponder, (previous as? NSView)?.window === window {
            window.makeFirstResponder(previous)
        } else {
            window.makeFirstResponder(nil)
        }
    }

    // MARK: Window

    override func layout() {
        super.layout()
        state.refreshGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard let window else { return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.state.dismiss() }
        }
    }
}

// MARK: The drawing

/// The layer's SwiftUI: the open popover on the popover surface, at the frame the placement gives it.
struct InkHostOverlay: View {
    let state: InkHostState

    var body: some View {
        // Nothing at all while nothing is open: no element for VoiceOver, no layer to draw.
        if let active = state.active {
            ZStack(alignment: .topLeading) {
                InkPopoverSurface(state: state, active: active).id(state.openCount)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
            .tint(LoomTheme.Accent.base)
        }
    }
}

/// One popover: radius 12 on `Surface.popover`, the ring and the popover's shadow, entering with opacity and a 3 pt rise over
/// 160 ms (instant under Reduce Motion) and leaving at once.
struct InkPopoverSurface: View {
    let state: InkHostState
    let active: InkHostState.Open
    @State private var entered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let frame = state.frame
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Host.radius)
        active.content()
            .fixedSize()
            .background(LoomTheme.Surface.popover)
            .clipShape(shape)
            .overlay(shape.strokeBorder(LoomTheme.Host.ring, lineWidth: LoomTheme.Host.ringWidth))
            .depth(LoomTheme.Elevation.popover)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { state.setContentSize($0) }
            .offset(x: frame?.minX ?? 0, y: (frame?.minY ?? 0) + (entered ? 0 : Self.entryOffset(side: active.side)))
            .opacity(frame != nil && entered ? 1 : 0)
            .onChange(of: frame != nil, initial: true) { _, placed in
                guard placed, !entered else { return }
                withAnimation(LoomTheme.Host.entrance(reduceMotion: reduceMotion)) { entered = true }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(active.label)
    }

    /// Where the surface starts: 3 pt towards its control and settles away from it, as the reference's `translateY`.
    static func entryOffset(side: InkPlacement.Side) -> CGFloat {
        side == .above ? LoomTheme.Host.rise : -LoomTheme.Host.rise
    }
}

// MARK: Reaching the host

private struct InkHostKey: EnvironmentKey {
    static let defaultValue: InkHostState? = nil
}

extension EnvironmentValues {
    /// The window's host. A view outside a window that has one (a test's rig, a preview) has none, and its popovers stay shut.
    var inkHost: InkHostState? {
        get { self[InkHostKey.self] }
        set { self[InkHostKey.self] = newValue }
    }
}

/// A window's host: the layer to add over the window's content, and the environment its views present through.
@MainActor
public final class InkHost {
    let state = InkHostState()
    /// The layer. Add it over the whole content of the window, once; it costs nothing while nothing is open.
    public let view: NSView

    public init() {
        view = InkHostView(state: state)
    }
}

extension View {
    /// Lets this view's popovers and menus open in `host`.
    public func inkHost(_ host: InkHost) -> some View { environment(\.inkHost, host.state) }

    /// Presents `content` in the window's host while `isPresented` is true, against this view (replacing `.popover`).
    /// - `side` and `alignment` say where it opens (`InkPlacement`).
    /// - `takesKeyboard` is false for a popover that opens under the pointer and must not interrupt typing.
    /// - `keys` gets the arrow keys, Return and Space while it is open; Esc is the host's.
    /// - The content and the handler are read again whenever this view renders, so they follow the model.
    func inkPopover<Content: View>(
        isPresented: Binding<Bool>, id: String, label: String, side: InkPlacement.Side, alignment: InkPlacement.Alignment,
        takesKeyboard: Bool = true, keys: ((InkKey) -> Bool)? = nil, restoreFocus: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(InkPopoverModifier(isPresented: isPresented, id: id, label: label, side: side, alignment: alignment,
                                    takesKeyboard: takesKeyboard, keys: keys, restoreFocus: restoreFocus,
                                    popover: { AnyView(content()) }))
    }
}

private struct InkPopoverModifier: ViewModifier {
    let isPresented: Binding<Bool>
    let id: String
    let label: String
    let side: InkPlacement.Side
    let alignment: InkPlacement.Alignment
    let takesKeyboard: Bool
    let keys: ((InkKey) -> Bool)?
    let restoreFocus: (() -> Void)?
    let popover: () -> AnyView
    @State private var anchor = InkAnchor()
    @Environment(\.inkHost) private var host

    func body(content: Content) -> some View {
        // Reading the flag here makes this view render again when it changes, which is what brings the host in line.
        let _ = isPresented.wrappedValue
        content
            .background(InkAnchorView(anchor: anchor, sync: sync))
            .onDisappear { host?.close(owner: ObjectIdentifier(anchor)) }
    }

    /// Brings the host in line with the flag. Called from the anchor's view update, so it runs again whenever this view renders.
    private func sync() {
        guard let host else { return }
        let owner = ObjectIdentifier(anchor)
        let binding = isPresented
        // A control that has left its window opens nothing (its last update may land after it went).
        if binding.wrappedValue, anchor.view?.window != nil {
            host.present(InkHostState.Open(
                owner: owner, id: id, anchor: anchor, side: side, alignment: alignment, label: label, content: popover, keys: keys,
                takesKeyboard: takesKeyboard, restoreFocus: restoreFocus, onClose: { binding.wrappedValue = false }))
        } else {
            host.close(owner: owner)
        }
    }
}

/// The control's own rect, as a view behind it. It takes no click and says nothing to VoiceOver.
private struct InkAnchorView: NSViewRepresentable {
    let anchor: InkAnchor
    let sync: @MainActor () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AnchorNSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
        // The host's state is another view's: it changes after this update, not inside it.
        let sync = sync
        Task { @MainActor in sync() }
    }

    final class AnchorNSView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}
