import SwiftUI

/// Geometry and visibility rules of the tab strip (design/run1-surfaces-preview.html,
/// surface 3): tabs share the width between 112 and 200 pt; when 112 pt tabs no longer
/// fit the list scrolls and a chevron button lists every tab.
struct TabStripLayout: Equatable {
    /// The strip is drawn for at least this many visible tabs.
    static let minimumTabs = 2

    static func isVisible(tabCount: Int) -> Bool { tabCount >= minimumTabs }

    let count: Int
    /// The whole strip's width.
    let width: CGFloat

    private var inner: CGFloat { width - 2 * LoomTheme.TabStrip.inset }

    private func contentWidth(tabWidth: CGFloat) -> CGFloat {
        CGFloat(count) * tabWidth + CGFloat(max(count - 1, 0)) * LoomTheme.TabStrip.gap
    }

    var overflows: Bool { contentWidth(tabWidth: LoomTheme.TabStrip.minTabWidth) > inner }

    var tabWidth: CGFloat {
        guard count > 0 else { return LoomTheme.TabStrip.maxTabWidth }
        if overflows { return LoomTheme.TabStrip.minTabWidth }
        let share = (inner - CGFloat(count - 1) * LoomTheme.TabStrip.gap) / CGFloat(count)
        return min(LoomTheme.TabStrip.maxTabWidth, max(LoomTheme.TabStrip.minTabWidth, share))
    }

    /// The width of the scrolling list, which gives up room to the chevron when the tabs overflow.
    var listWidth: CGFloat {
        overflows ? inner - LoomTheme.TabStrip.gap - LoomTheme.TabStrip.overflowWidth : inner
    }

    /// Tabs whose status indicator (at the leading edge) is scrolled out of the list.
    func hiddenIndices(scrollOffset: CGFloat) -> [Int] {
        guard overflows else { return [] }
        let step = tabWidth + LoomTheme.TabStrip.gap
        let indicator = LoomTheme.TabStrip.tabInset + LoomTheme.Layout.indicatorSlot.width
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

    /// The strongest status among hidden tabs, the same priority as a project row.
    static func hiddenAttention(_ indicators: [SessionIndicator]) -> ProjectAttention? {
        ProjectAttention.strongest(of: indicators)
    }
}

/// The conversation tab strip (D-33): pinned tabs plus the selected conversation as one
/// transient (italic) tab. Selecting a tab swaps the terminal view; it never starts or
/// stops anything, and closing a tab only unpins it.
struct ConversationTabStrip: View {
    let model: CatalogModel
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        let ids = model.visibleTabIDs
        GeometryReader { proxy in
            let layout = TabStripLayout(count: ids.count, width: proxy.size.width)
            HStack(spacing: LoomTheme.TabStrip.gap) {
                TabList(model: model, ids: ids, layout: layout, scrollOffset: $scrollOffset)
                if layout.overflows {
                    TabOverflowButton(model: model, ids: ids, layout: layout, scrollOffset: scrollOffset)
                }
            }
            .padding(.horizontal, LoomTheme.TabStrip.inset)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .frame(height: LoomTheme.TabStrip.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation tabs")
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

/// One tab: indicator, title and a close button that is reserved on the selected tab only
/// and appears over the end of the title on hover for the others.
struct ConversationTabItem: View {
    let model: CatalogModel
    let id: UUID
    @State private var hovering = false

    var body: some View {
        let selected = model.selectedSessionID == id
        let transient = model.isTransientTab(id)
        let row = model.tabRow(id)
        let title = row.map { model.title(of: $0) } ?? "Conversation"
        let indicator = row?.indicator ?? .idle
        HStack(spacing: LoomTheme.TabStrip.tabSpacing) {
            IndicatorView(indicator: indicator)
            Text(title)
                .font(LoomTheme.Typography.smallMedium).italic(transient)
                .foregroundStyle(titleColor(selected: selected, stale: indicator == .stale))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if selected { TabCloseButton(model: model, id: id, tabHovering: hovering) }
        }
        .padding(.leading, LoomTheme.TabStrip.tabInset)
        .padding(.trailing, selected ? LoomTheme.TabStrip.selectedTrailing : LoomTheme.TabStrip.tabInset)
        .frame(height: LoomTheme.TabStrip.tabHeight)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.control)
            .fill(selected ? LoomTheme.Surface.selected : (hovering ? LoomTheme.Surface.controlHover : .clear)))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.control)
            .strokeBorder(selected ? LoomTheme.Surface.hairline : .clear, lineWidth: LoomTheme.Line.hairline))
        .overlay(alignment: .trailing) {
            if hovering && !selected {
                TabCloseButton(model: model, id: id, tabHovering: true)
                    .padding(.trailing, LoomTheme.TabStrip.hoverCloseInset)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.control))
        .onHover { hovering = $0 }
        .onTapGesture { model.selectTab(id) }
        // A double click pins the transient tab (a pinned tab ignores it).
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.openTab(id) })
        .contextMenu {
            if transient { Button("Open in Tab") { model.openTab(id) } }
            Button("Close Tab") { model.closeTab(id) }
        }
        .help(title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(title: title, status: indicator.label, transient: transient))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        // Activating the tab selects it; closing is the named action (the close button itself is
        // hidden from accessibility, so VoiceOver cannot activate it by accident).
        .accessibilityAction { model.selectTab(id) }
        .accessibilityAction(named: "Close Tab") { model.closeTab(id) }
    }

    static func accessibilityLabel(title: String, status: String?, transient: Bool) -> String {
        title + (status.map { ", \($0)" } ?? "") + (transient ? ", not pinned" : "")
    }

    private func titleColor(selected: Bool, stale: Bool) -> Color {
        if selected { return LoomTheme.Text.primary }
        if stale { return LoomTheme.Text.secondary }
        return hovering ? LoomTheme.Text.primary : LoomTheme.Text.secondary
    }
}

private struct TabCloseButton: View {
    let model: CatalogModel
    let id: UUID
    let tabHovering: Bool
    @State private var hovering = false

    var body: some View {
        Button { model.closeTab(id) } label: {
            Image(systemName: "xmark").font(LoomTheme.Typography.chevron)
                .foregroundStyle(hovering ? LoomTheme.Text.primary : LoomTheme.Text.secondary)
                .frame(width: LoomTheme.TabStrip.close, height: LoomTheme.TabStrip.close)
                .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.bar)
                    .fill(hovering || (tabHovering && !isSelected) ? LoomTheme.Surface.controlPressed : .clear))
                .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.bar))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close Tab (⌥⌘W)")
        .accessibilityHidden(true) // the tab's own "Close Tab" action does this
    }

    private var isSelected: Bool { model.selectedSessionID == id }
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
                let title = row.map { model.title(of: $0) } ?? "Conversation"
                let label = row?.indicator.label
                Button { model.selectTab(id) } label: {
                    let text = label.map { "\(title) — \($0)" } ?? title
                    if model.selectedSessionID == id { Label(text, systemImage: "checkmark") } else { Text(text) }
                }
            }
        } label: {
            Image(systemName: "chevron.down").font(LoomTheme.Typography.chevron)
        }
        .menuStyle(.button).buttonStyle(ChromeButtonStyle(size: CGSize(
            width: LoomTheme.TabStrip.overflowWidth, height: LoomTheme.TabStrip.tabHeight)))
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
