import AppKit
import LoomCore
import SwiftUI

public struct DetailView: View {
    @Bindable var model: CatalogModel
    @Environment(\.colorScheme) private var colorScheme

    public init(model: CatalogModel) { self.model = model }

    /// The top banner stack's state: whether "+N" has opened the others.
    @State private var bannerState = BannerStackState()

    /// Whether the banner stack above the content holds nothing.
    static func bannersAreEmpty(_ model: CatalogModel) -> Bool { Banners.isEmpty(for: model) }

    public var body: some View {
        let route = model.detailRoute
        let banners = Banners.items(for: model)
        // One canvas (DESIGN §2 item 2, §6 Terminal framing): no panel, no inset, no border and no second background around
        // the main pane. The sidebar and this pane are divided by the split view's hairline.
        VStack(spacing: 0) {
            // The whole top stack sits above the content: the Chat stream is an AppKit scroll view that is laid over its
            // neighbours (it hid the header and the banners, so a handover's refusal was never seen). It has the page's
            // own fill, so no row shows through behind it, and it takes the clicks on its transparent parts.
            if route.drawsHeaderRow {
                DetailHeader(model: model, showsSessionHeader: route.showsSessionHeader, draft: route.draftHeader)
                    .background(route.surface)
                    .contentShape(Rectangle())
                    .revealsTabRowOnSessionDrag(model: model)
                    .zIndex(2)
            }
            // The tab row belongs to the content column, so that the inspector, when it is a column, starts on the tab row's
            // line and its own 36 pt bar sits beside the row (`detailInspector`).
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    if DetailHeader.drawsStrip(model: model, showsSessionHeader: route.showsSessionHeader) {
                        ConversationTabStrip(model: model)
                    }
                    Banners(model: model, items: banners, state: bannerState)
                }
                // Without a header row a banner would sit under the window's buttons: it keeps the header's 52 pt above it.
                .padding(.top, DetailPageChrome.bannerTop(route: route, bannersAreEmpty: banners.isEmpty))
                .onChange(of: banners.count) { _, count in bannerState.closeIfAlone(count) }
                .onAppear { BannerStackState.current = bannerState }
                .background(route.surface)
                .contentShape(Rectangle())
                .zIndex(1)
                DetailContent(model: model, route: route)
                    .environment(\.bannerStackShown, !banners.isEmpty)
                    .environment(\.detailLeadingClearance, route.drawsHeaderRow ? 0 : DetailPageChrome.leadingClearance(
                        sidebarCollapsed: model.sidebarCollapsed, isFullScreen: model.isFullScreen))
            }
            .detailInspector(model: model)
        }
        // Home and the project page draw no row: the window's buttons, "Show Sidebar" and the notice float over the page.
        .overlay(alignment: .topLeading) {
            if !route.drawsHeaderRow { DetailPageChrome(model: model) }
        }
        .background(route.surface)
        // The terminal face is dark in both appearances (D-63): the whole pane, header and inspector included,
        // is drawn under a dark scheme; the sidebar and every other page follow the appearance.
        .environment(\.colorScheme, route.drawsDark ? .dark : colorScheme)
        .ignoresSafeArea(.container, edges: .top)
        .tint(LoomTheme.Accent.base)
        .environment(\.indicatorsAnimate, model.windowIsActive)
        .environment(\.animatedArt, model.animatedArt)
        .alert("Undo the rewind?", isPresented: Binding(
            get: { model.rewinds.undoPrompt != nil }, set: { if !$0 { model.cancelUndoPrompt() } }
        ), presenting: model.rewinds.undoPrompt) { _ in
            Button("Cancel", role: .cancel) {}
            Button("Overwrite and Undo", role: .destructive) { model.confirmUndoOverwrite() }
        } message: { prompt in
            Text("These files changed after the rewind, and Undo overwrites them with the copies Sphyrna kept: "
                + prompt.files.joined(separator: ", "))
        }
    }
}

/// The header row (DESIGN §6 Header, §8 Header): 52 pt on the canvas, its content centred 26 pt from the window top. A session
/// has a hairline under it; so does the development terminal. The draft's row carries its crumb and the project's button
/// (`DraftHeaderLine`) and, like an empty pane or a startup error, has no hairline. Home and the project page draw no row
/// (`DetailRoute.drawsHeaderRow`): `DetailPageChrome` keeps their window buttons usable.
struct DetailHeader: View {
    let model: CatalogModel
    var showsSessionHeader = true
    /// Set on the draft route: the row draws the draft's line.
    var draft: DraftHeaderTarget?
    static let height = LoomTheme.Layout.headerHeight

