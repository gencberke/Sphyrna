import LoomCore
import LoomRemora
import SwiftUI

// The field with its scope, Send and Stop, the answer under it, the Earlier line (DESIGN §20; the reference's `.askr`, `.rans`,
// `.rchip` and `.rearly`).

private typealias R = LoomTheme.Remora

/// The field's surface: raised 2, radius 15, the composer's ring and its shadow (level 2, the composer card at the field's radius).
private struct HomeRemoraFieldSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let depth = LoomTheme.Composer.depth[LoomTheme.Appearance(scheme)]
        let shape = RoundedRectangle(cornerRadius: R.fieldRadius)
        content
            .background { shape.fill(LoomTheme.Composer.fill).depth(LoomTheme.Composer.depth) }
            .overlay {
                if let ring = depth.ring { shape.strokeBorder(ring.color, lineWidth: LoomTheme.Line.hairline).allowsHitTesting(false) }
            }
    }
}

/// "Ask Remora about your sessions". ↵ asks, Esc stops and ↑ in the empty field brings back the last question; the field takes those keys
/// only while it is focused, through its own key handling (no default or cancel action, so a pinned card's keys stay its own).
struct HomeRemoraFieldBlock: View {
    let model: CatalogModel
    let ui: HomeRemoraUI
    let reads: HomeRemoraReads
    let context: HomeRemoraContext
    let topGap: CGFloat
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var ui = ui
        let busy = model.remora.isBusy
        HStack(spacing: R.fieldGap) {
            TextField("", text: $ui.text, prompt: Text(HomeRemoraText.fieldPlaceholder).foregroundStyle(LoomTheme.Text.faint))
                .textFieldStyle(.plain)
                .homeType(R.fieldText)
                .foregroundStyle(LoomTheme.Text.primary)
                .focused($focused)
                .onKeyPress(phases: [.down, .repeat]) { press in handle(press, busy: busy) }
                .accessibilityLabel("Ask Remora")
                .accessibilityIdentifier("home-remora-field")
            scopeChip
            if busy { stopButton } else { sendButton }
        }
        .padding(.leading, R.fieldLeading).padding(.trailing, R.fieldTrailing)
        .frame(height: R.fieldHeight)
        .modifier(HomeRemoraFieldSurface())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-remora-field-bar")
        .padding(.top, topGap)
        .tint(LoomTheme.Accent.base)
    }

    // MARK: Keys

    /// The question ↑ brings back: the last one sent in this Home, else the last answer's.
    private var lastQuestion: String? { ui.asked?.question ?? model.remora.lastAnswer?.question }

    private func handle(_ press: KeyPress, busy: Bool) -> KeyPress.Result {
        guard press.modifiers.isEmpty else { return .ignored }
        let key: HomeRemoraFieldKeys.Key
        switch press.key {
        case .return: key = .return
        case .escape: key = .escape
        case .upArrow: key = .up
        default: return .ignored
        }
        let outcome = HomeRemoraFieldKeys.resolve(key, text: ui.text, busy: busy, lastQuestion: lastQuestion)
        switch outcome.action {
        case .ask(let question): HomeRemoraCalls.ask(model, ui: ui, question)
        case .stop: model.stopRemora()
        case .recall(let question): ui.text = question
        case .nothing: break
        }
        return outcome.handled ? .handled : .ignored
    }

    // MARK: Parts

    private var scopeItems: [HomeRemoraMenuItem] {
        let excluded = model.remora.preferences.excludedProjects
        var rows = [HomeRemoraMenuItem(id: "all", title: HomeRemoraText.allProjects, checked: ui.scope == .allProjects,
                                       action: { ui.scope = .allProjects })]
        for (index, project) in model.projects.filter({ !excluded.contains($0.id) }).enumerated() {
            rows.append(HomeRemoraMenuItem(id: project.id.uuidString, title: project.name, mark: .project(name: project.name, tone: project.tone),
                                           checked: ui.scope == .project(project.id), dividerAbove: index == 0,
                                           action: { ui.scope = .project(project.id) }))
        }
        return rows
    }

    private var scopeTitle: String {
        if case .project(let id) = ui.scope, let name = model.projects.first(where: { $0.id == id })?.name { return name }
        return HomeRemoraText.allProjects
    }

    private var scopeChip: some View {
        let isOpen = ui.binding(.scope)
        return Button { isOpen.wrappedValue.toggle() } label: {
            HStack(spacing: R.scopeGap) {
                Text(scopeTitle).homeType(R.scopeText).lineLimit(1)
                Image(systemName: "chevron.down").font(R.scopeChevronGlyph.font)
                    .foregroundStyle(LoomTheme.Text.tertiaryStyle).accessibilityHidden(true)
            }
        }
        .buttonStyle(ComposerChipStyle())
        .fixedSize()
        .accessibilityLabel("Scope: \(scopeTitle)")
        .accessibilityHint("Opens a menu")
        .accessibilityIdentifier("home-remora-scope")
        .inkPopover(isPresented: isOpen, id: "home-remora-scope", label: "Scope", side: .above, alignment: .trailing, keys: { key in
            let items = scopeItems
            let outcome = HomeRemoraMenuKeys.resolve(key, cursor: ui.cursor, count: items.count)
            ui.cursor = outcome.cursor
            if let use = outcome.use {
                items[use].action()
                isOpen.wrappedValue = false
            }
            return outcome.handled
        }, content: {
            HomeRemoraMenuView(items: scopeItems, width: R.scopeMenuWidth, cursor: ui.cursor, hover: { ui.cursor = $0 },
                               close: { isOpen.wrappedValue = false })
        })
    }

    private var sendButton: some View {
        let question = ui.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Button { HomeRemoraCalls.ask(model, ui: ui, question) } label: {
            Image(systemName: "arrow.up").font(R.sendGlyph.font)
                .foregroundStyle(LoomTheme.Composer.sendOnDiscGlyph)
                .frame(width: R.sendSide, height: R.sendSide)
                .background(Circle().fill(question.isEmpty ? LoomTheme.Composer.sendOffFill : LoomTheme.Composer.sendReadyFill))
        }
        .buttonStyle(.plain)
        .disabled(question.isEmpty)
        .accessibilityLabel("Ask")
        .accessibilityIdentifier("home-remora-send")
    }

    private var stopButton: some View {
        Button { model.stopRemora() } label: {
            HStack(spacing: R.stopGap) {
                RoundedRectangle(cornerRadius: R.stopSquareRadius).frame(width: R.stopSquare, height: R.stopSquare)
                Text("Stop").homeType(R.stopText)
            }
            .foregroundStyle(LoomTheme.Text.primary)
            .padding(.horizontal, R.stopPadding)
            .frame(height: R.stopHeight)
            .overlay(RoundedRectangle(cornerRadius: R.stopRadius)
                .strokeBorder(LoomTheme.Surface.strongHairline, lineWidth: LoomTheme.Line.hairline))
            .contentShape(RoundedRectangle(cornerRadius: R.stopRadius))
        }
        .buttonStyle(.plain)
        .help("Stop \u{00B7} esc")
        .accessibilityLabel("Stop")
        .accessibilityIdentifier("home-remora-stop")
    }
}

