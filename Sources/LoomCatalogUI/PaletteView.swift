import AppKit
import SwiftUI

/// Sizes of the palette (concept §6: a popover surface, 14 pt radius, 620 pt wide, grouped rows).
enum PaletteMetrics {
    static let width: CGFloat = 620
    static let topInset: CGFloat = 88
    static let inputHeight: CGFloat = 48
    static let rowHeight: CGFloat = 34
    static let hitRowHeight: CGFloat = 54
    static let headerHeight: CGFloat = 28
    static let footerHeight: CGFloat = 34
    static let listPadding: CGFloat = LoomTheme.Highlight.inset
    static let maximumListHeight: CGFloat = 420
    static let minimumListHeight: CGFloat = 120
    static let bottomMargin: CGFloat = 24
    static let rowInset: CGFloat = 12
    static let rowRadius = LoomTheme.Highlight.radius
    static let emptyHeight: CGFloat = 64

    /// The list's height: its rows and headers, up to the cap and up to what a window of `windowHeight` leaves
    /// under the panel's top and above its footer, then it scrolls.
    static func listHeight(for groups: [PaletteGroup], windowHeight: CGFloat = .infinity) -> CGFloat {
        guard !groups.isEmpty else { return emptyHeight }
        let content = groups.reduce(2 * listPadding) { total, group in
            total + headerHeight + group.items.reduce(0) { $0 + ($1.snippet == nil ? rowHeight : hitRowHeight) }
        }
        let room = windowHeight - topInset - inputHeight - footerHeight - 2 * LoomTheme.Line.hairline - bottomMargin
        return min(content, maximumListHeight, max(minimumListHeight, room))
    }
}

/// The overlay over the whole window: nothing while the palette is closed.
struct PaletteOverlay: View {
    let model: CatalogModel

    var body: some View {
        if model.palette.isOpen {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    LoomTheme.Surface.scrim
                        .contentShape(Rectangle())
                        .onTapGesture { model.palette.close() }
                        .accessibilityHidden(true)
                    PalettePanel(model: model, palette: model.palette, windowHeight: proxy.size.height)
                        .padding(.top, PaletteMetrics.topInset)
                }
            }
            .ignoresSafeArea()
        }
    }
}

