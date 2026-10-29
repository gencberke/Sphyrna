import LoomCore
import LoomRemora
import SwiftUI

/// Remora on Home (DESIGN §9 and §20; the reference's `#brief` document): the brief with its states, or the fold, then the field,
/// the answer and the footer. It takes the band's place with Remora on, and it is one VoiceOver group named "Remora"; its art (the
/// band's hammerhead behind it, and Remora's face in the heading row or the fold's 84 × 30 slot, `HomeRemoraArt`) is hidden from
/// VoiceOver.
struct HomeRemoraSection: View {
    let model: CatalogModel
    let paneWidth: CGFloat
    let ui: HomeRemoraUI
    let reads: HomeRemoraReads
    @Environment(\.detailLeadingClearance) private var clearance
    @Environment(\.openRemoraMemory) private var openMemory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var art = HomeRemoraArt()

    var body: some View {
        let context = HomeRemoraContext.make(model: model, reads: reads, ui: ui)
        let columns = HomeLayout.tileColumns(contentWidth: HomeLayout.contentWidth(paneWidth: paneWidth))
        VStack(alignment: .leading, spacing: 0) {
            if context.state == .folded {
                HomeRemoraFold(model: model, ui: ui, reads: reads, context: context)
            } else {
                HomeRemoraBriefBlock(model: model, ui: ui, reads: reads, context: context, columns: columns)
            }
            HomeRemoraFieldBlock(model: model, ui: ui, reads: reads, context: context,
                                 topGap: context.state == .folded ? LoomTheme.Remora.foldFieldTop : LoomTheme.Remora.fieldTop)
            HomeRemoraAnswerBlock(model: model, ui: ui, reads: reads, context: context)
            if context.state == .brief, let brief = context.brief, !brief.footer.isEmpty {
                HomeRemoraFooter(model: model, ui: ui, reads: reads, brief: brief, openMemory: openMemory)
            }
        }
        .frame(maxWidth: LoomTheme.Home.maxWidth - 2 * LoomTheme.Home.sideInset)
        .padding(.leading, HomeLayout.bandLeadingExtra(paneWidth: paneWidth, clearance: clearance))
        .padding(.horizontal, LoomTheme.Home.sideInset)
        .padding(.top, context.state == .folded ? LoomTheme.Remora.foldTop : LoomTheme.Remora.top)
        .padding(.bottom, context.state == .folded ? LoomTheme.Remora.foldBottom : LoomTheme.Remora.bottom)
        .frame(maxWidth: .infinity)
        // Remora's face sits in the place's column, beside the sentence and never behind it. No art behind the brief.
        .environment(\.homeRemoraArt, art)
        // A new brief being written fades the face in (DESIGN §9 The arrival).
        .onChange(of: HomeRemoraArtPose.arrives(context.state), initial: true) { _, arrives in
            if arrives { art.arrival(reduceMotion: reduceMotion) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Remora")
        .accessibilityIdentifier("home-remora")
        // ⌘↵ on the palette's answer: Home keeps it as the field's Earlier line.
        .onChange(of: model.palette.homeEarlier, initial: true) { _, handed in
            if handed != nil, let asked = model.palette.takeHomeEarlier() { ui.earlier = asked }
        }
    }
}

/// A place of Remora's face in the fold: about 36 wide at the start of the folded line. It takes no click and VoiceOver does not
/// see it.
struct HomeRemoraArtPlace: View {
    let identifier: String
    private typealias R = LoomTheme.Remora

    var body: some View {
        HomeRemoraFace(width: R.foldFaceWidth).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .allowsHitTesting(false).accessibilityHidden(true).accessibilityIdentifier(identifier)
    }
}

// MARK: The brief

/// The heading with its face, the sentence, the tiles, the further and quiet projects and the proposal.
private struct HomeRemoraBriefBlock: View {
    let model: CatalogModel
    let ui: HomeRemoraUI
    let reads: HomeRemoraReads
    let context: HomeRemoraContext
    /// How many columns the tiles take at this pane's width.
    let columns: Int
    private typealias R = LoomTheme.Remora

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeRemoraHeading(model: model, ui: ui, context: context)
            HomeRemoraSentence(model: model, ui: ui, context: context)
                .frame(maxWidth: R.sentenceMaxWidth, alignment: .topLeading)
                .padding(.top, R.lineTop)
            if !context.tiles.isEmpty {
                HomeRemoraTileGrid(model: model, ui: ui, reads: reads, tiles: context.tiles, now: context.now, columns: columns)
                    .padding(.top, R.tilesTop)
            } else if context.readingFrames > 0 {
                HomeRemoraReadingFrames(count: context.readingFrames, columns: columns).padding(.top, R.tilesTop)
            }
            ForEach(context.further) { line in
                HomeRemoraFurtherLine(model: model, line: line).padding(.top, R.quietTop)
            }
            ForEach(context.quiet) { quiet in
                HomeRemoraQuietLine(quiet: quiet, now: context.now).padding(.top, R.quietTop)
            }
            if context.state == .brief { HomeRemoraProposal(model: model, reads: reads) }
        }
    }
}

