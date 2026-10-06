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
            DetailContent(model: model)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(CatalogTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(CatalogTheme.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(8)
        .ignoresSafeArea(.container, edges: .top)
        .background(CatalogTheme.sidebar.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .environment(\.indicatorsAnimate, model.windowIsActive)
        .sheet(item: $model.renameDraft) { draft in
            RenameSheet(model: model, draft: draft)
        }
    }
}

struct DetailHeader: View {
    let model: CatalogModel
    static let rowHeight = CatalogTheme.detailRowHeight

    /// The native buttons sit over this header's leading edge only while the
    /// sidebar (which otherwise carries them) is collapsed.
    private var reservesWindowButtons: Bool { model.sidebarCollapsed && !model.isFullScreen }

    var body: some View {
        HStack(spacing: 8) {
            if reservesWindowButtons {
                // The native buttons start 19 pt from the window edge, inside this row.
                Color.clear.frame(width: CatalogTheme.detailButtonsGap)
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
                ProviderIcon(provider: .synthetic, size: 16)
                Text("Synthetic terminal (development)").fontWeight(.semibold).lineLimit(1)
            } else if let row = model.selectedRow {
                ProviderIcon(provider: row.record.session.provider, size: 16)
                Text(model.title(of: row)).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                IndicatorView(indicator: row.indicator)
                if model.busy[row.id] == .starting {
                    Text("Starting — complete any prompts in the terminal")
                        .font(.system(size: 11)).foregroundStyle(CatalogTheme.secondary)
                        .lineLimit(1).layoutPriority(1)
                } else if let label = row.indicator.label {
                    Text(label).font(.system(size: 11)).foregroundStyle(row.indicator.labelColor)
                        .lineLimit(1).layoutPriority(1)
                }
            }
            Spacer(minLength: 8)
            if !model.showsDevTerminal, let row = model.selectedRow, model.canStop(row) {
                Button("Stop") { model.stopConversation(row.id) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityLabel("Stop conversation")
            }
            if !model.showsDevTerminal, let row = model.selectedRow {
                Menu {
                    Button("Rename…") { model.beginRename(row.id) }
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
        .font(.system(size: 13))
        .foregroundStyle(CatalogTheme.text)
        .padding(.horizontal, 14)
        // The window buttons are centered natively 26 pt below the window top
        // (8 pt panel inset + 18 pt); the row's center line is the same, and the
        // rest of the 52 pt header is spacing above the terminal.
        .frame(height: Self.rowHeight)
        .padding(.bottom, CatalogTheme.headerHeight - Self.rowHeight)
    }
}

struct Banners: View {
    let model: CatalogModel

    private var isEmpty: Bool {
        model.ownershipNotice == nil && model.statusMessage == nil
            && model.errorMessage == nil && model.infoMessage == nil
    }

    var body: some View {
        VStack(spacing: 6) {
            if let notice = model.ownershipNotice {
                Text(notice)
                    .font(.system(size: 12)).foregroundStyle(CatalogTheme.attention)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("ownership-notice")
            }
            if let message = model.statusMessage {
                Text(message)
                    .font(.system(size: 12)).foregroundStyle(CatalogTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("status-message")
            }
            if let message = model.errorMessage {
                BannerRow(text: message, color: CatalogTheme.failure) { model.dismissError() }
            }
            if let message = model.infoMessage {
                BannerRow(text: message, color: CatalogTheme.secondary) { model.dismissInfo() }
            }
        }
        .padding(.horizontal, isEmpty ? 0 : 14)
        .padding(.bottom, isEmpty ? 0 : 8)
    }
}

struct BannerRow: View {
    let text: String
    let color: Color
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text).font(.system(size: 12)).foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(CatalogTheme.secondary)
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
                VStack(spacing: 12) {
                    Message(symbol: "folder.badge.plus", title: "Add a project to begin",
                            text: "Your projects and conversations appear in the sidebar.")
                    HStack {
                        Button("Add Project…") { model.presentAddProject() }
                            .keyboardShortcut("o", modifiers: .command)
                        Button("New Claude Conversation") { model.startConversation(.claude, projectID: nil) }
                            .disabled(!model.canStart(.claude, projectID: nil))
                        Button("New Codex Conversation") { model.startConversation(.codex, projectID: nil) }
                            .disabled(!model.canStart(.codex, projectID: nil))
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
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(CatalogTheme.secondary)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(CatalogTheme.text)
            Text(text).font(.system(size: 12)).foregroundStyle(CatalogTheme.secondary)
                .multilineTextAlignment(.center).textSelection(.enabled)
        }
        .frame(maxWidth: 420)
        .padding(24)
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

    var body: some View {
        let record = row.record
        let indicator = row.indicator
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    ProviderIcon(provider: record.session.provider, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.title(of: row)).font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(CatalogTheme.text).textSelection(.enabled)
                        Text(ProviderName.title(record.session.provider) + " conversation")
                            .font(.system(size: 12)).foregroundStyle(CatalogTheme.secondary)
                    }
                }
                RequestList(model: model, row: row)
                if case let .stopUnverified(message) = indicator {
                    Notice(symbol: "exclamationmark.triangle.fill", color: CatalogTheme.failure,
                           title: "Stop could not be verified", text: message)
                } else if case let .problem(message) = indicator {
                    Notice(symbol: "exclamationmark.triangle.fill", color: CatalogTheme.failure,
                           title: "This conversation has a problem", text: message)
                } else if indicator == .identityUnclear {
                    Notice(symbol: "questionmark.diamond", color: CatalogTheme.attention,
                           title: "Conversation identity is not certain",
                           text: "Loom could not tell which provider conversation this is, so it changed nothing.")
                } else if case let .failed(message) = indicator {
                    Notice(symbol: "exclamationmark.triangle.fill", color: CatalogTheme.failure,
                           title: "The provider reported a failure", text: message ?? "No details were provided.")
                } else if indicator == .unviewedCompletion {
                    Notice(symbol: "checkmark.circle", color: CatalogTheme.unviewed,
                           title: "Finished while you were away", text: "The provider reported a completed turn.")
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    Fact("Status", indicator.label ?? (record.lifecycle == .active ? "Not running" : "—"))
                    Fact("Project", model.projectName(for: record) ?? "No project")
                    Fact("Working directory", record.session.workingDirectory)
                    Fact("Provider conversation", record.session.providerConversationID ?? "Not assigned yet")
                    Fact("Created", record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Fact("Last used", record.lastUsedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Divider().overlay(CatalogTheme.hairline)
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.canResume(row) ? "Not running" : "Working…")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(CatalogTheme.text)
                    Text("Opening this record launches nothing. Resume continues the same provider conversation in its own folder; if the provider no longer has it, you will see that instead of a new conversation.")
                        .font(.system(size: 12)).foregroundStyle(CatalogTheme.secondary)
                    HStack {
                        Button(record.lifecycle == .stale ? "Reactivate and Resume" : "Resume") {
                            model.resumeConversation(row.id)
                        }
                        .disabled(!model.canResume(row))
                        .keyboardShortcut(.defaultAction)
                        Button("Stop") { model.stopConversation(row.id) }
                            .disabled(!model.canStop(row))
                        Button("Rename…") { model.beginRename(row.id) }
                    }
                    if let busy = model.busy[row.id] {
                        Text(busy == .resuming ? "Resuming…" : busy == .starting ? "Starting…" : "Stopping…")
                            .font(.system(size: 12)).foregroundStyle(CatalogTheme.secondary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
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
            VStack(spacing: 6) {
                ForEach(requests) { request in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(CatalogTheme.attention)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(request.summary).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(CatalogTheme.text).textSelection(.enabled)
                            if let failure = request.failure {
                                Text(failure).font(.system(size: 11)).foregroundStyle(CatalogTheme.failure)
                            }
                        }
                        Spacer(minLength: 8)
                        if request.isAnswerable {
                            Button("Deny") {
                                model.answerRequest(sessionID: row.id, requestID: request.id, accept: false)
                            }
                            Button("Approve") {
                                model.answerRequest(sessionID: row.id, requestID: request.id, accept: true)
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(CatalogTheme.attention.opacity(0.10)))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Provider request: \(request.summary)")
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
        }
    }
}

struct Notice: View {
    let symbol: String
    let color: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
                Text(text).font(.system(size: 12)).foregroundStyle(CatalogTheme.text).textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.10)))
    }
}

struct Fact: View {
    let name: String
    let value: String
    init(_ name: String, _ value: String) { self.name = name; self.value = value }

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(name).font(.system(size: 12)).foregroundStyle(CatalogTheme.secondary)
                .gridColumnAlignment(.trailing)
            Text(value).font(.system(size: 12)).foregroundStyle(CatalogTheme.text).textSelection(.enabled)
        }
    }
}

struct RenameSheet: View {
    let model: CatalogModel
    @Bindable var draft: RenameDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename conversation").font(.system(size: 15, weight: .semibold))
            TextField("Title", text: $draft.text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
                .accessibilityLabel("Conversation title")
            HStack {
                Text("\(draft.text.count)/\(SessionCatalog.maxTitleLength)")
                    .foregroundStyle(draft.text.count > SessionCatalog.maxTitleLength
                                     ? CatalogTheme.failure : CatalogTheme.secondary)
                Text("Longer titles are shortened. An empty title returns to the automatic one.")
                    .foregroundStyle(CatalogTheme.secondary)
            }
            .font(.system(size: 11))
            if let failure = draft.failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(CatalogTheme.failure)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.renameDraft = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(draft.saving)
            }
        }
        .padding(20)
        .frame(width: 420)
        .preferredColorScheme(.dark)
    }

    private func save() {
        Task { await model.commitRename() }
    }
}