struct PalettePanel: View {
    let model: CatalogModel
    @Bindable var palette: PaletteState
    let windowHeight: CGFloat
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            input
            Rectangle().fill(LoomTheme.Surface.hairline).frame(height: LoomTheme.Line.hairline)
            list
            Rectangle().fill(LoomTheme.Surface.hairline).frame(height: LoomTheme.Line.hairline)
            footer
        }
        .frame(width: PaletteMetrics.width)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.floating).fill(LoomTheme.Surface.popover))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.floating)
            .strokeBorder(LoomTheme.Surface.hairline, lineWidth: LoomTheme.Line.hairline))
        .shadow(color: LoomTheme.Depth.shadowColor(LoomTheme.Depth.popover.shadow.opacity),
                radius: LoomTheme.Depth.popover.shadow.blur / 2, y: LoomTheme.Depth.popover.shadow.y)
        .tint(LoomTheme.Accent.base)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    // MARK: Input

    private var input: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(LoomTheme.Typography.body)
                .foregroundStyle(LoomTheme.OnPopover.placeholder)
                .accessibilityHidden(true)
            TextField("", text: Binding(get: { palette.query }, set: { palette.setQuery($0) }),
                      prompt: Text("Sessions, projects, actions, or text inside sessions")
                          .foregroundStyle(LoomTheme.OnPopover.placeholder))
                .textFieldStyle(.plain)
                .font(LoomTheme.TypeScale.reading)
                .foregroundStyle(LoomTheme.Text.primary)
                .focused($fieldFocused)
                .onAppear { fieldFocused = true }
                .onChange(of: palette.openCount) { fieldFocused = true }
                .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
                .onExitCommand { palette.close() }
                .accessibilityLabel("Search")
        }
        .padding(.horizontal, PaletteMetrics.rowInset + 4)
        .frame(height: PaletteMetrics.inputHeight)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow: palette.move(-1)
        case .downArrow: palette.move(1)
        case .return: palette.activateSelected(inTab: press.modifiers.contains(.command))
        case .escape: palette.close()
        default:
            // Control-P and Control-N, as in any text field on the Mac.
            guard press.modifiers == .control, press.characters == "\u{10}" || press.characters == "\u{0E}" else { return .ignored }
            palette.move(press.characters == "\u{10}" ? -1 : 1)
        }
        return .handled
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if palette.groups.isEmpty {
                        Text(palette.query.isEmpty ? "Nothing to show yet" : "No matches")
                            .font(LoomTheme.Typography.body)
                            .foregroundStyle(LoomTheme.Text.secondary)
                            .frame(maxWidth: .infinity, minHeight: PaletteMetrics.emptyHeight)
                    }
                    ForEach(palette.groups) { group in
                        Text(group.title)
                            .font(LoomTheme.Typography.dayHeading)
                            .foregroundStyle(LoomTheme.Text.secondary)
                            .padding(.horizontal, PaletteMetrics.rowInset)
                            .padding(.bottom, 4)
                            .frame(height: PaletteMetrics.headerHeight, alignment: .bottomLeading)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.items) { item in
                            PaletteRow(item: item, selected: item.id == palette.selectedID,
                                       animates: model.windowIsActive) { palette.activate(item.id) }
                                .id(item.id)
                        }
                    }
                }
                .padding(PaletteMetrics.listPadding)
            }
            .frame(height: PaletteMetrics.listHeight(for: palette.groups, windowHeight: windowHeight))
            .onChange(of: palette.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            if palette.isSearching {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                Text("Searching session text…").lineLimit(1)
            } else if let failure = palette.searchFailure {
                Text(failure).lineLimit(1).accessibilityIdentifier("palette-search-failure")
            } else if let note = palette.coverageNote {
                Text(note).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 14) {
                hint("↑↓", "move")
                hint("↵", "open")
                hint("⌘↵", "open in a tab")
                hint("esc", "close")
            }
            .fixedSize()
        }
        .font(LoomTheme.Typography.caption)
        .foregroundStyle(LoomTheme.Text.secondary)
        .padding(.horizontal, PaletteMetrics.rowInset + 4)
        .frame(height: PaletteMetrics.footerHeight)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).foregroundStyle(LoomTheme.Text.primary)
            Text(label)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool
    let animates: Bool
    let activate: () -> Void
    @State private var hovering = false

    /// The evidence run's name for this row: `palette-row:<item id>`.
    private var highlightKey: String { "palette-row:\(item.id)" }

    /// The row draws the hover fill (the cursor or the pointer is on it): its secondary text takes the lifted tone that holds
    /// 4.5:1 on that fill over the popover surface (`OnPopover`).
    private var lit: Bool { selected || hovering || LookEvidence.forcesHover(highlightKey) }

    var body: some View {
        Button(action: activate) {
            if let snippet = item.snippet { hit(snippet) } else { line }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, PaletteMetrics.rowInset)
        .frame(height: item.snippet == nil ? PaletteMetrics.rowHeight : PaletteMetrics.hitRowHeight)
        .background(RowHighlight(
            // The cursor row and the row under the pointer take the same fill; the secondary text of a lit row is lifted so it
            // keeps 4.5:1 on it over the popover surface (`HighlightTests`).
            state: .resolve(selected: false, hovering: lit),
            radius: PaletteMetrics.rowRadius))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var line: some View {
        let secondary = LoomTheme.OnPopover.secondary(lit: lit)
        return HStack(spacing: 10) {
            leading
            Text(item.title)
                .font(LoomTheme.Typography.body)
                .foregroundStyle(LoomTheme.Text.primary)
                .lineLimit(1)
            if let detail = item.detail {
                Text(detail)
                    .font(LoomTheme.Typography.small)
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            if let trailing = item.trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(LoomTheme.Typography.small)
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private func hit(_ snippet: PaletteSnippet) -> some View {
        HStack(alignment: .top, spacing: 10) {
            leading.padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.title).font(LoomTheme.Typography.body).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                    Spacer(minLength: 8)
                    if let trailing = item.trailing, !trailing.isEmpty {
                        Text(trailing).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.OnPopover.secondary(lit: lit)).lineLimit(1)
                    }
                }
                Text(Self.attributed(snippet, lit: lit))
                    .font(LoomTheme.Typography.small)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    /// The role, the words before, the match in the accent colour, the words after.
    static func attributed(_ snippet: PaletteSnippet, lit: Bool = false) -> AttributedString {
        func part(_ text: String, _ color: Color, bold: Bool = false) -> AttributedString {
            var result = AttributedString(text)
            result.foregroundColor = color
            if bold { result.inlinePresentationIntent = .stronglyEmphasized }
            return result
        }
        // An attributed run takes a colour, not a style: the lifted tone for a row under the cursor, the plain secondary otherwise.
        let secondary = lit ? LoomTheme.OnPopover.hoveredSecondaryPair.color : LoomTheme.Text.secondary
        return part(snippet.role.label + "  ", secondary) + part(snippet.before, secondary)
            + part(snippet.match, LoomTheme.OnPopover.accent, bold: true) + part(snippet.after, secondary)
    }

    @ViewBuilder private var leading: some View {
        Group {
            if let indicator = item.indicator {
                IndicatorView(indicator: indicator)
            } else if let symbol = item.symbol {
                Image(systemName: symbol)
                    .font(LoomTheme.Typography.small)
                    .foregroundStyle(LoomTheme.OnPopover.secondary(lit: lit))
            } else {
                Color.clear
            }
        }
        .frame(width: LoomTheme.Layout.indicatorSlot.width + 4, height: LoomTheme.Layout.indicatorSlot.height)
        .environment(\.indicatorsAnimate, animates)
    }
}

/// The overlay as a view for the window: it sits over the split view, draws only while the palette is open and
/// lets every click through while it is closed.
final class PaletteHostingView: NSHostingView<PaletteOverlay> {
    private let palette: PaletteState

    init(model: CatalogModel) {
        palette = model.palette
        super.init(rootView: PaletteOverlay(model: model))
        // Nothing the overlay draws may size the window: an empty (closed) overlay would otherwise ask for 0 × 0.
        sizingOptions = []
    }

    @MainActor @preconcurrency required init(rootView: PaletteOverlay) { fatalError("init(rootView:) is not used") }
    @MainActor @preconcurrency required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { palette.isOpen ? super.hitTest(point) : nil }
}

/// The window-level overlay of the command palette (⌘K). The window's content view controller adds it over its view
/// once; it costs nothing while the palette is closed.
@MainActor
public func makePaletteOverlayView(model: CatalogModel) -> NSView { PaletteHostingView(model: model) }
