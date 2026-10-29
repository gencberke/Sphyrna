import AppKit
import LoomCore
import SwiftUI

/// The session drag this app is running, in one place (FB6-5): which session is dragged and which targets the pointer is
/// over. Every target and the source read it, so the three looks (`LoomTheme.Drag`) agree: an insertion line where the
/// dragged thing joins an ordered list, a wash on a target it drops onto, and the source dimmed while the pointer is over
/// nothing that takes it.
///
/// One value shared by the whole process, not a property of `CatalogModel`: the composer's text view and the terminal are AppKit
/// views with no catalog model to ask. It is set when a source's drag starts and cleared when a target takes the drop or when the
/// mouse button is up (SwiftUI says nothing when a drag is cancelled, so the button is watched while a drag is active).
/// Projects are not dragged through it: their live reorder is `ProjectReorderModel` (A1).
@MainActor @Observable
final class DragActivity {
    static let shared = DragActivity()

    private(set) var active: UUID?
    /// The targets the pointer is over that take the drag, by key (`Self.key`); empty: the drag is over nothing that takes it.
    private(set) var over: Set<String> = []
    @ObservationIgnored private var watch: Task<Void, Never>?
    /// Whether a mouse button is down now: the real buttons, of the whole system. Tests give a mouse of their own, because the
    /// person at the Mac can press a button at any moment.
    private let buttonsDown: @MainActor () -> Bool

    init(buttonsDown: @escaping @MainActor () -> Bool = { NSEvent.pressedMouseButtons != 0 }) {
        self.buttonsDown = buttonsDown
    }

    /// How long the button is let be seen released before the drag is called over: a drag starts after the mouse is down.
    static let settle: Duration = .milliseconds(300)
    static let poll: Duration = .milliseconds(100)

    // MARK: Keys

    static let tabs = "tabs"
    static let composerChips = "composer-chips"
    static let composerField = "composer-field"
    static let terminal = "terminal"

    // MARK: A drag

    /// A source's drag starts. The log line carries the first 8 digits of the id, never a name or a path.
    func begin(_ id: UUID) {
        LoomLog.debug(.sidebar, "beginDrag session \(Self.short(id))")
        active = id
        over = []
        watch?.cancel()
        watch = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.settle)
            while !Task.isCancelled, self?.buttonsDown() == true { try? await Task.sleep(for: Self.poll) }
            guard !Task.isCancelled else { return }
            self?.end(why: "button up")
        }
    }

    /// The drag is over: dropped on a target or cancelled.
    func end(why: String) {
        watch?.cancel()
        watch = nil
        guard active != nil || !over.isEmpty else { return }
        LoomLog.debug(.sidebar, "endDrag \(why)")
        active = nil
        over = []
    }

    /// The pointer is over a target that takes the drag / left it.
    func enter(_ key: String) { if !over.contains(key) { over.insert(key) } }
    func leave(_ key: String) { if over.contains(key) { over.remove(key) } }

    /// The source of `id` is dimmed: it is being dragged and the pointer is over nothing that takes it.
    func refuses(_ id: UUID) -> Bool { active == id && over.isEmpty }

    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }
}

extension View {
    /// The look of a source while it is dragged and nothing under the pointer takes it.
    func dragSourceDimming(_ id: UUID) -> some View {
        modifier(DragSourceDimming(id: id))
    }

    /// The target wash over this view while the pointer is over the target `key` with a drag it takes.
    func dragWash(_ key: String, radius: CGFloat = LoomTheme.Drag.washRadius) -> some View {
        modifier(DragWash(key: key, radius: radius))
    }
}

private struct DragSourceDimming: ViewModifier {
    let id: UUID

    func body(content: Content) -> some View {
        content.opacity(DragActivity.shared.refuses(id) ? LoomTheme.Drag.sourceOpacity : 1)
    }
}

private struct DragWash: ViewModifier {
    let key: String
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if DragActivity.shared.over.contains(key) {
                RoundedRectangle(cornerRadius: radius)
                    .fill(LoomTheme.Drag.wash)
                    .overlay(RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(LoomTheme.Drag.edge, lineWidth: LoomTheme.Drag.edgeWidth))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}
