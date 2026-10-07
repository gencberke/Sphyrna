import AppKit
import LoomCore
import SwiftUI

public struct DetailView: View {
    @Bindable var model: CatalogModel

    public init(model: CatalogModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            DetailHeader(model: model)
            Banners(model: model)
            if model.tabStripIsVisible { ConversationTabStrip(model: model) }
            DetailContent(model: model)
        }
        .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.panel).fill(LoomTheme.Surface.panel))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.panel).stroke(LoomTheme.Surface.hairline, lineWidth: LoomTheme.Line.hairline))
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
    }
}

struct DetailHeader: View {
    let model: CatalogModel
    static let rowHeight = LoomTheme.Layout.detailRowHeight

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
            } else if let row = model.selectedRow {
                ProviderIcon(provider: row.record.session.provider, size: LoomTheme.Layout.providerIconHeader)
                Text(model.title(of: row)).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                IndicatorView(indicator: row.indicator)
                if model.busy[row.id] == .starting {
                    Text("Starting — complete any prompts in the terminal")
                        .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
                        .lineLimit(1).layoutPriority(1)
                } else if let label = row.indicator.label {
                    Text(label).font(LoomTheme.Typography.statusLabel).foregroundStyle(row.indicator.labelColor)
                        .lineLimit(1).layoutPriority(1)
                }
            }
            Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            if !model.showsDevTerminal, let row = model.selectedRow, model.canStop(row) {
                Button("Stop") { model.stopConversation(row.id) }
                    .buttonStyle(AccentButtonStyle(kind: .tinted))
                    .accessibilityLabel("Stop conversation")
            }
            if !model.showsDevTerminal, let row = model.selectedRow {
                Menu {
                    Button("Rename…") { model.beginRename(row.id) }
                    Button("Open in Tab") { model.openTab(row.id) }
                        .disabled(model.tabs.isPinned(row.id))
                    Divider()
                    Button("Resume") { model.resumeConversation(row.id) }
                        .disabled(!model.canResume(row))
                    Button("Stop") { model.stopConversation(row.id) }
                        .disabled(!model.canStop(row))
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button).buttonStyle(ChromeButtonStyle()).menuIndicator(.hidden).fixedSize()
                .focusEffectDisabled()
                .accessibilityLabel("Conversation actions")
            }
        }
        .font(LoomTheme.Typography.body)
        .foregroundStyle(LoomTheme.Text.primary)
        .padding(.horizontal, LoomTheme.Space.detailInset)
        // The window buttons are centered natively 26 pt below the window top
        // (8 pt panel inset + 18 pt); the row's center line is the same, and the
        // rest of the 52 pt header is spacing above the terminal.
        .frame(height: Self.rowHeight)
        .padding(.bottom, LoomTheme.Layout.headerHeight - Self.rowHeight)
    }
}

struct Banners: View {
    let model: CatalogModel

    private var isEmpty: Bool {
        model.ownershipNotice == nil && model.statusMessage == nil
            && model.errorMessage == nil && model.infoMessage == nil
    }

    var body: some View {
        VStack(spacing: LoomTheme.Space.bannerSpacing) {
            if let notice = model.ownershipNotice {
                Text(notice)
                    .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Status.attention)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("ownership-notice")
            }
            if let message = model.statusMessage {
                Text(message)
                    .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                .buttonStyle(.plain).foregroundStyle(LoomTheme.Text.secondary)
                .accessibilityLabel("Dismiss message")
        }
    }
}

struct DetailContent: View {
    let model: CatalogModel

