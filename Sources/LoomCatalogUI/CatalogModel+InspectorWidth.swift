import Foundation

/// A drag on the inspector's resize handle: the width it started from, the widths it may reach and where its edge is now. The edge
/// is the inspector's leading one, so a drag to the left widens it.
struct InspectorResize: Equatable {
    let widthClass: InspectorWidthClass
    let start: CGFloat
    let range: ClosedRange<CGFloat>
    var live: CGFloat

    init(widthClass: InspectorWidthClass, start: CGFloat, range: ClosedRange<CGFloat>) {
        self.widthClass = widthClass
        self.start = start
        self.range = range
        live = start
    }

    /// The edge's width after a horizontal drag of `translation` points, whole and inside the range.
    func width(dragging translation: CGFloat) -> CGFloat {
        min(max((start - translation).rounded(), range.lowerBound), range.upperBound)
    }
}

/// The inspector's resize handle (W1-b). D-78 made every width change instant so a terminal resizes once per change; a drag keeps
/// that: while it lasts only `InspectorState.resize` moves (the handle's guide draws it), and the release changes the class's width
/// once, so the content takes its new width in one layout pass: one PTY resize, one Chat re-measure.
extension CatalogModel {
    /// The widths a drag may reach in a pane `detailWidth` wide: from the class's minimum up to what leaves the content its 480 pt
    /// beside a column. An overlaid inspector covers the content, which keeps its width, so it may reach the pane's.
    func inspectorResizeRange(detailWidth: CGFloat) -> ClosedRange<CGFloat> {
        let low = inspectorWidthClass.minimumWidth
        let high = inspectorLayout(detailWidth: detailWidth).placement == .overlay
            ? detailWidth : detailWidth - LoomTheme.Inspector.minimumContent
        return low...max(low, high)
    }

    /// One step of a drag on the handle, `translation` points from where it started; the first step starts it from the drawn
    /// `width`. Nothing but the drag's edge moves.
    func dragInspectorEdge(by translation: CGFloat, from width: CGFloat, range: ClosedRange<CGFloat>) {
        if inspector.resize == nil {
            let start = min(max(width, range.lowerBound), range.upperBound)
            inspector.beginResize(InspectorResize(widthClass: inspectorWidthClass, start: start, range: range))
        }
        guard let resize = inspector.resize else { return }
        inspector.moveResize(to: resize.width(dragging: translation))
    }

    /// The release (or a cancelled drag): the class takes the edge's width, once, and only when it moved.
    func endInspectorDrag() {
        guard let resize = inspector.endResize(), resize.live != resize.start else { return }
        setInspectorWidth(resize.live, for: resize.widthClass)
    }

    /// A double-click on the handle: the shown class goes back to its default width.
    func resetInspectorWidth() {
        _ = inspector.endResize()
        setInspectorWidth(inspectorWidthClass.defaultWidth, for: inspectorWidthClass)
    }

    /// The handle's adjustable action: one step wider or narrower than the drawn `width`, inside `range`, taken at once.
    func stepInspectorWidth(by delta: CGFloat, from width: CGFloat, range: ClosedRange<CGFloat>) {
        let target = min(max(width + delta, range.lowerBound), range.upperBound)
        guard target != width else { return }
        setInspectorWidth(target, for: inspectorWidthClass)
    }
}
