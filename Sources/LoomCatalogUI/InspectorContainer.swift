import SwiftUI

/// The inspector column on the right of the detail panel: closed by default, open per session
/// (`CatalogModel.inspector`). A tab bar, then the open tab: Overview, Changes, Agents or Side (V09, V20, V22).
struct InspectorContainer: View {
    let model: CatalogModel
    /// The column's width: the open class's (`InspectorWidthClass`), as the pane draws it (`InspectorLayout`).
    var width = LoomTheme.Rhythm.inspectorWidth
    /// Drawn over the content (a narrow pane): the popover surface and shadow, so it reads as above the content
    /// and not as part of it.
    var overlays = false
    /// The widths the leading edge's resize handle may reach; nil draws no handle.
    var resizeRange: ClosedRange<CGFloat>?

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
        .overlay(alignment: .leading) {
            if let resizeRange {
                InspectorResizeHandle(model: model, width: width, range: resizeRange)
            }
        }
        .modifier(OverlayShadow(overlays: overlays))
        .environment(\.inspectorOverlays, overlays)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector")
    }
}

/// The popover shadow of an overlaid inspector; a column has none (and adds no layer for it).
private struct OverlayShadow: ViewModifier {
    let overlays: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if overlays {
            content.depth(LoomTheme.Elevation.popover, x: LoomTheme.Inspector.overlayShadowX)
        } else {
            content
        }
    }
}

/// The view tabs (DESIGN §6 Tabs): underlined text on a 36 pt bar with a hairline, each showing its name. The open one has an
/// accent underline on the hairline; a count in mono, or the Side tab's dot, follows the label.
struct InspectorTabBar: View {
    let model: CatalogModel
    @Environment(\.inspectorOverlays) private var overlays

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
                        Text(Self.title(tab)).inspectorType(LoomTheme.Inspector.tabLabel)
                        if let count = count(tab) {
                            Text("\(count)").inspectorType(LoomTheme.Inspector.tabCount)
                                .foregroundStyle(LoomTheme.Inspector.quiet(overlays: overlays))
                        } else if showsDot(tab) {
                            Circle().fill(LoomTheme.Side.dot).frame(width: LoomTheme.Side.dotSize, height: LoomTheme.Side.dotSize)
                                .accessibilityHidden(true).accessibilityIdentifier("inspector-side-dot")
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(InspectorTabStyle(selected: selected, key: "inspector-tab:\(tab)"))
                .focusEffectDisabled()
                .accessibilityLabel(accessibilityLabel(tab))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LoomTheme.Inspector.tabBarInset)
        .frame(height: LoomTheme.Inspector.tabBarHeight)
        // Behind the tabs, so the open tab's underline is drawn over the hairline it sits on.
        .background(alignment: .bottom) {
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
                .accessibilityHidden(true)
        }
    }
}

/// A view tab's look: secondary text, primary on hover and when open, and the open tab's accent underline along the bar's
/// bottom edge. No pill (DESIGN §6 Tabs). `key` names the tab for the evidence run's `hover:` command.
private struct InspectorTabStyle: ButtonStyle {
    let selected: Bool
    let key: String

    func makeBody(configuration: Configuration) -> some View {
        Tab(configuration: configuration, selected: selected, key: key)
    }

    private struct Tab: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        let key: String
        @State private var hovering = false
        @Environment(\.isFocused) private var focused

