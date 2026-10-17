import AppKit
import LoomCore
import SwiftUI

public struct DetailView: View {
    @Bindable var model: CatalogModel

    public init(model: CatalogModel) { self.model = model }

    public var body: some View {
        let route = model.detailRoute
        VStack(spacing: 0) {
            DetailTop(model: model, showsSessionHeader: route.showsSessionHeader)
            Banners(model: model)
            DeletionBanner(model: model)
            DetailContent(model: model, route: route)
                .detailInspector(model: model)
        }
        .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.panel).fill(route.surface))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.panel).stroke(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
        .clipShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.panel))
        .padding(LoomTheme.Space.panelInset)
        .ignoresSafeArea(.container, edges: .top)
        .background(LoomTheme.Surface.backdrop.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(LoomTheme.Accent.base)
        .environment(\.indicatorsAnimate, model.windowIsActive)
        .sheet(item: $model.renameDraft) { draft in
            RenameSheet(model: model, draft: draft)
        }
        .sheet(item: Binding(get: { model.deletions.confirmation }, set: { model.deletions.confirmation = $0 })) { confirmation in
            DeleteConversationSheet(model: model, confirmation: confirmation)
        }
    }
}

/// The header and, when two or more tabs are open, the tab strip directly under it. Banners come
/// below both, so nothing sits between a title and its tabs.
struct DetailTop: View {
    let model: CatalogModel
    /// False on Home, a draft and a project page: the header then carries no session.
    var showsSessionHeader = true

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(model: model, showsSessionHeader: showsSessionHeader)
            if model.tabStripIsVisible { ConversationTabStrip(model: model) }
        }
    }
}

struct DetailHeader: View {
    let model: CatalogModel
    var showsSessionHeader = true
    static let rowHeight = LoomTheme.Layout.detailRowHeight

    /// The rest of the 52 pt header block is spacing above the terminal; the strip, when shown,
    /// takes that place (header row 36 pt + strip 32 pt, as in the approved preview).
    static func bottomSpacing(stripVisible: Bool) -> CGFloat {
        stripVisible ? 0 : LoomTheme.Layout.headerHeight - rowHeight
    }

    /// The native buttons sit over this header's leading edge only while the
    /// sidebar (which otherwise carries them) is collapsed.
    private var reservesWindowButtons: Bool { model.sidebarCollapsed && !model.isFullScreen }

    var body: some View {
        HStack(spacing: LoomTheme.Space.detailSpacing) {
            if reservesWindowButtons {
                // The native buttons start 19 pt from the window edge, inside this row.
                Color.clear.frame(width: LoomTheme.Layout.detailButtonsGap)
            }
            if model.sidebarCollapsed {
                Button { model.onToggleSidebar?() } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(ChromeButtonStyle()).focusEffectDisabled()
                .help("Show Sidebar (⌃⌘S)")
                .accessibilityLabel("Show sidebar")
            }
            if model.showsDevTerminal {
                ProviderIcon(provider: .synthetic, size: LoomTheme.Layout.providerIconHeader)
                Text("Synthetic terminal (development)").fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            } else if showsSessionHeader, let row = model.selectedRow {
                if let viewed = model.viewedSubagent, viewed.sessionID == row.id {
                    SubagentHeaderRow(model: model, row: row, agentID: viewed.agentID)
                } else {
                    SessionHeaderRow(model: model, row: row)
                }
            } else if let notice = model.preparingNotice {
                PreparingNotice(text: notice)
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            } else {
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            }
        }
        .font(LoomTheme.Typography.body)
        .foregroundStyle(LoomTheme.Text.primary)
        .padding(.horizontal, LoomTheme.Space.detailInset)
        // The window buttons are centered natively 26 pt below the window top
        // (8 pt panel inset + 18 pt); the row's center line is the same.
        .frame(height: Self.rowHeight)
        .padding(.bottom, Self.bottomSpacing(stripVisible: model.tabStripIsVisible))
    }
}

/// A selected session in the header row (D-53, "A with the branch"): the provider mark, then the title,
/// which gives way first; at fixed places on the right the state pill (or a transient text in its place),
/// the project chip ending with the branch, a hairline and the control group (`HeaderFlow`).
struct SessionHeaderRow: View {
    let model: CatalogModel
    let row: SessionRowModel