    /// The tab row belongs to the page that shows a session (the route with the session header); the model's
    /// `tabStripIsVisible` only says there are enough tabs. While a session is dragged over the header or the row, the row is
    /// drawn as a drop zone even with fewer than two tabs.
    static func drawsStrip(model: CatalogModel, showsSessionHeader: Bool) -> Bool {
        showsSessionHeader && (model.tabStripIsVisible || model.showsTabDropZone)
    }

    /// The hairline under the header: a session's, and the development terminal's; the pages have none.
    static func drawsHairline(showsSessionHeader: Bool, showsDevTerminal: Bool) -> Bool { showsSessionHeader || showsDevTerminal }

    /// The native buttons sit over this header's leading edge only while the
    /// sidebar (which otherwise carries them) is collapsed.
    private var reservesWindowButtons: Bool { model.sidebarCollapsed && !model.isFullScreen }

    var body: some View {
        HStack(spacing: LoomTheme.Space.detailSpacing) {
            if reservesWindowButtons {
                // The native buttons start 19 pt from the window edge, inside this row.
                Color.clear.frame(width: LoomTheme.Layout.detailButtonsGap)
            }
            if model.sidebarCollapsed { ShowSidebarButton(model: model) }
            if model.showsDevTerminal {
                ProviderIcon(provider: .synthetic, size: LoomTheme.Layout.harnessMarkHeader)
                Text("Synthetic terminal (development)").font(LoomTheme.Header.titleFont).lineLimit(1)
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            } else if showsSessionHeader, let row = model.selectedRow {
                SessionHeaderRow(model: model, row: row)
            } else if let draft {
                // The draft's line shows the "Preparing…" notice itself, after its crumb.
                DraftHeaderLine(model: model, projectID: draft.projectID)
            } else if let notice = model.preparingNotice {
                PreparingNotice(text: notice)
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            } else {
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            }
        }
        .font(LoomTheme.Typography.body)
        .foregroundStyle(LoomTheme.Text.primary)
        .padding(.leading, LoomTheme.Header.leadingInset).padding(.trailing, LoomTheme.Header.trailingInset)
        // The window buttons are centered natively 26 pt below the window top; the row's center line is the same.
        .frame(height: Self.height)
        .overlay(alignment: .bottom) {
            if Self.drawsHairline(showsSessionHeader: showsSessionHeader, showsDevTerminal: model.showsDevTerminal) {
                Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// "Show Sidebar" while the sidebar is collapsed: an icon button on the header's centre line.
struct ShowSidebarButton: View {
    let model: CatalogModel

    var body: some View {
        Button { model.onToggleSidebar?() } label: {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(ChromeButtonStyle()).focusEffectDisabled()
        .help("Show Sidebar (⌃⌘S)")
        .accessibilityLabel("Show sidebar")
    }
}

/// What floats over a page that draws no header row (Home, the project page) on the 26 pt centre line: the clearance for the
/// window's native buttons and "Show Sidebar" while the sidebar is collapsed, and the "Preparing…" notice, in the order and
/// at the places the header row has them. It is an overlay on the whole pane, so it takes no layout space; only its buttons
/// take clicks. A page that puts its own content on that line keeps clear with `EnvironmentValues.detailLeadingClearance`.
struct DetailPageChrome: View {
    let model: CatalogModel

    private var reservesWindowButtons: Bool { model.sidebarCollapsed && !model.isFullScreen }

    /// The project page's head holds this line (DESIGN §10 Head), so the "Preparing…" notice is not drawn over it: a head that
    /// moved aside during a start would be worse than a transient notice left out. Home's line is free, and shows it.
    static func showsNotice(on route: DetailRoute) -> Bool {
        if case .projectPage = route { false } else { true }
    }

    var body: some View {
        HStack(spacing: LoomTheme.Space.detailSpacing) {
            if reservesWindowButtons { Color.clear.frame(width: LoomTheme.Layout.detailButtonsGap) }
            if model.sidebarCollapsed { ShowSidebarButton(model: model) }
            if Self.showsNotice(on: model.detailRoute), let notice = model.preparingNotice {
                PreparingNotice(text: notice).allowsHitTesting(false)
            }
        }
        .font(LoomTheme.Typography.body)
        .foregroundStyle(LoomTheme.Text.primary)
        .padding(.leading, LoomTheme.Header.leadingInset)
        .frame(height: LoomTheme.Layout.headerHeight)
    }

    /// Where a page's content on the centre line may start while the buttons float over it: past the leading inset, the
    /// window buttons' clearance (not in full screen, where the buttons are gone), the gap and "Show Sidebar", plus one
    /// more gap. 0 while the sidebar is open: the buttons are in the sidebar then.
    static func leadingClearance(sidebarCollapsed: Bool, isFullScreen: Bool) -> CGFloat {
        guard sidebarCollapsed else { return 0 }
        let gap = LoomTheme.Space.detailSpacing
        let buttons = isFullScreen ? 0 : LoomTheme.Layout.detailButtonsGap + gap
        let toggle = ChromeButtonStyle.hitSize(for: LoomTheme.Layout.chromeButton).width
        return LoomTheme.Header.leadingInset + buttons + toggle + gap
    }

    /// The space above the banners: a page without a header row keeps the header's 52 pt above a banner, which would
    /// otherwise sit under the window's buttons; nothing while there is no banner, or when the row is drawn.
    static func bannerTop(route: DetailRoute, bannersAreEmpty: Bool) -> CGFloat {
        route.drawsHeaderRow || bannersAreEmpty ? 0 : LoomTheme.Layout.headerHeight
    }
}

/// A selected session in the header row (DESIGN §6 Header): the harness's mark, then the title, which gives way first, and
/// right after it the state pill (or a transient text in its place); at fixed places at the trailing edge the project chip
/// ending with the branch, the model segment where the face has no composer bar, a hairline, the inspector toggle and the
/// control group (`HeaderFlow`).
struct SessionHeaderRow: View {
    let model: CatalogModel
    let row: SessionRowModel

    var body: some View {
        let _ = HeaderRenderProbe.row(row.id)
        HStack(spacing: LoomTheme.Space.detailSpacing) {
            ProviderIcon(provider: row.record.session.provider, size: LoomTheme.Layout.harnessMarkHeader)
            HeaderFlow {
                Text(model.title(of: row)).font(LoomTheme.Header.titleFont).lineLimit(1).truncationMode(.tail)
                    .headerSlot(.title)
                status
                if let chip = model.headerChip(of: row.record) {
                    ProjectBranchChip(chip: chip).headerSlot(.chip, dropsBranch: chip.dropsBranch)
                }
                // The model and the context fill, on every face without the composer bar (fix round 3 F). It reads the
                // usage entry in its own body: a reading redraws this segment, not the row.
                if model.headerShowsModelSegment(row) {
                    HeaderModelSegment(model: model, row: row).headerSlot(.model)
                }
                HeaderRule().headerSlot(.rule)
                // The inspector toggle sits beside the control group and shares its place in the row.
                HStack(spacing: LoomTheme.Space.detailSpacing) {
                    HeaderInspectorToggle(model: model, sessionID: row.id)
                    HeaderControlGroup(canStop: model.canStop(row), stop: { model.stopConversation(row.id) }) {
                        Button("Rename…") { model.beginRename(row.id) }
                        Button("Open in Tab") { model.openTab(row.id) }
                            .disabled(model.tabs.isPinned(row.id))
                        if model.canChooseFace {
                            // Both faces stay one click away (D-57: the header carries no switch of its own).
                            Divider()
                            Button(ShellCommand.showChat.title) { model.showFace(.chat) }
                            Button(ShellCommand.showTerminal.title) { model.showFace(.terminal) }
                        }
                        continueItems
                        Divider()
                        Button("Resume") { model.resumeConversation(row.id) }
                            .disabled(!model.canResume(row))
                        Button("Stop") { model.stopConversation(row.id) }
                            .disabled(!model.canStop(row))
                        SessionLocationMenuItems(row: row, model: model)
                        DeletionMenuItems(model: model, row: row)
                    }
                }
                .fixedSize()
                .headerSlot(.group)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The way to end a wait that has begun (the policy banner's move, D-69). The menu offers no move of its own: the
    /// face is the app-wide switch in Settings.
    @ViewBuilder private var continueItems: some View {
        if let title = CatalogModel.cancelMoveTitle(for: model.handover(of: row.id)) {
            Divider()
            Button(title) { model.cancelHandover(sessionID: row.id) }
        }
    }

    /// The state pill, or in its place a transient text as plain secondary text; nothing for a run that ended.
    @ViewBuilder private var status: some View {
        if model.busy[row.id] == .starting {
            Text("Starting — complete any prompts in the terminal")
                .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
                .lineLimit(1).headerSlot(.status, shrinks: true)
        } else if let notice = model.handoverNotice(of: row.id) {
            Text(notice).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
                .lineLimit(1).headerSlot(.status, shrinks: true)
        } else if model.isDeleting(row.id) {
            Text("Deleting…").font(LoomTheme.Typography.statusLabel).foregroundStyle(LoomTheme.Text.secondary)
                .lineLimit(1).headerSlot(.status, shrinks: true)
        } else if let notice = model.preparingNotice {
            PreparingNotice(text: notice).headerSlot(.status, shrinks: true)
        } else if let style = StatePillStyle(row.indicator, suffix: BackgroundWorkText.of(row.reason)) {
            StatePill(indicator: row.indicator, style: style).headerSlot(.status)
        }
    }
}

/// "Preparing Claude…" in the header's fixed-height row: it takes no layout space above the
/// terminal (only opacity changes, DESIGN §6), so starting a conversation never resizes the one on screen.
struct PreparingNotice: View {
    let text: String

    var body: some View {
        Text(text)
            .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
            .lineLimit(1).layoutPriority(1)
            .fadesIn()
            .accessibilityIdentifier("preparing-notice")
    }
}

struct Message: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: LoomTheme.Space.messageSpacing) {
            Image(systemName: symbol).font(LoomTheme.Typography.heroSymbol).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .accessibilityHidden(true)
            Text(title).font(LoomTheme.Typography.heading).foregroundStyle(LoomTheme.Text.primary)
            Text(text).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .multilineTextAlignment(.center).textSelection(.enabled)
        }
        .frame(maxWidth: LoomTheme.Layout.messageMaxWidth)
        .padding(LoomTheme.Space.messagePadding)
        // A group, not .combine: combining drops the selectable text from the element's label.
        .accessibilityElement(children: .contain)
    }
}

struct TerminalHost: NSViewRepresentable {
    let panel: NSView
    func makeNSView(context: Context) -> NSView { panel }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Questions the provider asked that only the user can answer, and the requests of this session's agent
/// to open another session. Nothing is answered on the user's behalf; a failed answer stays visible on the request.
struct RequestList: View {
    let model: CatalogModel
    let row: SessionRowModel
    /// Whether Return answers Approve. Above a live terminal it does not: Return belongs to the
    /// CLI, and a stray one (focus on the window after Esc, a click on the card) must never grant
    /// a permission. The button stays one click away.
    var returnApproves = true

    var body: some View {
        let requests = row.live?.userRequests ?? []
        let openRequests = model.openRequests(for: row.id)
        if !requests.isEmpty || !openRequests.isEmpty {
            VStack(spacing: LoomTheme.Space.requestListSpacing) {
                ForEach(requests) { request in
                    HStack(alignment: .top, spacing: LoomTheme.Space.requestSpacing) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(LoomTheme.Status.attention)
                        VStack(alignment: .leading, spacing: LoomTheme.Space.requestLineSpacing) {
                            Text(request.summary).font(LoomTheme.Typography.smallMedium)
                                .foregroundStyle(LoomTheme.Text.primary).textSelection(.enabled)
                            if let failure = request.failure {
                                Text(failure).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Status.failure)
                            }
                        }
                        Spacer(minLength: LoomTheme.Space.detailMinSpacer)
                        if request.isAnswerable {
                            Button("Deny") {
                                model.answerRequest(sessionID: row.id, requestID: request.id, accept: false)
                            }
                            .buttonStyle(ControlButtonStyle(kind: .secondary))
                            Button("Approve") {
                                model.answerRequest(sessionID: row.id, requestID: request.id, accept: true)
                            }
                            .keyboardShortcut(returnApproves ? .defaultAction : nil)
                            .buttonStyle(AccentButtonStyle(kind: .filled))
                        }
                    }
                    .padding(LoomTheme.Space.requestPadding)
                    .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.callout).fill(LoomTheme.Status.attention.opacity(LoomTheme.Status.tintOpacity)))
                    .fadesIn()
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(ProviderName.title(row.record.session.provider)) request: \(request.summary)")
                }
                // An agent's request to open a session (D-40) follows the provider's own requests.
                OpenRequestBoxes(model: model, requests: openRequests)
            }
            .padding(.horizontal, LoomTheme.Space.detailInset).padding(.bottom, LoomTheme.Space.bannerBottom)
        }
    }
}

struct RenameSheet: View {
    let model: CatalogModel
    @Bindable var draft: RenameDraft

    var body: some View {
        InkSheet(
            title: "Rename session", cancel: { model.renameDraft = nil },
            actions: [SheetAction(id: "save", title: "Save", tint: .filled, isEnabled: !draft.saving, perform: save)]
        ) {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Title", text: $draft.text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                    .accessibilityLabel("Session title")
                    .padding(.top, LoomTheme.Sheet.fieldTop)
                HStack {
                    Text("\(draft.text.count)/\(SessionCatalog.maxTitleLength)")
                        .foregroundStyle(draft.text.count > SessionCatalog.maxTitleLength
                                         ? LoomTheme.Status.failure : LoomTheme.Text.secondary)
                    Text("Longer titles are shortened. An empty title returns to the automatic one.")
                        .foregroundStyle(LoomTheme.Text.secondary)
                }
                .font(LoomTheme.Typography.caption)
                .padding(.top, LoomTheme.Sheet.fieldGap)
                if let failure = draft.failure {
                    Text(failure).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Status.failure)
                        .padding(.top, LoomTheme.Sheet.factGap)
                }
            }
        }
    }

    private func save() {
        Task { await model.commitRename() }
    }
}

/// The brand accent on a button, in the control family (`ControlButtonStyle`). `filled` is the default action (on-accent text on
/// the accent; light text on it is only 2.2 to 3.0:1); `tinted` is a quieter action such as Try again (accent text on a faint
/// accent fill). `size` is the family's: 26 high by default, 30 for a page's main action.
struct AccentButtonStyle: ButtonStyle {
    enum Kind { case filled, tinted }
    let kind: Kind
    var size: LoomTheme.Control.Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        ControlButtonStyle(kind: kind == .filled ? .primary : .tinted, size: size).makeBody(configuration: configuration)
    }
}

