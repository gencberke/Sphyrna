import LoomCore
import SwiftUI

/// A history record without a live terminal. It states plainly what is not
/// connected yet; nothing here can start a provider or a PTY.
struct ConversationDetail: View {
    let model: CatalogModel
    let row: SessionRowModel
    /// Shown as the Chat's fallback: the chat view already draws the requests above and, for a session without a
    /// terminal, the notice with Resume, so this screen leaves both out rather than draw them twice (a second
    /// request list would be a second Approve on the same question).
    var inChat = false

    nonisolated static func showsRequests(inChat: Bool) -> Bool { !inChat }

    /// What Resume does, in the provider's own name.
    nonisolated static func resumeExplanation(provider: String) -> String {
        "Resume continues this \(provider) session in its folder. If \(provider) no longer has it, Sphyrna says so."
    }
    nonisolated static func showsResume(inChat: Bool, hasTerminal: Bool) -> Bool { !inChat || hasTerminal }

    /// The state line above the actions. It states what Loom knows: a pending
    /// start, resume or stop; no run; a run without a terminal here; or that
    /// actions are not available right now (for example while quitting).
    /// The record waits for a run to start: Starting… or Resuming….
    nonisolated static func showsStartingArt(busy: ConversationBusy?) -> Bool { busy == .starting || busy == .resuming }

    nonisolated static func runStateHeading(busy: ConversationBusy?, canResume: Bool, isRunning: Bool) -> String {
        switch busy {
        case .starting: "Starting…"
        case .resuming: "Resuming…"
        case .stopping: "Stopping…"
        case nil: canResume ? "Not running" : isRunning ? "Running" : "Not available right now"
        }
    }

    /// What the record says first, when the state has something to say: the state pill's long form (DESIGN §19 The record), so the
    /// two always agree. A session that is simply not running has none.
    nonisolated static func notice(for indicator: SessionIndicator, provider: String) -> RecordNotice? {
        switch indicator {
        case .stopUnverified(let message):
            RecordNotice(tone: .failure, symbol: "exclamationmark.triangle", title: "Stop could not be verified", text: message)
        case .problem(let message):
            RecordNotice(tone: .failure, symbol: "exclamationmark.triangle", title: "This session has a problem", text: message)
        case .identityUnclear:
            RecordNotice(tone: .attention, symbol: "questionmark.diamond", title: "Session identity is not certain",
                         text: "Sphyrna could not tell which \(provider) session this is, so it changed nothing.")
        case .failed(let message):
            RecordNotice(tone: .failure, symbol: "exclamationmark.triangle", title: "\(provider) reported a failure",
                         text: message ?? "No details were provided.")
        case .unviewedCompletion:
            RecordNotice(tone: .unviewed, symbol: "checkmark.circle", title: "Finished while you were away",
                         text: "\(provider) reported a completed turn.")
        default: nil
        }
    }

    enum Part: Equatable { case notice, state, facts }

    /// The record top to bottom: the notice when the state has one, then "Not running", what Resume does and the buttons, then
    /// the facts in a card. There is no title block; the header holds the title.
    nonisolated static func sections(for indicator: SessionIndicator) -> [Part] {
        (notice(for: indicator, provider: "") == nil ? [] : [.notice]) + [.state, .facts]
    }

    /// Whether the Status fact draws the state's mark before its word.
    nonisolated static func statusDrawsMark(_ indicator: SessionIndicator) -> Bool {
        switch indicator {
        case .ready, .idle, .stale, .ended, .working: false
        default: true
        }
    }