    var body: some View {
        HStack(spacing: LoomTheme.Space.detailSpacing) {
            ProviderIcon(provider: row.record.session.provider, size: LoomTheme.Layout.providerIconHeader)
            HeaderFlow {
                Text(model.title(of: row)).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                    .headerSlot(.title)
                status
                if let chip = model.headerChip(of: row.record) {
                    ProjectBranchChip(chip: chip).headerSlot(.chip, dropsBranch: chip.dropsBranch)
                }
                HeaderRule().headerSlot(.rule)
                HeaderControlGroup(canStop: model.canStop(row), stop: { model.stopConversation(row.id) }) {
                    Button("Rename…") { model.beginRename(row.id) }
                    Button("Open in Tab") { model.openTab(row.id) }
                        .disabled(model.tabs.isPinned(row.id))
                    Divider()
                    Button("Resume") { model.resumeConversation(row.id) }
                        .disabled(!model.canResume(row))
                    Button("Stop") { model.stopConversation(row.id) }
                        .disabled(!model.canStop(row))
                    SessionLocationMenuItems(row: row)
                    DeletionMenuItems(model: model, row: row)
                }
                .headerSlot(.group)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The state pill, or in its place a transient text as plain secondary text; nothing for a run that ended.
    @ViewBuilder private var status: some View {
        if model.busy[row.id] == .starting {
            Text("Starting — complete any prompts in the terminal")
                .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
                .lineLimit(1).headerSlot(.status, shrinks: true)
        } else if model.isDeleting(row.id) {
            Text("Deleting…").font(LoomTheme.Typography.statusLabel).foregroundStyle(LoomTheme.Text.secondary)
                .lineLimit(1).headerSlot(.status, shrinks: true)
        } else if let notice = model.preparingNotice {
            PreparingNotice(text: notice).headerSlot(.status, shrinks: true)
        } else if let style = StatePillStyle(row.indicator) {
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

struct Banners: View {
    let model: CatalogModel

    /// Whether the stack takes no layout space at all. The "Preparing…" notice is not part of it: a
    /// row here would resize the terminal below (a PTY resize); it lives in the fixed-height header row.
    static func isEmpty(for model: CatalogModel) -> Bool {
        model.ownershipNotice == nil && model.statusMessage == nil
            && model.errorMessage == nil && model.infoMessage == nil
    }

    private var isEmpty: Bool { Self.isEmpty(for: model) }

    var body: some View {
        VStack(spacing: LoomTheme.Space.bannerSpacing) {
            if let notice = model.ownershipNotice {
                Text(notice)
                    .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Status.attention)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fadesIn()
                    .accessibilityIdentifier("ownership-notice")
            }
            if let message = model.statusMessage {
                Text(message)
                    .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fadesIn()
                    .accessibilityIdentifier("status-message")
            }
            if let message = model.errorMessage {
                BannerRow(text: message, color: LoomTheme.Status.failure) { model.dismissError() }
            }
            if let message = model.infoMessage {
                BannerRow(text: message, color: LoomTheme.Text.secondary) { model.dismissInfo() }
            }
        }
        .padding(.horizontal, isEmpty ? 0 : LoomTheme.Space.detailInset)
        .padding(.bottom, isEmpty ? 0 : LoomTheme.Space.bannerBottom)
    }
}

struct BannerRow: View {
    let text: String
    let color: Color
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: LoomTheme.Space.bannerRowSpacing) {
            Text(text).font(LoomTheme.Typography.small).foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .accessibilityLabel("Dismiss message")
        }
        .fadesIn()
    }
}

/// The slim notice above the kept screen of a run that ended. Resume is never the default action (Return
/// does nothing on an ended screen); "Show Details" lets go of the screen and
/// shows the record. It fades in (opacity only): a height animation above the terminal would resize it.
struct EndedScreenNotice: View {
    let model: CatalogModel
    let row: SessionRowModel

    /// The notice text; a resume under way says so.
    static func text(busy: ConversationBusy?) -> String {
        busy == .resuming ? "Resuming…" : "This session is not running."
    }

    var body: some View {
        HStack(spacing: LoomTheme.Space.detailSpacing) {
            Text(Self.text(busy: model.busy[row.id]))
                .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
                .lineLimit(1)
            Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            Button(row.record.lifecycle == .stale ? "Reactivate and Resume" : "Resume") {
                model.resumeConversation(row.id)
            }
            .disabled(!model.canResume(row))
            .buttonStyle(AccentButtonStyle(kind: .filled))
            Button("Show Details") { model.closeEndedScreen(row.id) }
                .help("Closes this screen and shows the session's details")
        }
        .padding(.horizontal, LoomTheme.Space.detailInset).padding(.bottom, LoomTheme.Space.bannerBottom)
        .fadesIn()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ended-screen-notice")
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

/// A history record without a live terminal. It states plainly what is not
/// connected yet; nothing here can start a provider or a PTY.
struct ConversationDetail: View {
    let model: CatalogModel
    let row: SessionRowModel

    /// The state line above the actions. It states what Loom knows: a pending
    /// start, resume or stop; no run; a run without a terminal here; or that
    /// actions are not available right now (for example while quitting).
    nonisolated static func runStateHeading(busy: ConversationBusy?, canResume: Bool, isRunning: Bool) -> String {
        switch busy {
        case .starting: "Starting…"
        case .resuming: "Resuming…"
        case .stopping: "Stopping…"
        case nil: canResume ? "Not running" : isRunning ? "Running" : "Not available right now"
        }
    }

    var body: some View {
        let record = row.record
        let indicator = row.indicator
        ScrollView {
            VStack(alignment: .leading, spacing: LoomTheme.Space.detailSectionSpacing) {
                HStack(spacing: LoomTheme.Space.detailTitleSpacing) {
                    ProviderIcon(provider: record.session.provider, size: LoomTheme.Layout.providerIconDetail)
                    VStack(alignment: .leading, spacing: LoomTheme.Space.detailLineSpacing) {
                        Text(model.title(of: row)).font(LoomTheme.Typography.heading)
                            .foregroundStyle(LoomTheme.Text.primary).textSelection(.enabled)
                        Text(ProviderName.title(record.session.provider) + " session")
                            .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
                    }
                }
                RequestList(model: model, row: row)
                if case let .stopUnverified(message) = indicator {
                    Notice(symbol: "exclamationmark.triangle.fill", color: LoomTheme.Status.failure,
                           title: "Stop could not be verified", text: message)
                } else if case let .problem(message) = indicator {
                    Notice(symbol: "exclamationmark.triangle.fill", color: LoomTheme.Status.failure,
                           title: "This session has a problem", text: message)
                } else if indicator == .identityUnclear {
                    Notice(symbol: "questionmark.diamond", color: LoomTheme.Status.attention,
                           title: "Session identity is not certain",
                           text: "Loom could not tell which provider session this is, so it changed nothing.")
                } else if case let .failed(message) = indicator {
                    Notice(symbol: "exclamationmark.triangle.fill", color: LoomTheme.Status.failure,
                           title: "The provider reported a failure", text: message ?? "No details were provided.")
                } else if indicator == .unviewedCompletion {
                    Notice(symbol: "checkmark.circle", color: LoomTheme.Status.unviewed,
                           title: "Finished while you were away", text: "The provider reported a completed turn.")
                }
                Grid(alignment: .leading, horizontalSpacing: LoomTheme.Space.factColumnSpacing, verticalSpacing: LoomTheme.Space.factRowSpacing) {
                    Fact("Status", indicator.label ?? (record.lifecycle == .active ? "Not running" : "—"))
                    Fact("Project", model.projectName(for: record) ?? "No project")
                    if let origin = model.origin(of: row) { Fact("Opened by", origin.factValue) }
                    Fact("Working directory", record.session.workingDirectory)
                    Fact("Provider session", record.session.providerConversationID ?? "Not assigned yet")
                    Fact("Created", record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Fact("Last activity", record.lastActivityAt.formatted(date: .abbreviated, time: .shortened))
                    Fact("Last used", record.lastUsedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Divider().overlay(LoomTheme.Surface.hairline)
                VStack(alignment: .leading, spacing: LoomTheme.Space.actionsSpacing) {
                    Text(Self.runStateHeading(busy: model.busy[row.id], canResume: model.canResume(row),
                                              isRunning: row.live?.runID != nil))
                        .font(LoomTheme.Typography.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
                    if let reason = model.resumeUnavailableReason(row) {
                        Text(reason)
                            .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
                    } else {
                        Text("Opening this record launches nothing. Resume continues the same provider session in its own folder; if the provider no longer has it, you will see that instead of a new session.")
                            .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
                    }
                    HStack {
                        Button(record.lifecycle == .stale ? "Reactivate and Resume" : "Resume") {
                            model.resumeConversation(row.id)
                        }
                        .disabled(!model.canResume(row))
                        .buttonStyle(AccentButtonStyle(kind: .filled))
                        Button("Stop") { model.stopConversation(row.id) }
                            .disabled(!model.canStop(row))
                        Button("Rename…") { model.beginRename(row.id) }
                    }
                }
            }
            .padding(LoomTheme.Space.detailPadding)
            .frame(maxWidth: LoomTheme.Layout.detailMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
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
                    .accessibilityLabel("Provider request: \(request.summary)")
                }
                // An agent's request to open a session (D-40) follows the provider's own requests.
                OpenRequestBoxes(model: model, requests: openRequests)
            }
            .padding(.horizontal, LoomTheme.Space.detailInset).padding(.bottom, LoomTheme.Space.bannerBottom)
        }
    }
}

struct Notice: View {
    let symbol: String
    let color: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: LoomTheme.Space.noticeSpacing) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LoomTheme.Space.noticeLineSpacing) {
                Text(title).font(LoomTheme.Typography.bodyStrong).foregroundStyle(color)
                Text(text).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.primary).textSelection(.enabled)
            }
        }
        .padding(LoomTheme.Space.noticePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.callout).fill(color.opacity(LoomTheme.Status.tintOpacity)))
        .accessibilityElement(children: .contain)
    }
}

struct Fact: View {
    let name: String
    let value: String
    init(_ name: String, _ value: String) { self.name = name; self.value = value }

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(name).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
                .gridColumnAlignment(.trailing)
            Text(value).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.primary).textSelection(.enabled)
        }
    }
}

