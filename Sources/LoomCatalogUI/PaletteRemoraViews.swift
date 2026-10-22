import LoomCore
import LoomRemora
import SwiftUI

/// Ask Remora in the palette (DESIGN §20 ⌘K; the reference's `remora/sections.html` "⌘K: ask from anywhere"): the row that heads the
/// list, and the answer that takes the list's place. The answer is Home's (`HomeRemoraAnswerContent`, the markdown, the reading
/// line and the chips), laid out as the palette draws it.
private typealias P = LoomTheme.PaletteRemora
private typealias R = LoomTheme.Remora

/// "Ask Remora", then the scope, ⇥ and ↵; while Remora answers something else the row says so.
struct PaletteRemoraRow: View {
    let palette: PaletteState
    let busy: Bool
    let selected: Bool
    let activate: () -> Void
    @State private var hovering = false

    var body: some View {
        let lit = selected || hovering
        Button(action: activate) {
            HStack(spacing: P.rowGap) {
                Image(systemName: PaletteState.askRemoraItem.symbol ?? "questionmark.bubble")
                    .font(LoomTheme.Typography.small)
                    .foregroundStyle(LoomTheme.OnPopover.secondary(lit: lit))
                    .frame(width: LoomTheme.Layout.indicatorSlot.width + P.leadingExtra, height: LoomTheme.Layout.indicatorSlot.height)
                    .accessibilityHidden(true)
                Text(PaletteRemoraText.ask).font(LoomTheme.Typography.body).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                if busy {
                    Text(PaletteRemoraText.busy).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.OnPopover.secondary(lit: lit))
                        .lineLimit(1)
                        .accessibilityIdentifier("palette-remora-busy")
                }
                Spacer(minLength: P.rowGap)
                HStack(spacing: P.keyGap) {
                    Text(palette.remoraScope.label).accessibilityIdentifier("palette-remora-scope")
                    PaletteRemoraKeyCap(key: "⇥")
                    PaletteRemoraKeyCap(key: "↵")
                }
                .font(P.scope.font)
                .foregroundStyle(LoomTheme.OnPopover.secondary(lit: lit))
                .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, PaletteMetrics.rowInset)
        .frame(height: PaletteMetrics.rowHeight)
        .background(RowHighlight(state: .resolve(selected: false, hovering: lit), radius: PaletteMetrics.rowRadius))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(PaletteRemoraText.ask + ", " + palette.remoraScope.label + (busy ? ", " + PaletteRemoraText.busy : ""))
        .accessibilityHint("Tab changes the scope")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("palette-remora-ask")
    }
}

/// A key's cap, as the reference's `kbd`.
struct PaletteRemoraKeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .padding(.horizontal, P.capPaddingH)
            .frame(minWidth: P.capSide, minHeight: P.capSide)
            .overlay(RoundedRectangle(cornerRadius: P.capRadius).strokeBorder(LoomTheme.Surface.strongHairline, lineWidth: LoomTheme.Line.hairline))
            .accessibilityHidden(true)
    }
}

/// The answer in the palette: "Remora" and the scope, the reading line while it reads, the words as they come, then the chips.
struct PaletteRemoraAnswerView: View {
    let model: CatalogModel
    let palette: PaletteState
    let asked: HomeRemoraUI.Asked
    let reads: HomeRemoraReads
    @Environment(\.indicatorsAnimate) private var indicatorsAnimate
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
        }
        .frame(height: min(max(contentHeight, PaletteMetrics.minimumListHeight), PaletteMetrics.maximumListHeight))
        .task(id: model.homeRemoraReadKey) { await reads.read(model: model) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Remora's answer")
        .accessibilityIdentifier("palette-remora-answer")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: P.rowGap) {
                Image(systemName: PaletteState.askRemoraItem.symbol ?? "questionmark.bubble").font(LoomTheme.Typography.small)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle).accessibilityHidden(true)
                Text(PaletteRemoraText.header).homeType(P.head).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                Spacer(minLength: P.rowGap)
                Text(palette.remoraScope.label).homeType(P.head).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .padding(.horizontal, R.scopePadding).frame(height: R.scopeHeight)
                    .overlay(RoundedRectangle(cornerRadius: P.capRadius).strokeBorder(LoomTheme.Surface.strongHairline, lineWidth: LoomTheme.Line.hairline))
                    .accessibilityIdentifier("palette-remora-answer-scope")
            }
            switch HomeRemoraAnswerContent.make(model: model, asked: asked, baselineUndo: reads.baselineUndo)?.body {
            case .working(let reading, let text)?:
                if text.isEmpty {
                    HStack(spacing: R.readingGap) {
                        BrailleSpinner(animating: indicatorsAnimate).frame(width: LoomTheme.Layout.indicatorSlot.width).accessibilityHidden(true)
                        Text(HomeRemoraText.readingLine(reading)).homeType(R.working).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    }
                    .padding(.top, R.workingTop)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("palette-remora-working")
                } else {
                    answerText(text)
                }
            case .failed(let kind)?:
                Text(HomeRemoraText.failure(kind)).homeType(R.answerText).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .padding(.top, R.answerTextTop)
                    .accessibilityIdentifier("palette-remora-failure")
            case .stopped(let text)?:
                if !text.isEmpty { answerText(text) }
                Text(HomeRemoraText.stoppedQuestion).homeType(R.working).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    .padding(.top, R.stoppedTop)
                    .accessibilityIdentifier("palette-remora-stopped")
            case .answered(let facts)?:
                answerText(facts.text)
                let named = HomeRemoraAnswerChips.named(facts, model: model, reads: reads)
                if !named.isEmpty {
                    FlowLayout(spacing: R.chipsGap, centered: false) {
                        ForEach(named, id: \.0.id) { session, _ in
                            HomeRemoraChip(model: model, session: session, open: { palette.openRemoraChip(session.id) })
                        }
                    }
                    .padding(.top, R.chipsTop)
                }
            case .remembered(let fact)?:
                answerText("Remembered: \(fact)")
            case .notSaved(let reason)?:
                answerText(reason)
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, P.answerPaddingH)
        .padding(.top, P.answerPaddingTop)
        .padding(.bottom, P.answerPaddingBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answerText(_ text: String) -> some View {
        Text(HomeRemoraMarkdown.attributed(text)).homeType(R.answerText).lineSpacing(R.answerLineSpacing)
            .foregroundStyle(LoomTheme.Text.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, R.answerTextTop)
            .textSelection(.enabled)
            .accessibilityIdentifier("palette-remora-answer-text")
    }
}

/// The footer while the answer shows: what it read and how long it took, then its keys.
struct PaletteRemoraAnswerFooter: View {
    let model: CatalogModel
    let palette: PaletteState
    let asked: HomeRemoraUI.Asked
    let hint: (String, String) -> AnyView

    var body: some View {
        HStack(spacing: P.footGap) {
            if let answer = model.remora.lastAnswer, answer.question == asked.question, !palette.remoraInFlight {
                Text(HomeRemoraText.footer(answer.footer, duration: HomeRemoraText.seconds(answer.answer.duration))).lineLimit(1)
                    .accessibilityIdentifier("palette-remora-footer")
            }
            Spacer(minLength: P.footGap)
            HStack(spacing: P.footGap) {
                if !palette.remoraChips.isEmpty { hint("↵", PaletteRemoraText.openChip) }
                if !palette.remoraInFlight { hint("⌘↵", PaletteRemoraText.openOnHome) }
                hint("esc", palette.remoraInFlight ? "stop" : "close")
            }
            .fixedSize()
        }
    }
}
