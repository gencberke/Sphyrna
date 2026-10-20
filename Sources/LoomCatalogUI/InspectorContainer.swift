import SwiftUI

/// The inspector column on the right of the detail panel: closed by default, open per session
/// (`CatalogModel.inspector`). A tab bar, then the open tab: Overview, Changes, Agents or Side (V09, V20, V22).
struct InspectorContainer: View {
    let model: CatalogModel
    /// The column's width: the open tab's (`InspectorTab.width`), and no wider than the pane when it is drawn over it.
    var width = LoomTheme.Rhythm.inspectorWidth
    /// Drawn over the content (a narrow pane): the popover surface and shadow, so it reads as above the content
    /// and not as part of it.
    var overlays = false

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabBar(model: model)
            if let row = model.selectedRow {
                switch model.shownInspectorTab {
                case .overview: InspectorOverview(model: model, row: row)
                case .changes: ChangesTab(model: model, row: row)
                case .agents: InspectorAgents(model: model, row: row)
                case .side: SideTab(model: model, row: row)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(overlays ? LoomTheme.Surface.popover : LoomTheme.Surface.inspector, ignoresSafeAreaEdges: [])
        .overlay(alignment: .leading) {
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(width: LoomTheme.Line.hairline)
                .accessibilityHidden(true)
        }
        .frame(width: width)
        .modifier(OverlayShadow(overlays: overlays))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector")
    }
}

/// The popover shadow of an overlaid inspector; a column has none (and adds no layer for it).
private struct OverlayShadow: ViewModifier {
    let overlays: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if overlays {
            content.shadow(color: LoomTheme.Depth.shadowColor(LoomTheme.Depth.popover.shadow.opacity),
                           radius: LoomTheme.Depth.popover.shadow.blur / 2, x: LoomTheme.Inspector.overlayShadowX)
        } else {
            content
        }
    }
}

/// The tabs: the open one shows its name, the others their symbol and count.
struct InspectorTabBar: View {
    let model: CatalogModel

    static func symbol(_ tab: InspectorTab) -> String {
        switch tab {
        case .overview: "info.circle"
        case .changes: "plus.forwardslash.minus"
        case .agents: "person.crop.circle"
        case .side: "arrow.triangle.branch"
        }
    }

    static func title(_ tab: InspectorTab) -> String {
        switch tab {
        case .overview: "Overview"
        case .changes: "Changes"
        case .agents: "Agents"
        case .side: "Side"
        }
    }

    private func count(_ tab: InspectorTab) -> Int? {
        switch tab {
        case .overview: nil
        case .changes: model.changesFileCount(for: model.selectedSessionID)
        case .agents: model.selectedRow?.live?.subagents.count.nonZero
        case .side: nil
        }
    }

    /// The Side tab's slot holds a dot, and only while one of the session's side chats waits for the user.
    private func showsDot(_ tab: InspectorTab) -> Bool {
        tab == .side && model.sideChatIsWaiting(for: model.selectedSessionID)
    }

    private func accessibilityLabel(_ tab: InspectorTab) -> String {
        if showsDot(tab) { return "\(Self.title(tab)), a side chat is waiting for you" }
        return count(tab).map { "\(Self.title(tab)), \($0)" } ?? Self.title(tab)
    }

    var body: some View {
        HStack(spacing: LoomTheme.Inspector.tabGap) {
            ForEach(model.inspectorTabs, id: \.self) { tab in
                let selected = model.shownInspectorTab == tab
                Button { model.selectInspectorTab(tab) } label: {
                    HStack(spacing: LoomTheme.Inspector.tabContentGap) {
                        Image(systemName: Self.symbol(tab)).font(LoomTheme.Inspector.tabGlyph)
                            .accessibilityHidden(true)
                        if selected { Text(Self.title(tab)).font(LoomTheme.Typography.smallMedium) }
                        if let count = count(tab) {
                            Text("\(count)").font(LoomTheme.Typography.caption).monospacedDigit()
                                .foregroundStyle(LoomTheme.Text.secondaryStyle)
                        } else if showsDot(tab) {
                            Circle().fill(LoomTheme.Side.dot).frame(width: LoomTheme.Side.dotSize, height: LoomTheme.Side.dotSize)
                                .accessibilityHidden(true).accessibilityIdentifier("inspector-side-dot")
                        }
                    }
                    .padding(.horizontal, selected ? LoomTheme.Inspector.tabInset : LoomTheme.Inspector.tabInsetCompact)
                    .frame(height: LoomTheme.Inspector.tabHeight)
                    .foregroundStyle(selected ? LoomTheme.Text.primary : LoomTheme.Text.secondary)
                    .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Highlight.radiusControl))
                }
                .buttonStyle(RowButtonStyle(selected: selected, radius: LoomTheme.Highlight.radiusControl, key: "inspector-tab:\(tab)"))
                .focusEffectDisabled()
                .accessibilityLabel(accessibilityLabel(tab))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LoomTheme.Inspector.tabBarInset)
        .frame(height: LoomTheme.Inspector.tabBarHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
                .accessibilityHidden(true)
        }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

/// The header's inspector toggle: one segment in a group of its own, beside the control group. It does what
/// View > Toggle Inspector does, and shows whether the session's inspector is open.
struct InspectorToggleButton: View {
    let model: CatalogModel
    let sessionID: UUID