/// The face before "Where you left off", then the date line and ⋯.
private struct HomeRemoraHeading: View {
    let model: CatalogModel
    let ui: HomeRemoraUI
    let context: HomeRemoraContext
    @Environment(\.openRemoraMemory) private var openMemory
    @Environment(\.homeRemoraArt) private var art
    private typealias R = LoomTheme.Remora

    var body: some View {
        let when = HomeRemoraText.whenLine(context.brief?.startedAt ?? model.now)
        HStack(alignment: .center, spacing: 0) {
            HomeRemoraFace(width: R.headingFaceWidth).opacity(art?.fade ?? 1)
                .padding(.trailing, R.headingFaceGap)
                .accessibilityHidden(true)
                .accessibilityIdentifier("home-remora-face")
            Text(HomeRemoraText.heading).homeType(LoomTheme.InkType.statement).foregroundStyle(LoomTheme.Text.primary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home-remora-heading")
            Text(when).homeType(R.when).foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1)
                .padding(.leading, R.headGap)
                .accessibilityIdentifier("home-remora-when")
            Spacer(minLength: 0)
            moreButton
        }
    }

    private var items: [HomeRemoraMenuItem] {
        HomeRemoraMoreMenu.items(openMemory: openMemory, catchMeUp: { _ = HomeRemoraCalls.catchMeUp(model, ui: ui) },
                                 settings: { model.showSettings() })
    }

    private var moreButton: some View {
        let isOpen = ui.binding(.more)
        return Button { isOpen.wrappedValue.toggle() } label: { InkIcon(.more) }
            .buttonStyle(ChromeButtonStyle(selected: isOpen.wrappedValue))
            .fixedSize()
            .help("Remora actions")
            .accessibilityLabel("Remora actions")
            .accessibilityHint("Opens a menu")
            .accessibilityIdentifier("home-remora-more")
            .inkPopover(isPresented: isOpen, id: "home-remora-more", label: "Remora actions", side: .below, alignment: .trailing,
                        keys: { key in
                            let outcome = HomeRemoraMenuKeys.resolve(key, cursor: ui.cursor, count: items.count)
                            ui.cursor = outcome.cursor
                            if let use = outcome.use {
                                items[use].action()
                                isOpen.wrappedValue = false
                            }
                            return outcome.handled
                        }, content: {
                HomeRemoraMenuView(items: items, width: R.moreMenuWidth, cursor: ui.cursor, hover: { ui.cursor = $0 },
                                   close: { isOpen.wrappedValue = false })
            })
    }
}

