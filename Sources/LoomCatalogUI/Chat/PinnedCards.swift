import AppKit
import LoomChat
import LoomCore
import SwiftUI

// The pinned cards (V18, CHAT-SPEC → Requests): one card at a time above the composer, with the counter, the line an
// answered card folds to, the one-line notice of the typing guard, and the card a dead process cut off.

/// The stack between the stream and the composer. Empty, it is nothing at all.
private struct PinnedStackMaxHeight: EnvironmentKey { static let defaultValue: CGFloat? = nil }
extension EnvironmentValues {
    /// What the stack may take, so a card with a long body (a plan) can leave room for its buttons.
    fileprivate var pinnedStackMaxHeight: CGFloat? {
        get { self[PinnedStackMaxHeight.self] }
        set { self[PinnedStackMaxHeight.self] = newValue }
    }
}

struct PinnedCardsView: View {
    let cards: PinnedCardsModel
    /// The most the stack may take; past it the stack scrolls. Nil: no bound.
    var maxHeight: CGFloat?

    var body: some View {
        if !cards.isEmpty {
            ViewThatFits(in: .vertical) {
                PinnedStack(cards: cards)
                // "Show the request" scrolls this stack to the card, with no animation (the chat's own scroll is untouched).
                ScrollViewReader { proxy in
                    ScrollView(.vertical) { PinnedStack(cards: cards) }.scrollBounceBehavior(.basedOnSize)
                        .onChange(of: cards.revealCount) {
                            if let id = cards.revealedRequestID { proxy.scrollTo(id, anchor: .top) }
                        }
                }
            }
            .frame(maxHeight: maxHeight)
            .environment(\.pinnedStackMaxHeight, maxHeight)
            .frame(maxWidth: LoomTheme.Chat.column)
            .padding(.horizontal, LoomTheme.Pinned.stackPaddingH)
            .padding(.bottom, LoomTheme.Pinned.stackPaddingBottom)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("pinned-cards")
        }
    }
}

/// The stack of a session whose run ended: its transcript shows, and the cards the end cut off stay on screen until the next run.
struct EndedRunCards: View {
    let model: CatalogModel
    let sessionID: UUID
    var conversationID: String?
    var workingDirectory: String?
    /// The feed whose cards show, counted as a view while this one is on screen (`LiveChatFeed.endedViewAppeared`).
    @State private var feed: LiveChatFeed?

    var body: some View {
        Group {
            if let cards = feed?.cards {
                VStack(spacing: 0) {
                    if !cards.undelivered.isEmpty { EndedUndeliveredLine(texts: cards.undelivered) }
                    PinnedCardsView(cards: cards)
                }
            }
        }
        .onAppear {
            guard feed == nil, let driver = model.liveChatDriver(for: sessionID),
                  let made = model.liveChatFeed(for: driver, card: sessionID, conversationID: conversationID,
                                                workingDirectory: workingDirectory) else { return }
            feed = made
            made.endedViewAppeared()
        }
        .onDisappear {
            feed?.endedViewWentAway()
            feed = nil
        }
    }
}

/// The messages the process ended without reading (no composer is there until V19): one line, with Copy. The draft brings
/// them back when the session runs again.
struct EndedUndeliveredLine: View {
    let texts: [String]

    var body: some View {
        HStack(spacing: LoomTheme.Pinned.lineGap) {
            InkIcon(.exclamation, size: LoomTheme.Icon.navigation).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .accessibilityHidden(true)
            Text(verbatim: texts.count == 1 ? "Not delivered: 1 message" : "Not delivered: \(texts.count) messages")
                .font(LoomTheme.Pinned.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
            Text("It comes back in the composer when the session runs again.").font(LoomTheme.Pinned.detail)
                .foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1)
            Spacer(minLength: 0)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(texts.joined(separator: "\n\n"), forType: .string)
            }
            .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
        }
        .padding(.horizontal, LoomTheme.Pinned.linePaddingH)
        .frame(minHeight: LoomTheme.Pinned.lineHeight)
        .pinnedSurface(radius: LoomTheme.Pinned.lineRadius, fill: LoomTheme.Pinned.lineFill,
                       edge: AnyShapeStyle(LoomTheme.Surface.strongHairline))
        .frame(maxWidth: LoomTheme.Chat.column)
        .padding(.horizontal, LoomTheme.Pinned.stackPaddingH).padding(.bottom, LoomTheme.Pinned.stackPaddingBottom)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ended-undelivered")
    }
}