struct RenameSheet: View {
    let model: CatalogModel
    @Bindable var draft: RenameDraft

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sheetSpacing) {
            Text("Rename session").font(LoomTheme.Typography.title)
            TextField("Title", text: $draft.text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
                .accessibilityLabel("Session title")
            HStack {
                Text("\(draft.text.count)/\(SessionCatalog.maxTitleLength)")
                    .foregroundStyle(draft.text.count > SessionCatalog.maxTitleLength
                                     ? LoomTheme.Status.failure : LoomTheme.Text.secondary)
                Text("Longer titles are shortened. An empty title returns to the automatic one.")
                    .foregroundStyle(LoomTheme.Text.secondary)
            }
            .font(LoomTheme.Typography.caption)
            if let failure = draft.failure {
                Text(failure).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Status.failure)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.renameDraft = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(draft.saving)
                    .buttonStyle(AccentButtonStyle(kind: .filled))
            }
        }
        .padding(LoomTheme.Space.sheetPadding)
        .frame(width: LoomTheme.Layout.sheetWidth)
        .preferredColorScheme(.dark)
        .tint(LoomTheme.Accent.base)
    }

    private func save() {
        Task { await model.commitRename() }
    }
}

/// The brand accent on a button. `filled` is the default action (dark text on
/// the accent; light text on it is only 2.2 to 3.0:1); `tinted` is a quieter
/// action such as Stop (accent text on a faint accent fill).
struct AccentButtonStyle: ButtonStyle {
    enum Kind { case filled, tinted }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, kind: kind)
    }

    private struct Styled: View {
        let configuration: ButtonStyle.Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(LoomTheme.Typography.body)
                .foregroundStyle(kind == .filled ? LoomTheme.Accent.onAccent : LoomTheme.Accent.base)
                .padding(.horizontal, LoomTheme.Space.buttonH).padding(.vertical, LoomTheme.Space.buttonV)
                .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.control).fill(fill(pressed: pressed)))
                .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.control))
                .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
        }

        private func fill(pressed: Bool) -> Color {
            switch kind {
            case .filled: LoomTheme.Accent.base.opacity(pressed ? LoomTheme.Opacity.accentPressed : 1)
            case .tinted: LoomTheme.Accent.base.opacity(pressed ? LoomTheme.Opacity.accentTintPressed : LoomTheme.Opacity.accentTint)
            }
        }
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