/// The rows of ⋯: Catch Me Up, Memory… (only with a door to the memory) and Settings….
enum HomeRemoraMoreMenu {
    static func items(openMemory: (@MainActor () -> Void)?, catchMeUp: @escaping @MainActor () -> Void,
                      settings: @escaping @MainActor () -> Void) -> [HomeRemoraMenuItem] {
        var rows = [HomeRemoraMenuItem(id: "catch", title: HomeRemoraText.catchMeUp, mark: .symbol("arrow.clockwise"), action: catchMeUp)]
        if let openMemory {
            rows.append(HomeRemoraMenuItem(id: "memory", title: HomeRemoraText.memory, mark: .symbol("book"), action: openMemory))
        }
        rows.append(HomeRemoraMenuItem(id: "settings", title: HomeRemoraText.settings, mark: .symbol("gearshape"), dividerAbove: true,
                                       action: settings))
        return rows
    }
}

/// Remora's sentence in its two lines' room, or the words of a state; the reading line stands over it while Remora reads.
private struct HomeRemoraSentence: View {
    let model: CatalogModel
    let ui: HomeRemoraUI
    let context: HomeRemoraContext
    @Environment(\.indicatorsAnimate) private var indicatorsAnimate
    private typealias R = LoomTheme.Remora

    var body: some View {
        let remora = model.remora
        ZStack(alignment: .topLeading) {
            switch context.state {
            case .reading:
                if remora.streamedText.isEmpty {
                    HStack(spacing: R.readingGap) {
                        BrailleSpinner(animating: indicatorsAnimate).frame(width: LoomTheme.Layout.indicatorSlot.width)
                            .accessibilityHidden(true)
                        Text(HomeRemoraText.readingLine(remora.reading)).homeType(LoomTheme.InkType.small).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("home-remora-reading")
                } else {
                    sentence(remora.streamedText)
                }
            case .brief:
                sentence(context.brief?.text ?? "")
            case .cannotAnswer(let reason):
                words(cannotAnswerText(reason), button: button(for: reason))
            case .stoppedBrief:
                VStack(alignment: .leading, spacing: 0) {
                    if !remora.streamedText.isEmpty { sentence(remora.streamedText) }
                    words(HomeRemoraText.stoppedBrief, button: (HomeRemoraText.catchMeUp, { catchMeUp() }))
                }
            case .whenIAsk:
                words(HomeRemoraText.whenIAsk, button: (HomeRemoraText.catchMeUp, { catchMeUp() }))
            case .off, .beforeAnySession, .folded:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: R.sentenceRoom, alignment: .topLeading)
    }

    private func sentence(_ text: String) -> some View {
        Text(HomeRemoraMarkdown.attributed(text)).homeType(R.sentence).lineSpacing(R.sentenceLineSpacing)
            .foregroundStyle(LoomTheme.Text.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("home-remora-sentence")
    }

    /// A state's own words, in Sphyrna's voice, with the button that goes on.
    private func words(_ text: String, button: (title: String, action: () -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: R.readingGap) {
            Text(text).homeType(R.sentence).lineSpacing(R.sentenceLineSpacing).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("home-remora-state")
            if let button {
                Button(button.title, action: button.action)
                    .buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
                    .accessibilityIdentifier("home-remora-state-action")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cannotAnswerText(_ reason: HomeRemoraCannotAnswer) -> String {
        switch reason {
        case .login: return HomeRemoraText.notLoggedIn
        case .generic: return HomeRemoraText.couldNotAnswer
        case .wait:
            let usage = model.usage
            return HomeRemoraText.waitSentence(threshold: model.remora.preferences.windowThreshold,
                                               resetsAt: usage?.limits?.fiveHour?.resetsAt, timeZone: usage?.timeZone ?? .current)
        }
    }

    private func button(for reason: HomeRemoraCannotAnswer) -> (title: String, action: () -> Void)? {
        switch reason {
        case .login: nil
        case .wait: (HomeRemoraText.catchMeUpAnyway, { catchMeUp() })
        case .generic: (HomeRemoraText.tryAgain, { catchMeUp() })
        }
    }

    private func catchMeUp() { HomeRemoraCalls.catchMeUp(model, ui: ui) }
}

/// Inline markdown for the model's sentences, with its line breaks kept; plain text when it does not parse.
enum HomeRemoraMarkdown {
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