private struct PinnedStack: View {
    let cards: PinnedCardsModel

    var body: some View {
        VStack(spacing: LoomTheme.Pinned.stackSpacing) {
            if let folded = cards.folded { PinnedFoldedLine(folded: folded) }
            ForEach(cards.cutOff) { settled in PinnedCutOffCard(cards: cards, settled: settled) }
            if let request = cards.current {
                if cards.isHeld {
                    PinnedHeldLine(cards: cards)
                } else {
                    PinnedCard(cards: cards, request: request).id(request.requestID)
                }
            }
        }
    }
}

/// The card of the request shown, by kind.
struct PinnedCard: View {
    let cards: PinnedCardsModel
    let request: ChatPendingRequest

    var body: some View {
        switch request.kind {
        case .approval: PinnedApprovalCard(cards: cards, request: request)
        case .question: PinnedQuestionCard(cards: cards, request: request)
        case .plan: PinnedPlanCard(cards: cards, request: request)
        }
    }
}


// MARK: Approval

struct PinnedApprovalCard: View {
    let cards: PinnedCardsModel
    let request: ChatPendingRequest

    var body: some View {
        let content = cards.content(for: request)
        let busy = cards.answering.contains(request.requestID) || cards.isStopping
        let actions = self.actions(busy: busy)
        PinnedCardChrome(cards: cards, mark: .dot, title: content.title, kind: content.kindLabel,
                         failure: cards.failures[request.requestID]) {
            if let agent = content.agentLine {
                Text(verbatim: agent).font(LoomTheme.Pinned.kind).foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1)
                    .accessibilityIdentifier("pinned-agent")
            }
            PinnedCodeBlock(lines: content.lines, prompt: content.kind == .command ? "$" : nil)
            if content.claudeSays != nil || content.reason != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let says = content.claudeSays {
                        Text(Self.claudeSays(says)).lineSpacing(Self.saysLineSpacing).accessibilityIdentifier("pinned-says")
                    }
                    if let reason = content.reason {
                        Text(verbatim: reason).font(LoomTheme.Pinned.detail).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                            .accessibilityIdentifier("pinned-reason")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            // The mono hint goes first when the row is narrow, then the buttons stack under the menu.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: LoomTheme.Pinned.buttonSpacing) {
                    moreMenu(busy: busy)
                    PinnedHint(text: PinnedCopy.approvalHint)
                    Spacer(minLength: LoomTheme.Pinned.buttonSpacing)
                    PinnedButtonRow(actions: actions, focused: cards.focusedIndex)
                }
                HStack(spacing: LoomTheme.Pinned.buttonSpacing) {
                    moreMenu(busy: busy)
                    Spacer(minLength: LoomTheme.Pinned.buttonSpacing)
                    PinnedButtonRow(actions: actions, focused: cards.focusedIndex)
                }
                VStack(alignment: .trailing, spacing: LoomTheme.Pinned.buttonSpacing) {
                    HStack { moreMenu(busy: busy); Spacer(minLength: 0) }
                    PinnedButtonRow(actions: actions, focused: cards.focusedIndex)
                }
            }
            .pinnedKeys(cards: cards, kind: .approval, actions: actions, focusedIndex: cards.focusedBinding)
        }
    }

    private static let saysLineSpacing = LoomTheme.Chat.lineSpacing(size: 12.5, mono: false, lineHeight: LoomTheme.Pinned.saysLineHeight)

    /// "Claude: <its own words>", the label in the primary tone and the words in the secondary.
    static func claudeSays(_ says: String) -> AttributedString {
        var label = AttributedString("Claude: ")
        label.font = LoomTheme.Pinned.saysLabel
        label.foregroundColor = LoomTheme.Text.primary
        var words = AttributedString(says)
        words.font = LoomTheme.Pinned.body
        words.foregroundColor = LoomTheme.Text.secondary
        label.append(words)
        return label
    }

    private func actions(busy: Bool) -> [PinnedAction] {
        var list = [
            PinnedAction(id: "deny", title: "Deny", isEnabled: !busy) { Task { await cards.deny(request) } },
            PinnedAction(id: "once", title: "Allow Once", isEnabled: !busy) { Task { await cards.allowOnce(request) } },
        ]
        if cards.offersSessionGrants, request.canAllowForSession {
            // The words of the CLI's own button, in Title Case at the call site (LoomChat keeps its sentence).
            list.append(PinnedAction(id: "session", title: PinnedCopy.titleCase(request.sessionButtonTitle), isEnabled: !busy) {
                Task { await cards.allowForSession(request) }
            })
        }
        return list
    }

    private func moreMenu(busy: Bool) -> some View {
        PinnedMoreMenu(busy: busy) {
            Button("Deny and Stop", systemImage: "stop.fill", role: .destructive) { Task { await cards.denyAndStop(request) } }
        }
    }
}

