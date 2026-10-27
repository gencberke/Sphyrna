import AppKit
import LoomCore
import SwiftUI

/// The head that follows the pointer while a project is dragged (A1): the head's mark and its name, lifted to elevation 2
/// (a hairline, the card surface and a small shadow) with a little opacity, over the list and under the pointer.
struct ProjectReorderLiftedHead: View {
    let model: CatalogModel
    let project: CatalogProject

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Highlight.radiusCompact)
        HStack(spacing: LoomTheme.Sidebar.headSpacing) {
            ProjectMarkView(name: project.name, tone: model.projectTone(forProject: project.id), size: .head)
            Text(project.name).font(LoomTheme.Sidebar.headName)
                .foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
            Spacer(minLength: LoomTheme.Space.headerSpacing)
        }
        .padding(.leading, LoomTheme.Sidebar.headLeading)
        .padding(.trailing, LoomTheme.Sidebar.headTrailing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: LoomTheme.InkHeight.sidebarRow)
        .background(shape.fill(LoomTheme.Sidebar.reorderLiftFill))
        .overlay(shape.strokeBorder(LoomTheme.Surface.strongEdgeStyle, lineWidth: LoomTheme.Line.hairline))
        .shadow(color: LoomTheme.Sidebar.reorderLiftShadow.color, radius: LoomTheme.Sidebar.reorderLiftShadowRadius,
                x: 0, y: LoomTheme.Sidebar.reorderLiftShadowY)
        .opacity(LoomTheme.Sidebar.reorderLiftOpacity)
    }
}

/// The lifted head over the project list (A1): it reads the pointer, so only this overlay redraws while the pointer moves,
/// not the list under it.
struct ProjectReorderLiftedOverlay: View {
    let model: CatalogModel
    let reorder: ProjectReorderModel

    @ViewBuilder var body: some View {
        if let id = reorder.dragging, let project = model.projects.first(where: { $0.id == id }),
           let frame = reorder.liftedFrame {
            ProjectReorderLiftedHead(model: model, project: project)
                .frame(width: frame.width, height: frame.height, alignment: .leading)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Makes the view a project's block for the live reorder (A1): it slides by `slide` without changing its layout, the
    /// slide is one 150 ms movement (`animation`, nil under Reduce Motion), and the block's layout frame is measured for the
    /// gap. The slide sits inside the measured view, so the geometry the drag reads is never the one it moved.
    func projectReorderBlock(_ reorder: ProjectReorderModel, id: UUID, topGap: CGFloat, slide: CGFloat,
                             animation: Animation?) -> some View {
        ZStack(alignment: .topLeading) {
            self
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: slide)
                .animation(animation, value: slide)
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(ProjectReorderModel.contentSpace))
        } action: { frame in
            reorder.measure(id, frame: frame, topGap: topGap)
        }
    }
}

/// The list's `NSScrollView`, handed to the reorder so a drag near the viewport's edges scrolls the list under the pointer
/// (A1). SwiftUI's `ScrollView` is an `NSScrollView`; this view finds it from inside the content and asks nothing else of
/// it. It is zero sized and draws nothing.
struct ProjectReorderScrollLocator: NSViewRepresentable {
    let onChange: @MainActor (NSScrollView?) -> Void

    func makeNSView(context: Context) -> NSView { Locator(onChange: onChange) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Locator: NSView {
        let onChange: @MainActor (NSScrollView?) -> Void

        init(onChange: @escaping @MainActor (NSScrollView?) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onChange(enclosingScrollView)
        }
    }
}
