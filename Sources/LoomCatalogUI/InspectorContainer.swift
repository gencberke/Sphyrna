import SwiftUI

/// The inspector column on the right of the detail panel: closed by default, open per session
/// (`CatalogModel.inspector`). Empty for now; the Inspector and Agents slice fills it.
struct InspectorContainer: View {
    var body: some View {
        LoomTheme.Surface.inspector
            .inspectorColumnWidth(min: LoomTheme.Rhythm.inspectorWidth, ideal: LoomTheme.Rhythm.inspectorWidth,
                                  max: LoomTheme.Rhythm.inspectorWidthReview)
            .accessibilityIdentifier("inspector")
    }
}

extension View {
    /// Mounts the inspector for the selected session. With no selected session it stays closed.
    func detailInspector(model: CatalogModel) -> some View {
        inspector(isPresented: Binding(
            get: { model.inspector.isOpen(for: model.selectedSessionID) },
            set: { open in
                if let id = model.selectedSessionID { model.setInspectorOpen(open, for: id) }
            }
        )) { InspectorContainer() }
    }
}
