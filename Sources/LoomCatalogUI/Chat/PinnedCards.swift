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
                ScrollView(.vertical) { PinnedStack(cards: cards) }.scrollBounceBehavior(.basedOnSize)
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
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle").font(LoomTheme.Chat.rowIcon).frame(width: LoomTheme.Chat.iconSlot)
            Text(verbatim: texts.count == 1 ? "Not delivered: 1 message" : "Not delivered: \(texts.count) messages")
                .font(LoomTheme.Pinned.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
            Text("It comes back in the composer when the session runs again.").font(LoomTheme.Pinned.detail)
                .foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1)
            Spacer(minLength: 0)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(texts.joined(separator: "\n\n"), forType: .string)
            }
            .buttonStyle(PinnedButtonStyle(style: .neutral, isOn: false, isFocused: false))
        }
        .padding(.horizontal, LoomTheme.Pinned.cardPadding)
        .frame(minHeight: LoomTheme.Pinned.heldHeight)
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
        PinnedCardChrome(cards: cards, symbol: "exclamationmark.shield", title: content.title, who: content.kindLabel,
                         failure: cards.failures[request.requestID]) {
            if let agent = content.agentLine {
                Text(verbatim: agent).font(LoomTheme.Pinned.who).foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1)
                    .accessibilityIdentifier("pinned-agent")
            }
            PinnedCodeBlock(lines: content.lines, prompt: content.kind == .command ? "$" : nil)
            if content.claudeSays != nil || content.reason != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let says = content.claudeSays {
                        Text(Self.claudeSays(says)).accessibilityIdentifier("pinned-says")
                    }
                    if let reason = content.reason {
                        Text(verbatim: reason).font(LoomTheme.Pinned.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                            .accessibilityIdentifier("pinned-reason")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: LoomTheme.Pinned.buttonSpacing) {
                moreMenu(busy: busy)
                Spacer(minLength: 8)
                PinnedButtonRow(actions: actions, focused: cards.focusedIndex)
            }
            .pinnedKeys(cards: cards, kind: .approval, actions: actions, focusedIndex: cards.focusedBinding)
        }
    }

    /// "Claude: <its own words>", the label in the primary tone and the words in the secondary.
    static func claudeSays(_ says: String) -> AttributedString {
        var label = AttributedString("Claude: ")
        label.font = LoomTheme.Pinned.bodyStrong
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
            PinnedAction(id: "once", title: "Allow once", isEnabled: !busy) { Task { await cards.allowOnce(request) } },
        ]
        if request.canAllowForSession {
            list.append(PinnedAction(id: "session", title: request.sessionButtonTitle, isEnabled: !busy) {
                Task { await cards.allowForSession(request) }
            })
        }
        return list
    }

    private func moreMenu(busy: Bool) -> some View {
        Menu {
            Button("Deny and stop") { Task { await cards.denyAndStop(request) } }
        } label: {
            Image(systemName: "ellipsis").font(LoomTheme.Pinned.icon)
                .frame(width: LoomTheme.Pinned.buttonHeight, height: LoomTheme.Pinned.buttonHeight)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize()
        .disabled(busy)
        .accessibilityLabel("More answers")
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
        PinnedCardChrome(cards: cards, symbol: "questionmark.circle", title: "Claude asks", who: questions.indices.contains(step) ? questions[step].header : nil,
                         failure: cards.failures[request.requestID]) {
            if questions.indices.contains(step) {
                let question = questions[step]
                if questions.count > 1 {
                    Text("Question \(step + 1) of \(questions.count)").font(LoomTheme.Pinned.who).foregroundStyle(LoomTheme.Text.secondaryStyle)
                }
                ChatMarkdownView(blocks: ChatContent.blocks(id: request.requestID + "#\(step)", text: question.question, isStreaming: false),
                                 flags: [], rowID: request.requestID, context: cards.context)
                    .accessibilityIdentifier("pinned-question")
                if question.multiSelect {
                    Text("Select one or more").font(LoomTheme.Pinned.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                }
                ScrollView(.vertical) {
                    VStack(spacing: 6) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                            optionRow(option, number: index + 1, multi: question.multiSelect,
                                      isOn: draft.picks[step].contains(option.label), busy: busy) {
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
            HStack(spacing: LoomTheme.Pinned.buttonSpacing) {
                Menu {
                    Button("Stop this turn") { Task { await cards.denyAndStop(request) } }
                } label: {
                    Image(systemName: "ellipsis").font(LoomTheme.Pinned.icon)
                        .frame(width: LoomTheme.Pinned.buttonHeight, height: LoomTheme.Pinned.buttonHeight)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(busy)
                .accessibilityLabel("More answers")
                Spacer(minLength: 8)
                PinnedButtonRow(actions: actions, focused: cards.focusedIndex)
            }
            .pinnedKeys(cards: cards, kind: .question, actions: actions, focusedIndex: cards.focusedBinding) { index in
                cards.pick(option: index, in: request)
            }
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

    private func optionRow(_ option: ChatQuestion.Option, number: Int, multi: Bool, isOn: Bool, busy: Bool,
                           pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: multi ? (isOn ? "checkmark.square.fill" : "square") : (isOn ? "largecircle.fill.circle" : "circle"))
                    .font(LoomTheme.Pinned.body)
                    .foregroundStyle(isOn ? LoomTheme.Accent.base : LoomTheme.Text.secondary)
                    .frame(width: LoomTheme.Pinned.optionMark)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: option.label).font(LoomTheme.Pinned.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(verbatim: detail).font(LoomTheme.Pinned.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    }
                    if let preview = option.preview, !preview.isEmpty {
                        Text(verbatim: preview).font(LoomTheme.Pinned.mono).foregroundStyle(LoomTheme.Chat.output).lineLimit(6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if number <= 9 {
                    Text("\(number)").font(LoomTheme.Pinned.stepper).foregroundStyle(LoomTheme.Text.tertiary)
                }
            }
            .padding(LoomTheme.Pinned.optionPadding)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Pinned.optionRadius).fill(isOn ? LoomTheme.Pinned.optionSelectedFill : LoomTheme.Pinned.optionFill))
            .overlay(RoundedRectangle(cornerRadius: LoomTheme.Pinned.optionRadius)
                .strokeBorder(isOn ? AnyShapeStyle(LoomTheme.Pinned.optionSelectedStroke) : AnyShapeStyle(LoomTheme.Surface.hairlineStyle)))
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Pinned.optionRadius))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
        PinnedCardChrome(cards: cards, symbol: "list.bullet.rectangle", title: "Build this plan?", who: "Claude waits in plan mode",
                         tint: LoomTheme.Accent.base, strokeOpacity: LoomTheme.Pinned.planStrokeOpacity,
                         failure: cards.failures[request.requestID]) {
            if let plan {
                let long = ChatPlanCardView.isLong(plan.markdown)
                let shown = ChatPlanCardView.visibleText(plan.markdown, expanded: expanded || !long)
                ScrollView(.vertical) {
                    ChatMarkdownView(blocks: ChatContent.blocks(id: request.requestID, text: shown, isStreaming: false),
                                     flags: [], rowID: request.requestID, context: cards.context)
                        .padding(LoomTheme.Pinned.codePadding)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: bodyHeight)
                .background(RoundedRectangle(cornerRadius: LoomTheme.Pinned.codeRadius).fill(LoomTheme.Pinned.codeFill))
                .overlay(RoundedRectangle(cornerRadius: LoomTheme.Pinned.codeRadius).strokeBorder(LoomTheme.Surface.hairlineStyle))
                .accessibilityIdentifier("pinned-plan")
                HStack(spacing: 10) {
                    if let path = plan.filePath {
                        Text(verbatim: "Saved to \(path)").font(LoomTheme.Pinned.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if long {
                        Button(expanded ? "Show less" : "Show full plan") { cards.togglePlanExpanded(request) }
                            .buttonStyle(.plain).font(LoomTheme.Pinned.detail).foregroundStyle(LoomTheme.Accent.high)
                    }
                }
            }
            // One row when it fits; else the modes to continue in above, Keep planning and Approve below (the labels never cut).
            let modes = Array(actions.prefix(cards.askIsOn ? 0 : PinnedCardsModel.planModeChoices.count))
            let decisions = Array(actions.dropFirst(modes.count))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: LoomTheme.Pinned.buttonSpacing) {
                    Text(cards.askIsOn ? "Stays in Ask" : "Then").font(LoomTheme.Pinned.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    Spacer(minLength: 8)
                    PinnedButtonRow(actions: actions, focused: cards.focusedIndex)
                }
                VStack(alignment: .trailing, spacing: LoomTheme.Pinned.buttonSpacing) {
                    HStack(spacing: LoomTheme.Pinned.buttonSpacing) {
                        Text(cards.askIsOn ? "Stays in Ask" : "Then").font(LoomTheme.Pinned.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        Spacer(minLength: 8)
                        PinnedButtonRow(actions: modes, focused: cards.focusedIndex)
                    }
                    PinnedButtonRow(actions: decisions, focused: cards.focusedIndex, firstIndex: modes.count)
                }
            }
            .pinnedKeys(cards: cards, kind: .plan, actions: actions, focusedIndex: cards.focusedBinding)
        }
    }

    private func actions(mode: String, busy: Bool) -> [PinnedAction] {
        // In Ask the plan is approved in Ask: no mode to continue in.
        var list = (cards.askIsOn ? [] : PinnedCardsModel.planModeChoices).map { choice in
            PinnedAction(id: "mode-\(choice)", title: ChatModeNames.title(choice), isOn: choice == mode, isEnabled: !busy) {
                cards.setPlanMode(choice, for: request)
            }
        }
        list.append(PinnedAction(id: "keep", title: "Keep planning", isEnabled: !busy) { Task { await cards.keepPlanning(request) } })
        list.append(PinnedAction(id: "approve", title: "Approve", style: .accent, isEnabled: !busy) { Task { await cards.approvePlan(request) } })
        return list
    }
}

// MARK: Folded, held, cut off

/// An answered card, folded to one line.
struct PinnedFoldedLine: View {
    let folded: PinnedCardsModel.Folded

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(LoomTheme.Chat.rowIcon).frame(width: LoomTheme.Chat.iconSlot)
            Text(verbatim: folded.summary).font(LoomTheme.Pinned.body).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(LoomTheme.Text.secondaryStyle)
        .padding(.horizontal, 12)
        .frame(height: LoomTheme.Pinned.foldedHeight)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Pinned.buttonRadius).fill(LoomTheme.Chat.foldFill))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Pinned.buttonRadius).strokeBorder(LoomTheme.Surface.hairlineStyle))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pinned-folded")
    }

    private var symbol: String {
        switch folded.outcome {
        case .cancelled: "xmark.circle"
        case .answered, .resolved, .processEnded:
            switch folded.kind {
            case .approval: "checkmark.shield"
            case .question: "questionmark.circle"
            case .plan: "list.bullet.rectangle"
            }
        }
    }
}