    var body: some View {
        let open = model.inspector.isOpen(for: sessionID)
        Button { model.setInspector(open: !open, for: sessionID) } label: {
            Image(systemName: "sidebar.right").frame(width: LoomTheme.Inspector.toggleWidth)
        }
        .buttonStyle(HeaderSegmentStyle(secondaryUntilHovered: !open)).focusEffectDisabled()
        .frame(height: LoomTheme.Header.groupHeight)
        .background(open ? LoomTheme.Surface.controlHover : LoomTheme.Header.group)
        .clipShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.control))
        .fixedSize()
        .help(open ? "Hide Inspector (⌥⌘B)" : "Show Inspector (⌥⌘B)")
        .accessibilityLabel(open ? "Hide inspector" : "Show inspector")
        .accessibilityIdentifier("inspector-toggle")
    }
}

/// Where the inspector of the selected session goes for a detail pane this wide (pure, so a test reads it).
enum InspectorPlacement: Equatable {
    /// Closed, or no session selected.
    case closed
    /// A column beside the content, which gives up its width (the terminal resizes once, on the user's toggle).
    case column
    /// Drawn over the content at the trailing edge: the content keeps its width, so nothing resizes.
    case overlay

    /// The column is only used while the content keeps at least `minimumContent` beside it; below that the
    /// inspector covers the content's trailing edge instead of squeezing it. `inspectorWidth` is the open tab's
    /// (`InspectorTab.width`): the Changes tab's column is wider, so it needs a wider pane to stay a column.
    static func of(open: Bool, detailWidth: CGFloat,
                   inspectorWidth: CGFloat = LoomTheme.Rhythm.inspectorWidth) -> InspectorPlacement {
        guard open else { return .closed }
        return detailWidth - inspectorWidth < LoomTheme.Inspector.minimumContent ? .overlay : .column
    }

    /// The width the content gets.
    func contentWidth(detailWidth: CGFloat, inspectorWidth: CGFloat = LoomTheme.Rhythm.inspectorWidth) -> CGFloat {
        self == .column ? detailWidth - inspectorWidth : detailWidth
    }

    /// The width the inspector is drawn at: the open tab's, but never wider than the pane it covers.
    func inspectorWidth(detailWidth: CGFloat, tabWidth: CGFloat) -> CGFloat {
        self == .overlay ? min(tabWidth, detailWidth) : tabWidth
    }
}

extension View {
    /// Puts the inspector of the selected session beside the content, or over it when the pane is too narrow to
    /// keep `LoomTheme.Inspector.minimumContent` of content next to it (`InspectorPlacement`). With no selected
    /// session it stays closed. It is a plain column in the same layout pass as the content, not a SwiftUI
    /// `.inspector`: that one slides in over many frames and lags the content by a pass, so a terminal was
    /// resized on every frame of a toggle and twice on a change of selection. Here the width changes once, by
    /// the user's toggle only, and never animates (DESIGN §6, Motion: a width change is a PTY resize). The
    /// content is one view in every placement, given its width explicitly from the pane's width in the same
    /// pass; crossing the threshold changes that width once.
    func detailInspector(model: CatalogModel) -> some View {
        let open = model.inspector.isOpen(for: model.selectedSessionID)
        let tabWidth = model.shownInspectorTab.width
        return GeometryReader { proxy in
            let placement = InspectorPlacement.of(open: open, detailWidth: proxy.size.width, inspectorWidth: tabWidth)
            let width = placement.inspectorWidth(detailWidth: proxy.size.width, tabWidth: tabWidth)
            HStack(spacing: 0) {
                self.frame(width: placement.contentWidth(detailWidth: proxy.size.width, inspectorWidth: tabWidth))
                if placement == .column {
                    InspectorContainer(model: model, width: width).transition(.identity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .overlay(alignment: .trailing) {
                if placement == .overlay {
                    InspectorContainer(model: model, width: width, overlays: true).transition(.identity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The tab's width is part of the layout: switching to or from Changes resizes the pane once, like a toggle.
        .transaction(value: InspectorWidthKey(open: open, tab: model.shownInspectorTab)) { $0.animation = nil; $0.disablesAnimations = true }
        .task(id: model.inspectorContextSessions) { model.trackInspectorContext() }
        // Changes reads only while its tab is open on this session: the key is nil otherwise (`CatalogModel+Changes`).
        .task(id: model.changesTrigger) { await model.runChangesRead() }
        // The Side tab's list of side chats is read while the inspector is open on an eligible session, so the tab bar's dot
        // and the tab itself have it when they are looked at (`CatalogModel+Side`).
        .task(id: model.sideTrigger) { await model.runSideRead() }
    }
}

/// What changes the inspector's width or presence: neither may animate (a width change is a PTY resize).
private struct InspectorWidthKey: Equatable {
    let open: Bool
    let tab: InspectorTab
}