    var body: some View {
        let indicator = row.indicator
        let provider = ProviderName.title(row.record.session.provider)
        VStack(spacing: 0) {
            if Self.showsRequests(inChat: inChat) { RequestList(model: model, row: row) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.sections(for: indicator), id: \.self) { part in
                        switch part {
                        case .notice:
                            if let notice = Self.notice(for: indicator, provider: provider) {
                                Notice(notice).padding(.bottom, LoomTheme.Edges.noticeBottom)
                            }
                        case .state: state(provider: provider)
                        case .facts: facts(indicator: indicator, provider: provider).padding(.top, LoomTheme.Edges.factsTop)
                        }
                    }
                }
                .frame(maxWidth: LoomTheme.Edges.recordColumn, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, LoomTheme.Edges.recordPaddingTop).padding(.horizontal, LoomTheme.Edges.recordPaddingH)
                .padding(.bottom, LoomTheme.Edges.recordPaddingBottom)
            }
        }
    }

    /// "Not running", what Resume does (or why it cannot) and the buttons.
    private func state(provider: String) -> some View {
        let record = row.record
        let busy = model.busy[row.id]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LoomTheme.Edges.stateHeadingGap) {
                Text(Self.runStateHeading(busy: busy, canResume: model.canResume(row), isRunning: row.live?.runID != nil))
                    .font(LoomTheme.Edges.stateHeading).foregroundStyle(LoomTheme.Text.primary)
            }
            Text(model.resumeUnavailableReason(row) ?? Self.resumeExplanation(provider: provider))
                .font(LoomTheme.Edges.stateText).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, LoomTheme.Edges.stateTextTop)
            HStack(spacing: LoomTheme.Edges.stateActionsGap) {
                if Self.showsResume(inChat: inChat, hasTerminal: model.isRunning(row)) {
                    Button(EndedScreenNotice.resumeTitle(stale: record.lifecycle == .stale)) {
                        model.resumeConversation(row.id)
                    }
                    .disabled(!model.canResume(row))
                    .buttonStyle(ControlButtonStyle(kind: .default))
                    .onAppear { SidebarRenderProbe.appeared("resume", session: row.id) }
                    .onDisappear { SidebarRenderProbe.disappeared("resume", session: row.id) }
                }
                // Stop only where a run can be stopped; a session that is not running has nothing to stop.
                if model.canStop(row) {
                    Button("Stop") { model.stopConversation(row.id) }
                        .buttonStyle(ControlButtonStyle(kind: .outline))
                        .accessibilityIdentifier("record-stop")
                }
                Button("Rename…") { model.beginRename(row.id) }
                    .buttonStyle(ControlButtonStyle(kind: .outline))
            }
            .padding(.top, LoomTheme.Edges.stateActionsTop)
        }
    }

    /// The facts in a card raised 1 at radius 12: a 150 label column, rules between the rows, mono for the folder and the ID.
    private func facts(indicator: SessionIndicator, provider: String) -> some View {
        let record = row.record
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Edges.factsRadius)
        return VStack(spacing: 0) {
            Fact("Status") {
                if Self.statusDrawsMark(indicator) { IndicatorView(indicator: indicator).fixedSize() }
                FactText(indicator.label ?? (record.lifecycle == .active ? "Not running" : "—"))
            }
            FactRule()
            Fact("Project") {
                if let mark = model.headerProjectMark(of: record) { ProjectMarkView(name: mark.name, tone: mark.tone) }
                FactText(model.projectName(for: record) ?? "No project")
            }
            if let origin = model.origin(of: row) {
                FactRule()
                Fact("Opened by", origin.factValue)
            }
            FactRule()
            Fact("Working directory", record.session.workingDirectory, mono: true, truncation: .middle)
            FactRule()
            Fact("\(provider) session ID", record.session.providerConversationID ?? "Not assigned yet", mono: true)
            FactRule()
            Fact("Created", LoomDateFormat.dateTime(record.createdAt))
            FactRule()
            Fact("Last activity", LoomDateFormat.dateTime(record.lastActivityAt))
            FactRule()
            Fact("Last used", LoomDateFormat.dateTime(record.lastUsedAt))
        }
        .background(shape.fill(LoomTheme.Surface.raised1))
        .overlay(shape.strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
        .depth(LoomTheme.Elevation.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("record-facts")
    }
}