/// The typing guard's one line: the stack waits until the user pauses, leaves the composer or sends.
struct PinnedHeldLine: View {
    let cards: PinnedCardsModel

    var body: some View {
        Button { cards.openHeld() } label: {
            HStack(spacing: 8) {
                Circle().fill(LoomTheme.Status.attention).frame(width: 7, height: 7)
                Text(verbatim: cards.heldText).font(LoomTheme.Pinned.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
                Spacer(minLength: 0)
                Text("Show").font(LoomTheme.Pinned.detail).foregroundStyle(LoomTheme.Accent.high)
            }
            .padding(.horizontal, 12)
            .frame(height: LoomTheme.Pinned.heldHeight)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Pinned.buttonRadius).fill(LoomTheme.Pinned.cardFill))
            .overlay(RoundedRectangle(cornerRadius: LoomTheme.Pinned.buttonRadius)
                .strokeBorder(LoomTheme.Status.attention.opacity(LoomTheme.Pinned.strokeOpacity)))
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
        PinnedCardChrome(cards: cards, symbol: "exclamationmark.triangle", title: title, who: nil, showsCounter: false,
                         failure: cards.failures[settled.id]) {
            Text("Claude stopped before you answered").font(LoomTheme.Pinned.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
            Text(verbatim: settled.subject).font(LoomTheme.Pinned.mono).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .lineLimit(3).truncationMode(.middle)
            HStack {
                Spacer(minLength: 0)
                Button("Resume") { Task { await cards.resume() } }
                    .buttonStyle(PinnedButtonStyle(style: .accent, isOn: false, isFocused: false))
            }
        }
        .opacity(0.9)
        .accessibilityIdentifier("pinned-cutoff")
    }
}
