import LoomCore
import SwiftUI

/// Geometry and visibility rules of the session tab row (DESIGN §6 Tabs): tabs share the width between 112 and 230 pt, the "+"
/// button ends the row; when 112 pt tabs no longer fit the list scrolls and a chevron button lists every tab.
struct TabStripLayout: Equatable {
    /// The strip is drawn for at least this many visible tabs.
    static let minimumTabs = 2

    static func isVisible(tabCount: Int) -> Bool { tabCount >= minimumTabs }

    let count: Int
    /// The whole strip's width.
    let width: CGFloat

    private var inner: CGFloat { width - 2 * LoomTheme.TabStrip.inset }

    /// What the "+" button takes at the end of the row, with its gap.
    static var plusReserve: CGFloat { LoomTheme.TabStrip.gap + LoomTheme.TabStrip.plus }

    /// The room for the tabs (and the chevron when they overflow): the row without its "+" button.
    private var available: CGFloat { inner - Self.plusReserve }

    private func contentWidth(tabWidth: CGFloat) -> CGFloat {
        CGFloat(count) * tabWidth + CGFloat(max(count - 1, 0)) * LoomTheme.TabStrip.gap
    }

    var overflows: Bool { contentWidth(tabWidth: LoomTheme.TabStrip.minTabWidth) > available }

    var tabWidth: CGFloat {
        guard count > 0 else { return LoomTheme.TabStrip.maxTabWidth }
        if overflows { return LoomTheme.TabStrip.minTabWidth }
        let share = (available - CGFloat(count - 1) * LoomTheme.TabStrip.gap) / CGFloat(count)
        return min(LoomTheme.TabStrip.maxTabWidth, max(LoomTheme.TabStrip.minTabWidth, share))
    }

    /// The width of the scrolling list: the tabs themselves, so the "+" button follows the last one; when the tabs overflow it
    /// gives up room to the chevron.
    var listWidth: CGFloat {
        overflows ? available - LoomTheme.TabStrip.gap - LoomTheme.TabStrip.overflowWidth : contentWidth(tabWidth: tabWidth)
    }

    /// Whether a tab is cut at the leading edge: the list is scrolled, so a fade there says there is more.
    func showsLeadingFade(scrollOffset: CGFloat) -> Bool { overflows && scrollOffset > 0.5 }

    /// Tabs whose status indicator (at the leading edge) is scrolled out of the list.
    func hiddenIndices(scrollOffset: CGFloat) -> [Int] {
        guard overflows else { return [] }
        let step = tabWidth + LoomTheme.TabStrip.gap
        let indicator = LoomTheme.TabStrip.indicatorEnd
        return (0..<count).filter { index in
            let leading = CGFloat(index) * step - scrollOffset
            return leading < 0 || leading + indicator > listWidth
        }
    }

    /// Where a scroll must align the tab at `index` to reveal it fully: nil when it is already
    /// fully visible (the list never moves without need).
    func revealEdge(of index: Int, scrollOffset: CGFloat) -> HorizontalEdge? {
        guard overflows else { return nil }
        let leading = CGFloat(index) * (tabWidth + LoomTheme.TabStrip.gap)
        if leading < scrollOffset { return .leading }
        if leading + tabWidth > scrollOffset + listWidth { return .trailing }
        return nil
    }

    /// The gap a drop at `x` (in the strip) lands in: the number of visible tabs whose middle is left of it, so 0 is before
    /// the first tab and `count` after the last (also over the chevron and the "+" button).
    func dropGap(atX x: CGFloat, scrollOffset: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        let inList = x - LoomTheme.TabStrip.inset
        guard inList < listWidth else { return count }
        let step = tabWidth + LoomTheme.TabStrip.gap
        let position = inList + (overflows ? scrollOffset : 0) - tabWidth / 2
        return min(max(Int((position / step).rounded(.down)) + 1, 0), count)
    }