        var body: some View {
            let ring = ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled)
            let lit = selected || hovering || LookEvidence.forcesHover(key)
            configuration.label
                .foregroundStyle(lit ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
                .opacity(configuration.isPressed ? LoomTheme.Opacity.rowPressed : 1)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(LoomTheme.Accent.base).frame(height: LoomTheme.Inspector.tabUnderline)
                        .opacity(selected ? 1 : 0).accessibilityHidden(true)
                }
                .overlay {
                    if ring {
                        Color.clear
                            .controlFocusRing(visible: true, radius: LoomTheme.InkRadius.key)
                            .padding(.vertical, LoomTheme.Inspector.tabFocusInset)
                            .padding(.horizontal, -LoomTheme.Inspector.tabFocusOutset)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .onHover { hovering = $0 }
        }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
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

    /// The width the inspector is drawn at: the open tab's, but never wider than the pane it covers, nor, as a column, wider than
    /// what leaves the content its minimum.
    func inspectorWidth(detailWidth: CGFloat, tabWidth: CGFloat) -> CGFloat {
        switch self {
        case .overlay: min(tabWidth, detailWidth)
        case .column: min(tabWidth, detailWidth - LoomTheme.Inspector.minimumContent)
        case .closed: tabWidth
        }
    }
}

/// The inspector's layout for a detail pane this wide, as one value (pure, so a test reads it): where it goes, how wide it is drawn
/// and what the content keeps. The width is the open one (`CatalogModel.shownInspectorWidth`): the tab's, or the review width while
/// the Agents tab shows a transcript; the overlay rule takes the class's default width, or the open one when that is narrower.
struct InspectorLayout: Equatable {
    let placement: InspectorPlacement
    let inspectorWidth: CGFloat
    let contentWidth: CGFloat

    /// `defaultWidth` is the open class's: the overlay rule stays the one D-78 set for it, so a width dragged wider than the
    /// default never turns a column into an overlay. It gives way to the content's minimum instead, and the stored width stays.
    init(open: Bool, detailWidth: CGFloat, openWidth: CGFloat, defaultWidth: CGFloat? = nil) {
        let fits = min(openWidth, defaultWidth ?? openWidth)
        placement = InspectorPlacement.of(open: open, detailWidth: detailWidth, inspectorWidth: fits)
        inspectorWidth = placement.inspectorWidth(detailWidth: detailWidth, tabWidth: openWidth)
        contentWidth = placement.contentWidth(detailWidth: detailWidth, inspectorWidth: inspectorWidth)
    }
}

extension CatalogModel {
    /// The selected session's inspector layout in a detail pane `detailWidth` wide.
    func inspectorLayout(detailWidth: CGFloat) -> InspectorLayout {
        InspectorLayout(open: inspector.isOpen(for: selectedSessionID), detailWidth: detailWidth, openWidth: shownInspectorWidth,
                        defaultWidth: inspectorWidthClass.defaultWidth)
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
        let openWidth = model.shownInspectorWidth
        return GeometryReader { proxy in
            let layout = model.inspectorLayout(detailWidth: proxy.size.width)
            let placement = layout.placement
            let width = layout.inspectorWidth
            let range = model.inspectorResizeRange(detailWidth: proxy.size.width)
            HStack(spacing: 0) {
                self.frame(width: layout.contentWidth)
                if placement == .column {
                    InspectorContainer(model: model, width: width, resizeRange: range).transition(.identity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .overlay(alignment: .trailing) {
                if placement == .overlay {
                    InspectorContainer(model: model, width: width, overlays: true, resizeRange: range).transition(.identity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The open width is part of the layout: switching to or from Changes, or opening or closing a subagent's transcript, resizes
        // the pane once, like a toggle.
        .transaction(value: InspectorWidthKey(open: open, tab: model.shownInspectorTab, width: openWidth)) { $0.animation = nil; $0.disablesAnimations = true }
        .task(id: model.inspectorContextSessions) { model.trackInspectorContext() }
        // Changes reads only while its tab is open on this session: the key is nil otherwise (`CatalogModel+Changes`).
        .task(id: model.changesTrigger) { await model.runChangesRead() }
        // A stopped session's subagents are read from its folder only while the Agents tab is open on it: the key is nil
        // otherwise, and a new key (another session, the tab opened again) reads once (`StoppedAgents`).
        .task(id: model.agentsTrigger) { await model.runAgentsRead() }
        // The Side tab's list of side chats is read while the inspector is open on an eligible session, so the tab bar's dot
        // and the tab itself have it when they are looked at (`CatalogModel+Side`).
        .task(id: model.sideTrigger) { await model.runSideRead() }
    }
}

/// What changes the inspector's width or presence: neither may animate (a width change is a PTY resize).
private struct InspectorWidthKey: Equatable {
    let open: Bool
    let tab: InspectorTab
    let width: CGFloat
}
