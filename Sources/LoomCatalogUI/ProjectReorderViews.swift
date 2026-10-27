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

/// One part of a project's block in the project list (A1): a head, the drafts, a card or the note. It is a direct child of the
/// list, so the list still builds its rows lazily. The part slides with its project's place (`index`) by one 150 ms movement
/// (none under Reduce Motion), is hidden while its project is the one moved, and reports its frame for the gap. The frame is
/// read outside the slide, so a slide never moves what is measured.
struct ProjectReorderPartModifier: ViewModifier {
    let reorder: ProjectReorderModel
    let project: UUID
    let part: ProjectReorderPart
    let index: Int
    /// The list's gap above the head (read for the head only).
    let topGap: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(reorder: ProjectReorderModel, project: UUID, part: ProjectReorderPart, index: Int, topGap: CGFloat) {
        self.reorder = reorder
        self.project = project
        self.part = part
        self.index = index
        self.topGap = topGap
    }

    func body(content: Content) -> some View {
        let slide = reorder.offsetY(blockAt: index)
        // Read here, on the main actor, and captured as a plain string: the geometry closure is Sendable.
        let space = ProjectReorderModel.contentSpace
        ZStack(alignment: .topLeading) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(reorder.isDragging(project) ? 0 : 1)
                .offset(y: slide)
                .animation(reduceMotion ? nil : .easeOut(duration: LoomTheme.Sidebar.reorderSlide), value: slide)
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(space))
        } action: { frame in
            if part == .head {
                reorder.measure(project, frame: frame, topGap: topGap)
            } else {
                reorder.measurePart(project, part, frame: frame)
            }
        }
        .onDisappear { if part != .head { reorder.forgetPart(project, part) } }
    }
}

extension View {
    /// Makes the view one part of a project's block for the live reorder (A1); see `ProjectReorderPartModifier`.
    func projectReorderPart(_ reorder: ProjectReorderModel, project: UUID, part: ProjectReorderPart, index: Int,
                            topGap: CGFloat = 0) -> some View {
        modifier(ProjectReorderPartModifier(reorder: reorder, project: project, part: part, index: index, topGap: topGap))
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