    var body: some View {
        Group {
            if let error = model.startupError {
                Message(symbol: "exclamationmark.triangle", title: "Loom could not open its catalog",
                        text: "\(error)\n\nThe catalog file was left untouched. Nothing was created or overwritten.")
            } else if model.showsDevTerminal, let terminal = model.devTerminal {
                TerminalHost(panel: terminal.panel)
            } else if let row = model.selectedRow {
                if let terminal = model.terminalView(for: row.id) {
                    VStack(spacing: 0) {
                        RequestList(model: model, row: row)
                        TerminalHost(panel: terminal).id(ObjectIdentifier(terminal))
                    }
                } else {
                    ConversationDetail(model: model, row: row)
                }
            } else if model.isReady && model.projects.isEmpty && model.list(for: .activity).rows.isEmpty
                        && !model.isSearching {
                VStack(spacing: LoomTheme.Space.emptyStateSpacing) {
                    Message(symbol: "folder.badge.plus", title: "Add a project to begin",
                            text: "Your projects and conversations appear in the sidebar.")
                    HStack {
                        Button("Add Project…") { model.presentAddProject() }
                            .keyboardShortcut("o", modifiers: .command)
                            .buttonStyle(AccentButtonStyle(kind: .filled))
                        Button("New Claude Conversation") { model.startConversation(.claude, projectID: nil) }
                            .disabled(!model.canStart(.claude, projectID: nil))
                        if model.startableProviders.contains(.codex) {
                            Button("New Codex Conversation") { model.startConversation(.codex, projectID: nil) }
                                .disabled(!model.canStart(.codex, projectID: nil))
                        }
                    }
                }
            } else {
                Message(symbol: "text.bubble", title: "No conversation selected",
                        text: "Choose a conversation in the sidebar to see its details.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Message: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: LoomTheme.Space.messageSpacing) {
            Image(systemName: symbol).font(LoomTheme.Typography.heroSymbol).foregroundStyle(LoomTheme.Text.secondary)
            Text(title).font(LoomTheme.Typography.heading).foregroundStyle(LoomTheme.Text.primary)
            Text(text).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
                .multilineTextAlignment(.center).textSelection(.enabled)
        }
        .frame(maxWidth: LoomTheme.Layout.messageMaxWidth)
        .padding(LoomTheme.Space.messagePadding)
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
                        Text(ProviderName.title(record.session.provider) + " conversation")
                            .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
                    }
                }
                RequestList(model: model, row: row)
                if case let .stopUnverified(message) = indicator {
                    Notice(symbol: "exclamationmark.triangle.fill", color: LoomTheme.Status.failure,
                           title: "Stop could not be verified", text: message)
                } else if case let .problem(message) = indicator {
                    Notice(symbol: "exclamationmark.triangle.fill", color: LoomTheme.Status.failure,
                           title: "This conversation has a problem", text: message)
                } else if indicator == .identityUnclear {
                    Notice(symbol: "questionmark.diamond", color: LoomTheme.Status.attention,
                           title: "Conversation identity is not certain",
                           text: "Loom could not tell which provider conversation this is, so it changed nothing.")
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
                    Fact("Working directory", record.session.workingDirectory)
                    Fact("Provider conversation", record.session.providerConversationID ?? "Not assigned yet")
                    Fact("Created", record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Fact("Last used", record.lastUsedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Divider().overlay(LoomTheme.Surface.hairline)
                VStack(alignment: .leading, spacing: LoomTheme.Space.actionsSpacing) {
                    Text(Self.runStateHeading(busy: model.busy[row.id], canResume: model.canResume(row),
                                              isRunning: row.live?.runID != nil))
                        .font(LoomTheme.Typography.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
                    Text("Opening this record launches nothing. Resume continues the same provider conversation in its own folder; if the provider no longer has it, you will see that instead of a new conversation.")
                        .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
                    HStack {
                        Button(record.lifecycle == .stale ? "Reactivate and Resume" : "Resume") {
                            model.resumeConversation(row.id)
                        }
                        .disabled(!model.canResume(row))
                        .keyboardShortcut(.defaultAction)
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

/// Questions the provider asked that only the user can answer. Nothing is
/// answered on the user's behalf; a failed answer stays visible on the request.
struct RequestList: View {
    let model: CatalogModel
    let row: SessionRowModel

    var body: some View {
        let requests = row.live?.userRequests ?? []
        if !requests.isEmpty {
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
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(AccentButtonStyle(kind: .filled))
                        }
                    }
                    .padding(LoomTheme.Space.requestPadding)
                    .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.callout).fill(LoomTheme.Status.attention.opacity(LoomTheme.Status.tintOpacity)))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Provider request: \(request.summary)")
                }
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
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: LoomTheme.Space.noticeLineSpacing) {
                Text(title).font(LoomTheme.Typography.bodyStrong).foregroundStyle(color)
                Text(text).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.primary).textSelection(.enabled)
            }
        }
        .padding(LoomTheme.Space.noticePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.callout).fill(color.opacity(LoomTheme.Status.tintOpacity)))
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
            Text("Rename conversation").font(LoomTheme.Typography.title)
            TextField("Title", text: $draft.text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
                .accessibilityLabel("Conversation title")
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