    /// Where the insertion mark of `gap` stands in the strip: in the middle of the space between two tabs, kept inside the list.
    func insertionX(forGap gap: Int, scrollOffset: CGFloat) -> CGFloat {
        let step = tabWidth + LoomTheme.TabStrip.gap
        let inList = CGFloat(gap) * step - LoomTheme.TabStrip.gap / 2 - (overflows ? scrollOffset : 0)
        return LoomTheme.TabStrip.inset + min(max(inList, 0), max(listWidth, 0))
    }

    /// The strongest status among hidden tabs, the same priority as a project row.
    static func hiddenAttention(_ indicators: [SessionIndicator]) -> ProjectAttention? {
        ProjectAttention.strongest(of: indicators)
    }
}

/// The session tab row (D-33; DESIGN §6 Tabs): pinned tabs plus the selected session as one transient (italic) tab, 36 pt high
/// with a hairline under it. Selecting a tab swaps the terminal view; it never starts or stops anything, and closing a tab only
/// unpins it. A "+" icon button ends the row.
struct ConversationTabStrip: View {
    let model: CatalogModel
    @State private var scrollOffset: CGFloat = 0
    /// The gap a dragged session would land in, while one is over the strip.
    @State private var dropGap: Int?

    var body: some View {
        let ids = model.visibleTabIDs
        GeometryReader { proxy in
            let layout = TabStripLayout(count: ids.count, width: proxy.size.width)
            HStack(spacing: LoomTheme.TabStrip.gap) {
                TabList(model: model, ids: ids, layout: layout, scrollOffset: $scrollOffset)
                if layout.overflows {
                    TabOverflowButton(model: model, ids: ids, layout: layout, scrollOffset: scrollOffset)
                }
                NewTabButton(model: model)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LoomTheme.TabStrip.inset)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .overlay(alignment: .leading) {
                if let dropGap {
                    TabInsertionMark().offset(x: layout.insertionX(forGap: dropGap, scrollOffset: scrollOffset)
                        - LoomTheme.Drag.lineWidth / 2)
                }
            }
            .contentShape(Rectangle())
            .onDrop(of: [SessionDrag.contentType], delegate: TabStripDropDelegate(
                model: model, layout: layout, scrollOffset: scrollOffset, gap: $dropGap))
        }
        .frame(height: LoomTheme.TabStrip.height)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session tabs")
    }
}