// MARK: The answer

/// The answer under the field, one at a time, and the Earlier line.
struct HomeRemoraAnswerBlock: View {
    let model: CatalogModel
    let ui: HomeRemoraUI
    let reads: HomeRemoraReads
    let context: HomeRemoraContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let asked = ui.asked, !ui.answerClosed, let content = HomeRemoraAnswerContent.make(model: model, asked: asked, baselineUndo: reads.baselineUndo) {
                HomeRemoraAnswerCard(model: model, ui: ui, reads: reads, asked: asked, content: content)
                    .padding(.top, R.answerTop)
            }
            if let earlier = ui.earlier {
                HomeRemoraEarlier(ui: ui, earlier: earlier).padding(.top, R.earlierTop)
            }
        }
    }
}

/// What the answer card shows, from the model's state and the question asked. Plain values.
struct HomeRemoraAnswerContent: Equatable {
    enum Body: Equatable {
        /// Reading, then the words as they come.
        case working(reading: RemoraReading?, text: String)
        case failed(RemoraFailure.Kind)
        case stopped(text: String)
        case answered(HomeRemoraAnswerFacts)
        /// "Remember …" saved at once, with no call.
        case remembered(String)
        case notSaved(String)
    }

    let body: Body

    @MainActor
    static func make(model: CatalogModel, asked: HomeRemoraUI.Asked, baselineUndo: RemoraUndoToken?) -> HomeRemoraAnswerContent? {
        let remora = model.remora
        // The call's progress, failure and stop show here only for Home's own question (a ⌘K question or a brief has its own place).
        if remora.call == RemoraModelState.Call(kind: .question, door: .home) {
            if remora.phase == .asking { return HomeRemoraAnswerContent(body: .working(reading: remora.reading, text: remora.streamedText)) }
            if let failure = remora.lastFailure { return HomeRemoraAnswerContent(body: .failed(failure)) }
            if remora.stopped == .question { return HomeRemoraAnswerContent(body: .stopped(text: remora.streamedText)) }
        }
        if let answer = remora.lastAnswer, answer.question == asked.question {
            return HomeRemoraAnswerContent(body: .answered(HomeRemoraAnswerFacts(answer)))
        }
        if let reason = remora.notSavedReason { return HomeRemoraAnswerContent(body: .notSaved(reason)) }
        if let fact = remora.lastRemembered, let undo = remora.lastUndo, undo != baselineUndo { return HomeRemoraAnswerContent(body: .remembered(fact)) }
        return nil
    }
}

