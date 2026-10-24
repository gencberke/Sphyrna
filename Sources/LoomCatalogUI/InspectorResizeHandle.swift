import SwiftUI

/// The inspector's resize handle (W1-b): a thin strip inside its leading edge, under the column-resize pointer. A drag moves a guide
/// line only, so neither the content nor the inspector re-lays out while it lasts; the release gives the open width class the
/// guide's width, once (`CatalogModel+InspectorWidth`). A double-click resets the class; VoiceOver adjusts it a step at a time.
/// The strip is narrower than the tab bar's inset, so it covers no tab.
struct InspectorResizeHandle: View {
    let model: CatalogModel
    /// The width the inspector is drawn at.
    let width: CGFloat
    let range: ClosedRange<CGFloat>
    /// Set while the drag gesture is active; its fall back to false ends the drag, released or cancelled.
    @GestureState private var dragging = false

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in model.dragInspectorEdge(by: value.translation.width, from: width, range: range) }
    }

    var body: some View {
        Color.clear
            .frame(width: LoomTheme.Inspector.resizeHandleWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) { InspectorResizeGuide(model: model, width: width) }
            .pointerStyle(.columnResize)
            .gesture(drag)
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.resetInspectorWidth() })
            .onChange(of: dragging) { _, active in
                if !active { model.endInspectorDrag() }
            }
            .accessibilityElement()
            .accessibilityLabel("Inspector width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.stepInspectorWidth(by: LoomTheme.Inspector.resizeStep, from: width, range: range)
                case .decrement: model.stepInspectorWidth(by: -LoomTheme.Inspector.resizeStep, from: width, range: range)
                default: break
                }
            }
            .accessibilityAction(named: "Reset to default width") { model.resetInspectorWidth() }
            .accessibilityIdentifier("inspector-resize-handle")
    }
}

/// The line that follows a drag: drawn at the edge's width, measured from the inspector's leading edge (to the left of it when the
/// drag widens). Nothing while there is no drag. It takes no clicks.
private struct InspectorResizeGuide: View {
    let model: CatalogModel
    let width: CGFloat

    var body: some View {
        if let resize = model.inspector.resize {
            Rectangle().fill(LoomTheme.Inspector.resizeGuide)
                .frame(width: LoomTheme.Inspector.resizeGuideWidth)
                .frame(maxHeight: .infinity)
                .offset(x: width - resize.live)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