/// Where a dragged session will land: an accent bar as tall as a tab, in the gap.
private struct TabInsertionMark: View {
    var body: some View {
        Rectangle().fill(LoomTheme.Accent.base)
            .frame(width: LoomTheme.Drag.lineWidth, height: LoomTheme.TabStrip.sessionTabHeight)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The strip as a drop target: a session (from the sidebar, Home or a tab) opens pinned at the gap it is dropped in, or moves
/// there when it is already pinned. Anything that is not a session is refused.
struct TabStripDropDelegate: DropDelegate {
    let model: CatalogModel
    let layout: TabStripLayout
    let scrollOffset: CGFloat
    @Binding var gap: Int?

    static func accepts(_ info: DropInfo) -> Bool { SessionDrag.accepts(info.itemProviders(for: [SessionDrag.contentType])) }

    func validateDrop(info: DropInfo) -> Bool { Self.accepts(info) }

    func dropEntered(info: DropInfo) {
        guard Self.accepts(info) else { return }
        model.setTabDropHover(.strip, true)
        DragActivity.shared.enter(DragActivity.tabs)
        gap = layout.dropGap(atX: info.location.x, scrollOffset: scrollOffset)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard Self.accepts(info) else { return DropProposal(operation: .forbidden) }
        let next = layout.dropGap(atX: info.location.x, scrollOffset: scrollOffset)
        if gap != next { gap = next }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        gap = nil
        model.setTabDropHover(.strip, false)
        DragActivity.shared.leave(DragActivity.tabs)
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = gap ?? layout.dropGap(atX: info.location.x, scrollOffset: scrollOffset)
        gap = nil
        model.setTabDropHover(.strip, false)
        DragActivity.shared.end(why: "dropped on tabs")
        let providers = info.itemProviders(for: [SessionDrag.contentType])
        guard !providers.isEmpty else { return false }
        let model = model
        Task { @MainActor in
            guard let id = await SessionDrag.sessionID(from: providers) else { return }
            model.dropOnTabs(id, gap: target)
        }
        return true
    }
}

/// The header above the tab row while a session is dragged over it: the row shows as a drop zone (`showsTabDropZone`), even
/// with fewer than two tabs, until the drag leaves both or ends.
struct TabRowRevealDropDelegate: DropDelegate {
    let model: CatalogModel

    func validateDrop(info: DropInfo) -> Bool { TabStripDropDelegate.accepts(info) }
    func dropEntered(info: DropInfo) { if TabStripDropDelegate.accepts(info) { model.setTabDropHover(.header, true) } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .cancel) }
    func dropExited(info: DropInfo) { model.setTabDropHover(.header, false) }
    func performDrop(info: DropInfo) -> Bool {
        model.setTabDropHover(.header, false)
        return false
    }
}

extension View {
    /// Shows the tab row as a drop zone while a session is dragged over this view (the header).
    func revealsTabRowOnSessionDrag(model: CatalogModel) -> some View {
        onDrop(of: [SessionDrag.contentType], delegate: TabRowRevealDropDelegate(model: model))
    }
}

/// The "+" that ends the row: it opens the new-session page of the project on screen, what ⌘N does there.
private struct NewTabButton: View {
    let model: CatalogModel

    var body: some View {
        Button { ShellCommand.newSession.run(on: model) } label: { InkIcon(.plus) }
            .buttonStyle(ChromeButtonStyle(size: CGSize(width: LoomTheme.TabStrip.plus, height: LoomTheme.TabStrip.plus),
                                           key: "tab-plus"))
            .disabled(!ShellCommand.newSession.isEnabled(on: model))
            .focusEffectDisabled()
            .help("New session (⌘N)")
            .accessibilityLabel("New session")
            .accessibilityIdentifier("tab-new-session")
    }
}

private struct TabList: View {
    let model: CatalogModel
    let ids: [UUID]
    let layout: TabStripLayout
    @Binding var scrollOffset: CGFloat

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LoomTheme.TabStrip.gap) {
                    ForEach(ids, id: \.self) { id in
                        ConversationTabItem(model: model, id: id).frame(width: layout.tabWidth).id(id)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offset in
                scrollOffset = offset
            }
            .onChange(of: model.selectedSessionID) { _, _ in reveal(reader) }
            .onChange(of: layout) { _, _ in reveal(reader) }
            .onAppear { reveal(reader) }
            .overlay(alignment: .trailing) {
                if layout.overflows {
                    LinearGradient(colors: [.clear, LoomTheme.Surface.panel], startPoint: .leading, endPoint: .trailing)
                        .frame(width: LoomTheme.TabStrip.fadeWidth).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .leading) {
                if layout.showsLeadingFade(scrollOffset: scrollOffset) {
                    LinearGradient(colors: [LoomTheme.Surface.panel, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: LoomTheme.TabStrip.fadeWidth).allowsHitTesting(false)
                }
            }
        }
        .frame(width: layout.listWidth)
    }

    /// Scrolls the selected tab into view, by the smallest move.
    private func reveal(_ reader: ScrollViewProxy) {
        guard let selected = model.selectedSessionID, let index = ids.firstIndex(of: selected),
              let edge = layout.revealEdge(of: index, scrollOffset: scrollOffset) else { return }
        reader.scrollTo(selected, anchor: edge == .leading ? .leading : .trailing)
    }
}

/// One tab (DESIGN §6 Tabs): the project's mark, the status slot, the title and a 16 pt end slot that shows the harness's mark
/// and turns into the close button while the pointer is on the tab, the open tab too.
struct ConversationTabItem: View {
    let model: CatalogModel
    let id: UUID
    @State private var hovering = false