/// A banner or request card fades in over `LoomTheme.Motion.bannerDuration`. Opacity only: the
/// banners sit above the terminal, so nothing here may animate layout (a height change would
/// resize the PTY on every frame). Under Reduce Motion the view is simply there.
struct FadesIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .onAppear {
                withAnimation(LoomTheme.Motion.animation(.banner, reduceMotion: reduceMotion)) { shown = true }
            }
    }
}

extension View {
    func fadesIn() -> some View { modifier(FadesIn()) }
}

/// The main window in native full screen. Its toolbar is empty, there only so AppKit centres the window buttons in the 52 pt
/// header; in full screen AppKit would draw it as an opaque strip over the top of the pane, which reaches under the title bar.
/// Auto-hiding it detaches it from the window: it slides down with the menu bar at the screen's top edge and leaves the pane whole.
/// The windowed layout is untouched: these options apply only while the window is in full screen.
public enum MainWindowFullScreen {
    /// The options for `window(_:willUseFullScreenPresentationOptions:)`: what AppKit proposes, with the toolbar auto-hidden. AppKit
    /// accepts `.autoHideToolbar` only together with `.fullScreen` and `.autoHideMenuBar`, so both are set, and `.hideMenuBar`, which
    /// cannot go with `.autoHideMenuBar`, is taken out. `.autoHideMenuBar` needs the Dock hidden or auto-hidden: proposed options
    /// without either get `.autoHideDock` (AppKit raises on a combination it does not accept).
    public static func presentationOptions(proposed: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        var options = proposed.subtracting(.hideMenuBar).union([.fullScreen, .autoHideMenuBar, .autoHideToolbar])
        if !options.contains(.hideDock) && !options.contains(.autoHideDock) { options.insert(.autoHideDock) }
        return options
    }
}