/// An answered question as the card needs it.
struct HomeRemoraAnswerFacts: Equatable {
    let text: String
    let chips: [RemoraChip]
    let drafts: [RemoraDraft]
    let readSessionIDs: [UUID]
    let footer: String
    let duration: TimeInterval
    let tokens: Int

    init(_ answer: RemoraHostAnswer) {
        text = answer.answer.text
        chips = answer.answer.chips
        drafts = answer.answer.drafts
        readSessionIDs = answer.readSessionIDs
        footer = answer.footer
        duration = HomeRemoraText.seconds(answer.answer.duration)
        tokens = answer.answer.usage.total
    }
}

private struct HomeRemoraAnswerCard: View {
    let model: CatalogModel
    let ui: HomeRemoraUI
    let reads: HomeRemoraReads
    let asked: HomeRemoraUI.Asked
    let content: HomeRemoraAnswerContent
    @Environment(\.indicatorsAnimate) private var indicatorsAnimate

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Radius.block)
        VStack(alignment: .leading, spacing: 0) {
            header
            switch content.body {
            case .working(let reading, let text):
                if text.isEmpty {
                    HStack(spacing: R.readingGap) {
                        BrailleSpinner(animating: indicatorsAnimate).frame(width: LoomTheme.Layout.indicatorSlot.width).accessibilityHidden(true)
                        Text(HomeRemoraText.readingLine(reading)).homeType(R.working).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    }
                    .padding(.top, R.workingTop)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("home-remora-working")
                } else {
                    answerText(text)
                }
            case .failed(let kind):
                HStack(alignment: .firstTextBaseline, spacing: R.readingGap) {
                    Text(HomeRemoraText.failure(kind)).homeType(R.answerText).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                    if kind != .notLoggedIn {
                        Button(HomeRemoraText.tryAgain) { HomeRemoraCalls.ask(model, ui: ui, asked.question, retry: true) }
                            .buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
                            .accessibilityIdentifier("home-remora-try-again")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, R.answerTextTop)
                .accessibilityIdentifier("home-remora-failure")
            case .stopped(let text):
                if !text.isEmpty { answerText(text) }
                Text(HomeRemoraText.stoppedQuestion).homeType(R.working).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    .padding(.top, R.stoppedTop)
                    .accessibilityIdentifier("home-remora-stopped")
            case .answered(let facts):
                answerText(facts.text)
                chips(facts)
                foot(facts)
            case .remembered(let fact):
                HStack(spacing: R.proposalGap) {
                    Text("Remembered: \(fact)").homeType(R.answerText).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                    if let undo = model.remora.lastUndo {
                        Button("Undo") { model.undoRemora(undo) }
                            .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
                            .accessibilityIdentifier("home-remora-undo")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, R.answerTextTop)
            case .notSaved(let reason):
                Text(reason).homeType(R.answerText).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                    .padding(.top, R.answerTextTop)
            }
        }
        .padding(.horizontal, R.answerPaddingH).padding(.vertical, R.answerPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(LoomTheme.Surface.card))
        .overlay(shape.strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
        .depth(LoomTheme.Elevation.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-remora-answer")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: R.askedGap) {
            Text(HomeRemoraText.youAskedAt(asked.at)).homeType(R.asked).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            Text(asked.question).homeType(R.askedQuestion).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
            Spacer(minLength: 0)
            Button { ui.answerClosed = true } label: {
                Image(systemName: "xmark").font(R.closeGlyph.font).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .frame(width: R.closeSide, height: R.closeSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close answer")
            .accessibilityIdentifier("home-remora-close-answer")
        }
    }

    private func answerText(_ text: String) -> some View {
        Text(HomeRemoraMarkdown.attributed(text)).homeType(R.answerText).lineSpacing(R.answerLineSpacing)
            .foregroundStyle(LoomTheme.Text.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: R.answerMaxWidth, alignment: .leading)
            .padding(.top, R.answerTextTop)
            .accessibilityIdentifier("home-remora-answer-text")
    }

    /// The sessions the answer names that exist now, each a chip that opens the session; a draft sits beside its chip.
    @ViewBuilder
    private func chips(_ facts: HomeRemoraAnswerFacts) -> some View {
        let named = HomeRemoraAnswerChips.named(facts, model: model, reads: reads)
        if !named.isEmpty {
            FlowLayout(spacing: R.chipsGap, centered: false) {
                ForEach(named, id: \.0.id) { session, draft in
                    HStack(spacing: R.tileActionsGap) {
                        HomeRemoraChip(model: model, session: session)
                        if let draft {
                            HomeRemoraPutInDraft(model: model, ui: ui, reads: reads, sessionID: session.id, line: draft.text)
                        }
                    }
                }
            }
            .padding(.top, R.chipsTop)
        }
    }

    private func foot(_ facts: HomeRemoraAnswerFacts) -> some View {
        let sources = ui.binding(.answerSources)
        return HStack(spacing: R.footGap) {
            Text(HomeRemoraText.footer(facts.footer, duration: facts.duration)).homeType(R.foot).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .accessibilityIdentifier("home-remora-answer-footer")
            HomeRemoraLink(title: HomeRemoraText.sources, identifier: "home-remora-answer-sources") { sources.wrappedValue.toggle() }
                .homeType(R.footLink)
                .inkPopover(isPresented: sources, id: "home-remora-answer-sources", label: "Read for this answer", side: .above,
                            alignment: .leading, content: {
                    HomeRemoraSourcesView(model: model, reads: reads, label: HomeRemoraText.sourcesLabel(brief: false),
                                          sessionIDs: facts.readSessionIDs, tokens: facts.tokens, duration: facts.duration,
                                          close: { sources.wrappedValue = false })
                })
            Spacer(minLength: 0)
        }
        .padding(.top, R.answerFootTop)
    }
}

/// The sessions an answer names that exist now and whose project Remora may name, each with its draft line if it has one. Home's
/// answer and the palette's (⌘K) draw the same chips from it.
enum HomeRemoraAnswerChips {
    @MainActor
    static func named(_ facts: HomeRemoraAnswerFacts, model: CatalogModel, reads: HomeRemoraReads) -> [(HomeRemoraSession, RemoraDraft?)] {
        let excluded = model.remora.preferences.excludedProjects
        return facts.chips.compactMap { chip -> (HomeRemoraSession, RemoraDraft?)? in
            guard let id = UUID(uuidString: chip.sessionID), let record = reads.sessions[id], let session = model.homeRemoraSession(record)
            else { return nil }
            if let project = session.projectID, excluded.contains(project) { return nil }
            return (session, facts.drafts.first { $0.sessionID == chip.sessionID })
        }
    }
}

/// A session chip: the project's mark, the title and when, tinted with the project's tone; a click opens the session (`open` when
/// given: the palette closes first).
struct HomeRemoraChip: View {
    let model: CatalogModel
    let session: HomeRemoraSession
    var open: (@MainActor () -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: R.chipRadius)
        Button { if let open { open() } else { model.select(session.id) } } label: {
            HStack(spacing: R.chipGap) {
                if let name = session.projectName { ProjectMarkView(name: name, tone: session.tone, size: .chip) }
                Text(session.title).homeType(R.chipText).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                Text(RelativeTime.string(from: session.lastActivityAt, to: model.now)).homeType(R.chipWhen)
                    .foregroundStyle(LoomTheme.Text.tertiaryStyle)
                Image(systemName: "arrow.up.right").font(R.arrowGlyph.font)
                    .foregroundStyle(LoomTheme.Text.tertiaryStyle).accessibilityHidden(true)
            }
            .padding(.leading, R.chipPaddingLeading).padding(.trailing, R.chipPaddingTrailing)
            .frame(height: R.chipHeight)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(edge, lineWidth: LoomTheme.Line.hairline))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Open \(session.title)")
        .accessibilityIdentifier("home-remora-chip")
    }

    private var fill: Color {
        session.tone.map { LoomTheme.Remora.chipFillTone($0, hovering: hovering).color } ?? (hovering ? LoomTheme.Surface.hover : .clear)
    }

    private var edge: Color {
        session.tone.map { LoomTheme.Remora.chipEdgeTone($0).color } ?? LoomTheme.Surface.strongHairline
    }
}

/// "Earlier: <question> 11:20": the one line of history Home keeps; a click brings the question back to the field.
struct HomeRemoraEarlier: View {
    let ui: HomeRemoraUI
    let earlier: HomeRemoraUI.Asked

    var body: some View {
        Button { ui.text = earlier.question } label: {
            HStack(spacing: R.earlierGap) {
                Image(systemName: "chevron.right").font(R.chevronGlyph.font)
                    .foregroundStyle(LoomTheme.Text.tertiaryStyle).frame(width: R.chevron, height: R.chevron).accessibilityHidden(true)
                Text("Earlier:").homeType(R.earlier).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                Text(earlier.question).homeType(R.earlierQuestion).foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1)
                Text(HomeRemoraText.earlierTime(earlier.at)).homeType(R.earlierTime).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Earlier question: \(earlier.question)")
        .accessibilityHint("Brings the question back to the field")
        .accessibilityIdentifier("home-remora-earlier")
    }
}