    var body: some View {
        let selected = model.selectedSessionID == id
        let transient = model.isTransientTab(id)
        let row = model.tabRow(id)
        let title = row.map { model.title(of: $0) } ?? "Session"
        let indicator = row?.indicator ?? .idle
        let mark = row.flatMap { model.projectMark(of: $0.record) }
        // The mark names the project whatever the setting says; with project colors off it is neutral.
        let shown = row.flatMap { model.headerProjectMark(of: $0.record) }
        let tint = ProjectTabStyle(tone: mark?.tone, selected: selected, hovering: hovering)
        let shape = RoundedRectangle(cornerRadius: LoomTheme.TabStrip.sessionTabRadius)
        HStack(spacing: LoomTheme.TabStrip.tabSpacing) {
            if let shown { ProjectMarkView(name: shown.name, tone: mark?.tone, size: .chip) }
            IndicatorView(indicator: indicator)
            Text(title)
                .font(LoomTheme.InkType.small.font).italic(transient)
                .foregroundStyle(titleColor(selected: selected, stale: indicator == .stale))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            TabEndSlot(model: model, id: id, provider: row?.record.session.provider, showsClose: hovering)
        }
        .padding(.horizontal, LoomTheme.TabStrip.tabInset)
        .frame(height: LoomTheme.TabStrip.sessionTabHeight)
        .background {
            // Resting tabs are flat; a selected or hovered tab keeps its project's tint.
            ZStack {
                shape.fill(selected ? LoomTheme.Surface.raised2 : (hovering ? LoomTheme.Highlight.hover : .clear))
                if selected || hovering, let wash = tint.washColor { shape.fill(wash) }
            }
            .depth(selected ? LoomTheme.Elevation.lift : LoomTheme.Elevation.card)
        }
        .overlay(shape.strokeBorder(
            selected ? tint.stroke.map(AnyShapeStyle.init) ?? AnyShapeStyle(LoomTheme.Surface.hairlineStyle) : AnyShapeStyle(Color.clear),
            lineWidth: LoomTheme.Line.hairline))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .onTapGesture { model.selectTab(id) }
        // Dragged within the strip it reorders the tabs; dragged elsewhere it is the session (a mention in a composer).
        .sessionDragSource(id, title: title)
        // A double click pins the transient tab (a pinned tab ignores it).
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.openTab(id) })
        .contextMenu {
            if transient { Button("Open in Tab") { model.openTab(id) } }
            Button("Close Tab") { model.closeTab(id) }
        }
        .help(Self.tooltip(title: title, project: mark?.name))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(
            title: title, status: indicator.label, transient: transient, project: mark?.name))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        // Activating the tab selects it; closing is the named action (the close button itself is
        // hidden from accessibility, so VoiceOver cannot activate it by accident).
        .accessibilityAction { model.selectTab(id) }
        .accessibilityAction(named: "Close Tab") { model.closeTab(id) }
    }

    /// "<title>, Finished, project mixtape, not pinned"; the project only while project colors are on.
    static func accessibilityLabel(title: String, status: String?, transient: Bool, project: String? = nil) -> String {
        title + (status.map { ", \($0)" } ?? "") + (project.map { ", project \($0)" } ?? "")
            + (transient ? ", not pinned" : "")
    }

    /// The title, and a "Project: <name>" line under it while project colors are on.
    static func tooltip(title: String, project: String?) -> String {
        project.map { "\(title)\nProject: \($0)" } ?? title
    }

    /// Secondary, primary on hover and when open (a stale tab's title stays secondary until it is open).
    private func titleColor(selected: Bool, stale: Bool) -> Color {
        if selected { return LoomTheme.Text.primary }
        if stale { return LoomTheme.Text.secondary }
        return hovering ? LoomTheme.Text.primary : LoomTheme.Text.secondary
    }
}