// MARK: Question

struct PinnedQuestionCard: View {
    let cards: PinnedCardsModel
    let request: ChatPendingRequest

    var body: some View {
        let questions = request.questions
        let draft = cards.draft(for: request)
        let busy = cards.answering.contains(request.requestID) || cards.isStopping
        let step = min(draft.step, max(questions.count - 1, 0))
        let isLast = step >= questions.count - 1
        let actions = self.actions(draft: draft, isLast: isLast, busy: busy)
        let optionCount = questions.indices.contains(step) ? questions[step].options.count : 0
        PinnedCardChrome(cards: cards, mark: .glyph("questionmark.circle"), title: "Claude asks",
                         kind: questions.indices.contains(step) ? questions[step].header : nil,
                         failure: cards.failures[request.requestID]) {
            if questions.indices.contains(step) {
                let question = questions[step]
                if questions.count > 1 {
                    Text("Question \(step + 1) of \(questions.count)").font(LoomTheme.Pinned.kind).foregroundStyle(LoomTheme.Text.secondaryStyle)
                }
                Text(Self.questionText(question.question))
                    .lineSpacing(Self.questionLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("pinned-question")
                if question.multiSelect {
                    Text("Select one or more").font(LoomTheme.Pinned.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                }
                ScrollView(.vertical) {
                    VStack(spacing: LoomTheme.Pinned.optionSpacing) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                            optionRow(option, number: index + 1, isOn: draft.picks[step].contains(option.label), busy: busy) {
                                cards.pick(option: index, in: request)
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: LoomTheme.Pinned.optionsMaxHeight)
                if let typed = draft.other[step], !typed.isEmpty {
                    Text(verbatim: "Your answer: \(typed)").font(LoomTheme.Pinned.body).foregroundStyle(LoomTheme.Text.primary)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: LoomTheme.Pinned.buttonSpacing) {
                    moreMenu(busy: busy)
                    PinnedHint(text: PinnedCopy.questionHint(optionCount: optionCount))
                    Spacer(minLength: LoomTheme.Pinned.buttonSpacing)
                    PinnedButtonRow(actions: actions, focused: cards.focusedIndex)
                }
                HStack(spacing: LoomTheme.Pinned.buttonSpacing) {
                    moreMenu(busy: busy)
                    Spacer(minLength: LoomTheme.Pinned.buttonSpacing)
                    PinnedButtonRow(actions: actions, focused: cards.focusedIndex)
                }
            }
            .pinnedKeys(cards: cards, kind: .question, actions: actions, focusedIndex: cards.focusedBinding) { index in
                cards.pick(option: index, in: request)
            }
        }
    }

    private static let questionLineSpacing = LoomTheme.Chat.lineSpacing(size: 13, mono: false, lineHeight: LoomTheme.Pinned.questionLineHeight)

    /// The question in 13 pt primary; the CLI writes it as plain text with, at most, inline Markdown.
    static func questionText(_ text: String) -> AttributedString {
        var out = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        out.font = LoomTheme.Pinned.question
        out.foregroundColor = LoomTheme.Text.primary
        return out
    }

    private func moreMenu(busy: Bool) -> some View {
        PinnedMoreMenu(busy: busy) {
            Button("Stop This Turn", systemImage: "stop.fill", role: .destructive) { Task { await cards.denyAndStop(request) } }
        }
    }

    private func actions(draft: PinnedQuestionDraft, isLast: Bool, busy: Bool) -> [PinnedAction] {
        var list: [PinnedAction] = []
        if draft.step > 0 { list.append(PinnedAction(id: "back", title: "Back", isEnabled: !busy) { cards.back(in: request) }) }
        if isLast {
            list.append(PinnedAction(id: "submit", title: "Submit", style: .accent, isEnabled: !busy && cards.canSubmit(request)) {
                Task { await cards.submit(request) }
            })
        } else {
            let answered = draft.isAnswered(draft.step) || !cards.note.trimmed.isEmpty
            list.append(PinnedAction(id: "next", title: "Next", isEnabled: !busy && answered) { cards.next(in: request) })
        }
        return list
    }

    private func optionRow(_ option: ChatQuestion.Option, number: Int, isOn: Bool, busy: Bool,
                           pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(alignment: .top, spacing: LoomTheme.Pinned.optionGap) {
                Text(verbatim: "\(number)").font(LoomTheme.Pinned.optionNumberFont)
                    .foregroundStyle(isOn ? AnyShapeStyle(LoomTheme.Accent.onAccent) : AnyShapeStyle(LoomTheme.Text.tertiaryStyle))
                    .frame(width: LoomTheme.Pinned.optionNumber.width, height: LoomTheme.Pinned.optionNumber.height)
                    .background(RoundedRectangle(cornerRadius: LoomTheme.Pinned.optionNumberRadius)
                        .fill(isOn ? LoomTheme.Pinned.optionNumberFill : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: LoomTheme.Pinned.optionNumberRadius)
                        .strokeBorder(LoomTheme.Surface.strongHairline).opacity(isOn ? 0 : 1))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: option.label).font(LoomTheme.Pinned.optionLabel).foregroundStyle(LoomTheme.Text.primary)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(verbatim: detail).font(LoomTheme.Pinned.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                            .lineSpacing(Self.optionDetailSpacing).fixedSize(horizontal: false, vertical: true)
                    }
                    if let preview = option.preview, !preview.isEmpty {
                        Text(verbatim: preview).font(LoomTheme.Pinned.mono).foregroundStyle(LoomTheme.Chat.output).lineLimit(6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, LoomTheme.Pinned.optionPaddingTop).padding(.bottom, LoomTheme.Pinned.optionPaddingBottom)
            .padding(.leading, LoomTheme.Pinned.optionPaddingLeading).padding(.trailing, LoomTheme.Pinned.optionPadding)
        }
        .buttonStyle(PinnedOptionStyle(isOn: isOn))
        .disabled(busy)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private static let optionDetailSpacing = LoomTheme.Chat.lineSpacing(size: 12, mono: false, lineHeight: LoomTheme.Pinned.optionDetailLineHeight)
}

/// An option of a question: radius 8 with a strong hairline, the hover fill under the pointer, the accent wash and a 55 %
/// accent edge once picked.
private struct PinnedOptionStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, isOn: isOn)
    }

    private struct Styled: View {
        let configuration: ButtonStyle.Configuration
        let isOn: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: LoomTheme.Pinned.optionRadius)
            let active = enabled && (hovering || configuration.isPressed)
            configuration.label
                .background(shape.fill(isOn ? LoomTheme.Pinned.optionSelectedFill : (active ? LoomTheme.Pinned.optionHoverFill : Color.clear)))
                .overlay(shape.strokeBorder(isOn ? AnyShapeStyle(LoomTheme.Pinned.optionSelectedEdge)
                    : AnyShapeStyle(active ? LoomTheme.Surface.strongerHairline : LoomTheme.Surface.strongHairline),
                                            lineWidth: LoomTheme.Line.hairline))
                .contentShape(shape)
                .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: Plan

struct PinnedPlanCard: View {
    let cards: PinnedCardsModel
    let request: ChatPendingRequest
    @Environment(\.pinnedStackMaxHeight) private var stackMaxHeight

    var body: some View {
        let plan = request.plan
        let bodyHeight = stackMaxHeight.map {
            min(LoomTheme.Pinned.planBodyMaxHeight, max(LoomTheme.Pinned.planBodyMinHeight, $0 - LoomTheme.Pinned.planChromeAllowance))
        } ?? LoomTheme.Pinned.planBodyMaxHeight
        let busy = cards.answering.contains(request.requestID) || cards.isStopping
        let mode = cards.planMode(for: request)
        let expanded = cards.expandedPlans.contains(request.requestID)
        let actions = self.actions(mode: mode, busy: busy)
        PinnedCardChrome(cards: cards, mark: .glyph("list.bullet.rectangle"), title: "Build this plan?", kind: "Claude waits in plan mode",
                         failure: cards.failures[request.requestID]) {
            if let plan {
                let long = ChatPlanCardView.isLong(plan.markdown)
                let shown = ChatPlanCardView.visibleText(plan.markdown, expanded: expanded || !long)
                // The plan's text stays in the card (DESIGN §12); it gives way to the buttons in a short window.
                ScrollView(.vertical) {
                    ChatMarkdownView(blocks: ChatContent.blocks(id: request.requestID, text: shown, isStreaming: false),
                                     flags: [], rowID: request.requestID, context: cards.context)
                        .padding(LoomTheme.Pinned.planPadding)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: bodyHeight)
                .pinnedSurface(radius: LoomTheme.Pinned.codeRadius, fill: LoomTheme.Pinned.codeFill,
                               edge: AnyShapeStyle(LoomTheme.Surface.hairlineStyle))
                .accessibilityIdentifier("pinned-plan")
                HStack(spacing: LoomTheme.Pinned.buttonSpacing) {
                    if let path = plan.filePath {
                        Text(verbatim: "Saved to \(path)").font(LoomTheme.Pinned.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: LoomTheme.Pinned.buttonSpacing)
                    if long {
                        ChatLinkButton(title: expanded ? "Show Less" : "Show Full Plan", prominent: true, identified: false) {
                            cards.togglePlanExpanded(request)
                        }
                    }
                }
            }
            // One row when it fits; else the modes to continue in above, Keep Planning and Approve below (the labels never cut).
            let modes = Array(actions.prefix(cards.askIsOn ? 0 : PinnedCardsModel.planModeChoices.count))
            let decisions = Array(actions.dropFirst(modes.count))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: LoomTheme.Pinned.buttonSpacing) {
                    then
                    Spacer(minLength: LoomTheme.Pinned.buttonSpacing)
                    PinnedButtonRow(actions: actions, focused: cards.focusedIndex)
                }
                VStack(alignment: .trailing, spacing: LoomTheme.Pinned.buttonSpacing) {
                    HStack(spacing: LoomTheme.Pinned.buttonSpacing) {
                        then
                        Spacer(minLength: LoomTheme.Pinned.buttonSpacing)
                        PinnedButtonRow(actions: modes, focused: cards.focusedIndex)
                    }
                    PinnedButtonRow(actions: decisions, focused: cards.focusedIndex, firstIndex: modes.count)
                }
            }
            .pinnedKeys(cards: cards, kind: .plan, actions: actions, focusedIndex: cards.focusedBinding)
        }
    }

    /// "Then" before the build modes, or the note that Ask keeps the plan in Ask.
    private var then: some View {
        Text(cards.askIsOn ? "Stays in Ask" : "Then").font(LoomTheme.Pinned.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
    }

    private func actions(mode: String, busy: Bool) -> [PinnedAction] {
        // In Ask the plan is approved in Ask: no mode to continue in.
        var list = (cards.askIsOn ? [] : PinnedCardsModel.planModeChoices).map { choice in
            PinnedAction(id: "mode-\(choice)", title: ChatModeNames.title(choice), style: .segment, isOn: choice == mode, isEnabled: !busy,
                         symbol: ComposerModeLook.symbol(forRaw: choice), tone: ComposerModeLook.color(forRaw: choice)) {
                cards.setPlanMode(choice, for: request)
            }
        }
        list.append(PinnedAction(id: "keep", title: "Keep Planning", isEnabled: !busy) { Task { await cards.keepPlanning(request) } })
        list.append(PinnedAction(id: "approve", title: "Approve", style: .accent, isEnabled: !busy) { Task { await cards.approvePlan(request) } })
        return list
    }
}

// MARK: Folded, held, cut off

/// An answered card, folded to one line: a check in the success text, the outcome in secondary and its subject in mono.
struct PinnedFoldedLine: View {
    let folded: PinnedCardsModel.Folded

    var body: some View {
        HStack(spacing: LoomTheme.Pinned.lineGap) {
            InkIcon(systemName: symbol, size: LoomTheme.Icon.body)
                .foregroundStyle(folded.outcome == .cancelled ? AnyShapeStyle(LoomTheme.Text.tertiaryStyle) : AnyShapeStyle(LoomTheme.Success.light))
                .frame(width: LoomTheme.Pinned.lineIcon).accessibilityHidden(true)
            summary
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LoomTheme.Pinned.linePaddingH)
        .frame(height: LoomTheme.Pinned.lineHeight)
        .frame(maxWidth: .infinity)
        .pinnedSurface(radius: LoomTheme.Pinned.lineRadius, fill: LoomTheme.Pinned.lineFill, edge: AnyShapeStyle(LoomTheme.Surface.hairlineStyle))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pinned-folded")
    }

    /// "Allowed once: rm -rf build": what happened, then what it was about in mono.
    @ViewBuilder private var summary: some View {
        if let split = Self.split(folded.summary) {
            HStack(spacing: 4) {
                Text(verbatim: split.what + ":").font(LoomTheme.Pinned.body).foregroundStyle(LoomTheme.Text.secondaryStyle).fixedSize()
                Text(verbatim: split.subject).font(LoomTheme.Pinned.mono).foregroundStyle(LoomTheme.Text.primary)
                    .lineLimit(1).truncationMode(.middle)
            }
        } else {
            Text(verbatim: folded.summary).font(LoomTheme.Pinned.body).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    /// The summary cut at its first ": " (the stream keeps the same line, "Allowed once: …").
    static func split(_ summary: String) -> (what: String, subject: String)? {
        guard let range = summary.range(of: ": "), range.lowerBound > summary.startIndex else { return nil }
        let subject = String(summary[range.upperBound...])
        guard !subject.isEmpty else { return nil }
        return (String(summary[..<range.lowerBound]), subject)
    }

    private var symbol: String { folded.outcome == .cancelled ? "xmark" : "checkmark" }
}

/// The typing guard's one line: the stack waits until the user pauses, leaves the composer or sends.
struct PinnedHeldLine: View {
    let cards: PinnedCardsModel

    var body: some View {
        Button { cards.openHeld() } label: {
            HStack(spacing: LoomTheme.Pinned.lineGap) {
                Circle().fill(LoomTheme.Status.attention).frame(width: LoomTheme.Pinned.headerDot, height: LoomTheme.Pinned.headerDot)
                Text(verbatim: cards.heldText).font(LoomTheme.Pinned.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
                Spacer(minLength: 0)
                Text(verbatim: "shows when you pause typing").font(LoomTheme.Pinned.hint).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    .lineLimit(1)
            }
            .padding(.horizontal, LoomTheme.Pinned.linePaddingH)
            .frame(height: LoomTheme.Pinned.lineHeight)
            .frame(maxWidth: .infinity)
            .pinnedSurface(radius: LoomTheme.Pinned.lineRadius, fill: LoomTheme.Pinned.cardFill,
                           edge: AnyShapeStyle(LoomTheme.Status.attention.opacity(LoomTheme.Pinned.edgeOpacity)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cards.heldText)
        .accessibilityHint("Shows the request. Nothing is answered.")
        .accessibilityIdentifier("pinned-held")
    }
}

/// A request Claude's process left unanswered by ending: its buttons are off, and Resume starts the session again.
struct PinnedCutOffCard: View {
    let cards: PinnedCardsModel
    let settled: ChatSettledRequest

    var body: some View {
        let title = switch settled.kind {
        case .approval: PinnedApprovalContent.title(forTool: settled.toolName)
        case .question: "Claude asks"
        case .plan: "Build this plan?"
        }
        PinnedCardChrome(cards: cards, mark: .cutOff, title: title, kind: nil, showsCounter: false,
                         failure: cards.failures[settled.id]) {
            Text("Claude stopped before you answered").font(LoomTheme.Pinned.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
            Text(verbatim: settled.subject).font(LoomTheme.Pinned.kind).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .lineLimit(3).truncationMode(.middle)
            HStack {
                Spacer(minLength: 0)
                Button("Resume") { Task { await cards.resume() } }
                    .buttonStyle(PinnedButtonStyle(style: .accent, isFocused: false))
            }
        }
        .accessibilityIdentifier("pinned-cutoff")
    }
}
