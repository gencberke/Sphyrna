import AppKit
import SwiftUI

// The main window's questions (I6b): Rename, Delete, Rewind Files and Discard Side Chat are sheets of the family
// (`SheetFamily.swift`). The state of each already lives on the model, so the window reads one derived value instead of holding a
// presentation of its own: `mainWindowSheet` is that value, and the overlay below draws it over the whole window.

/// One of the main window's four questions, as the window shows it. The id is the state's own: the window never keeps a copy.
enum MainWindowSheet: Hashable {
    case rename(UUID)
    case delete(UUID)
    case rewind(UUID)
    case discard(parent: UUID, id: UUID)
}

extension CatalogModel {
    /// The question the window asks now, if any: the rename draft, the delete confirmation, the rewind sheet, or a side chat's
    /// discard, in that order. Nil while none is open, which is what the window's own keys hold back on.
    var mainWindowSheet: MainWindowSheet? {
        if let draft = renameDraft { return .rename(draft.id) }
        if let confirmation = deletions.confirmation { return .delete(confirmation.id) }
        if let rewind = rewinds.sheet { return .rewind(rewind.id) }
        for session in side.sessions.values.sorted(by: { $0.parentID.uuidString < $1.parentID.uuidString }) {
            if let request = session.discard { return .discard(parent: session.parentID, id: request.id) }
        }
        return nil
    }

    /// Whether a sheet of the window is open. The window's own keys (⌘W, ⌘N, Cmd+Delete …) hold back while it is.
    public var mainSheetIsOpen: Bool { sheets.isOpen }
}

/// The rule for the window's own key commands: a sheet that asks a question keeps the window's keys to itself, so a shortcut
/// cannot rename, delete, rewind, close or start anything behind it. The menu items stay usable with the mouse, as Cmd+Delete
/// already did: only a key-down event is held back (`holdsBack` is asked only then).
public enum MainWindowKeys {
    /// A native sheet on the window (an alert, a panel) holds the keys back the same way as one of the family's.
    public static func holdsBack(attachedSheet: Bool, sheetOpen: Bool) -> Bool { attachedSheet || sheetOpen }
}

/// The sheet of a `MainWindowSheet`: the family's body for the question the model holds. A state that closed between the value and
/// the body (a click, a turn) draws nothing.
enum MainWindowSheets {
    @MainActor @ViewBuilder
    static func view(for sheet: MainWindowSheet, model: CatalogModel) -> some View {
        switch sheet {
        case let .rename(id):
            if let draft = model.renameDraft, draft.id == id {
                RenameSheet(model: model, draft: draft)
            }
        case let .delete(id):
            if let confirmation = model.deletions.confirmation, confirmation.id == id {
                DeleteConversationSheet(model: model, confirmation: confirmation)
            }
        case let .rewind(id):
            if let state = model.rewinds.sheet, state.id == id {
                RewindSheetView(model: model, sheet: state)
            }
        case let .discard(parent, id):
            if let request = model.side.existing(for: parent)?.discard, request.id == id {
                SideDiscardSheet(model: model, parent: parent, request: request)
            }
        }
    }
}

/// The window's questions over both panes: the scrim covers the sidebar too, and the sheet comes down under the window's header.
struct MainSheetOverlay: View {
    let model: CatalogModel

    var body: some View {
        Color.clear
            .sheetLayer(model.sheets) { sheet in
                MainWindowSheets.view(for: sheet, model: model)
            }
    }
}

/// The overlay as a view for the window: it draws only while a question is open and lets every click through while none is.
final class MainSheetHostingView: NSHostingView<MainSheetOverlay> {
    private let sheets: SheetPresenter<MainWindowSheet>

    init(model: CatalogModel) {
        sheets = model.sheets
        super.init(rootView: MainSheetOverlay(model: model))
        // Nothing the overlay draws may size the window: an empty (closed) overlay would otherwise ask for 0 × 0.
        sizingOptions = []
    }

    @MainActor @preconcurrency required init(rootView: MainSheetOverlay) { fatalError("init(rootView:) is not used") }
    @MainActor @preconcurrency required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { sheets.isOpen ? super.hitTest(point) : nil }
}

/// The window-level layer of the main window's questions. The window's content view controller adds it over its view once; it
/// costs nothing while none is open.
@MainActor
public func makeMainSheetOverlayView(model: CatalogModel) -> NSView { MainSheetHostingView(model: model) }