/// The 16 pt slot at the end of a tab: the harness's mark (12) until the pointer is on the tab, then the close button.
private struct TabEndSlot: View {
    let model: CatalogModel
    let id: UUID
    let provider: ManagedSession.Provider?
    let showsClose: Bool

    var body: some View {
        ZStack {
            if showsClose {
                TabCloseButton(model: model, id: id)
            } else if let provider {
                ProviderIcon(provider: provider, size: LoomTheme.Layout.harnessMarkRow)
            }
        }
        .frame(width: LoomTheme.TabStrip.close, height: LoomTheme.TabStrip.close)
    }
}

private struct TabCloseButton: View {
    let model: CatalogModel
    let id: UUID
    @State private var hovering = false

    var body: some View {
        Button { model.closeTab(id) } label: {
            InkIcon(.close, size: LoomTheme.Icon.tiny)
                .foregroundStyle(hovering ? LoomTheme.Text.primary : LoomTheme.Text.secondary)
                .frame(width: LoomTheme.TabStrip.close, height: LoomTheme.TabStrip.close)
                .background(RoundedRectangle(cornerRadius: LoomTheme.TabStrip.closeRadius)
                    .fill(hovering ? LoomTheme.Surface.hover : .clear))
                .contentShape(RoundedRectangle(cornerRadius: LoomTheme.TabStrip.closeRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close Tab (⌥⌘W)")
        .accessibilityHidden(true) // the tab's own "Close Tab" action does this
    }
}

/// The chevron at the end of an overflowing strip: lists every tab (a check on the selected
/// one) and carries a dot for the strongest status among the tabs scrolled out of view.
private struct TabOverflowButton: View {
    let model: CatalogModel
    let ids: [UUID]
    let layout: TabStripLayout
    let scrollOffset: CGFloat

    var body: some View {
        let hidden = layout.hiddenIndices(scrollOffset: scrollOffset).map { ids[$0] }
        let attention = TabStripLayout.hiddenAttention(hidden.compactMap { model.tabRow($0)?.indicator })
        Menu {
            ForEach(ids, id: \.self) { id in
                let row = model.tabRow(id)
                let title = row.map { model.title(of: $0) } ?? "Session"
                let label = row?.indicator.label
                Button { model.selectTab(id) } label: {
                    let text = label.map { "\(title) — \($0)" } ?? title
                    if model.selectedSessionID == id { Label(text, systemImage: "checkmark") } else { Text(text) }
                }
            }
        } label: {
            // An element, or the Menu leaves the accessibility tree with its hidden icon (ARCHITECTURE §12.1).
            InkIcon(.chevronDown, size: LoomTheme.Icon.tiny)
                .accessibilityElement(children: .ignore)
        }
        .menuStyle(.button).buttonStyle(ChromeButtonStyle(size: CGSize(
            width: LoomTheme.TabStrip.overflowWidth, height: LoomTheme.TabStrip.sessionTabHeight)))
        .menuIndicator(.hidden).fixedSize()
        .overlay(alignment: .topTrailing) {
            if let attention {
                Circle().fill(color(for: attention))
                    .frame(width: LoomTheme.TabStrip.overflowDot, height: LoomTheme.TabStrip.overflowDot)
                    .overlay(Circle().stroke(LoomTheme.Surface.panel, lineWidth: LoomTheme.Line.indicatorRing))
                    .padding(LoomTheme.TabStrip.overflowDotInset).allowsHitTesting(false)
            }
        }
        .focusEffectDisabled()
        .help("All tabs")
        .accessibilityLabel("All tabs")
        .accessibilityValue(attention?.label ?? "")
    }

    private func color(for attention: ProjectAttention) -> Color {
        switch attention {
        case .failure: LoomTheme.Status.failure
        case .attention: LoomTheme.Status.attention
        case .unviewed: LoomTheme.Status.unviewed
        }
    }
}