/// What the record says first (DESIGN §19 The record): the state pill's long form.
struct RecordNotice: Equatable {
    enum Tone: Equatable { case failure, attention, unviewed }

    let tone: Tone
    let symbol: String
    let title: String
    let text: String
}

/// The record's notice: the state's wash at 10 % and its edge at 30 %, the symbol in the tone's text colour, a 13 semibold title in
/// primary and one sentence in secondary.
struct Notice: View {
    let content: RecordNotice

    init(_ content: RecordNotice) { self.content = content }

    private var hue: Color {
        switch content.tone {
        case .failure: LoomTheme.Status.failure
        case .attention: LoomTheme.Status.attention
        case .unviewed: LoomTheme.Status.unviewed
        }
    }

    private var symbolColor: Color {
        switch content.tone {
        case .failure: LoomTheme.Status.failureLight
        case .attention: LoomTheme.Status.attentionLight
        case .unviewed: LoomTheme.Status.unviewedLight
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Edges.noticeRadius)
        HStack(alignment: .top, spacing: LoomTheme.Edges.noticeGap) {
            Image(systemName: content.symbol).font(LoomTheme.Edges.noticeSymbol).foregroundStyle(symbolColor)
                .frame(width: LoomTheme.Edges.noticeSymbolSlot).padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LoomTheme.Edges.noticeRowGap) {
                Text(content.title).font(LoomTheme.Edges.noticeTitle).foregroundStyle(LoomTheme.Text.primary)
                Text(content.text).font(LoomTheme.Edges.noticeText).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, LoomTheme.Edges.noticePaddingTop).padding(.horizontal, LoomTheme.Edges.noticePaddingH)
        .padding(.bottom, LoomTheme.Edges.noticePaddingBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(hue.opacity(LoomTheme.Edges.noticeWashOpacity)))
        .overlay(shape.strokeBorder(hue.opacity(LoomTheme.Edges.noticeEdgeOpacity), lineWidth: LoomTheme.Line.hairline))
        .accessibilityElement(children: .contain)
    }
}

/// A value in the facts card: 12.5 primary, or mono 11.5 for the folder and the ID; one line, cut at its end (or in the middle for
/// a path), selectable.
struct FactText: View {
    let text: String
    var mono = false
    var truncation: Text.TruncationMode = .tail

    init(_ text: String, mono: Bool = false, truncation: Text.TruncationMode = .tail) {
        self.text = text
        self.mono = mono
        self.truncation = truncation
    }

    var body: some View {
        Text(text).font(mono ? LoomTheme.Edges.factMono : LoomTheme.Edges.factFont)
            .foregroundStyle(LoomTheme.Text.primary).lineLimit(1).truncationMode(truncation)
            .textSelection(.enabled).help(text)
    }
}

/// One row of the facts card: the label in a 150 column in secondary, then the value, 12 apart, 9 and 16 inside.
struct Fact<Value: View>: View {
    let name: String
    @ViewBuilder let value: Value

    init(_ name: String, @ViewBuilder value: () -> Value) {
        self.name = name
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Edges.factGap) {
            Text(name).font(LoomTheme.Edges.factFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .frame(width: LoomTheme.Edges.factLabelWidth, alignment: .leading)
            HStack(spacing: LoomTheme.Edges.factValueGap) { value }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, LoomTheme.Edges.factRowPaddingV).padding(.horizontal, LoomTheme.Edges.factRowPaddingH)
    }
}

extension Fact where Value == FactText {
    init(_ name: String, _ text: String, mono: Bool = false, truncation: Text.TruncationMode = .tail) {
        self.init(name) { FactText(text, mono: mono, truncation: truncation) }
    }
}

/// The 1 pt rule between two rows of the facts card.
struct FactRule: View {
    var body: some View {
        Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline).accessibilityHidden(true)
    }
}
