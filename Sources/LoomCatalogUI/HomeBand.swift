import SwiftUI

// MARK: The words

/// What the band says (DESIGN §9): a date line, one sentence and a line of counts. Plain values, so a test reads the words
/// without a view.
enum HomeBandText {
    /// "tuesday 20 october · 09:12": the weekday, the day and the month, then the time on a 24-hour clock, in the locale's
    /// own names and written in lower case.
    static func dateLine(_ date: Date, zone: TimeZone? = nil, locale: Locale = .current, calendar: Calendar = .current) -> String {
        var calendar = calendar
        calendar.locale = locale
        if let zone { calendar.timeZone = zone }
        let weekday = LoomDateFormat.weekdayLong(date, zone: zone, locale: locale, calendar: calendar)
        let parts = calendar.dateComponents([.day, .month], from: date)
        let month = parts.month.flatMap { calendar.standaloneMonthSymbols.indices.contains($0 - 1) ? calendar.standaloneMonthSymbols[$0 - 1] : nil }
        let day = parts.day.map(String.init)
        let time = LoomDateFormat.time24(date, zone: zone, locale: locale, calendar: calendar)
        return ([weekday, day, month].compactMap { $0 }.joined(separator: " ") + " \u{00B7} " + time).lowercased(with: locale)
    }

    /// A count in words up to ten ("Two"), in digits above, the first letter in capitals.
    static func word(_ count: Int) -> String {
        let words = ["Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
        return words.indices.contains(count) ? words[count] : String(count)
    }

    /// The counts line's parts: "2 working", "2 to continue", "5 sessions today". A part with nothing to count is left out.
    /// "Today" counts only: the catalog holds no figure for yesterday.
    static func counts(working: Int, toContinue: Int, sessionsToday: Int?) -> [Count] {
        var parts: [Count] = []
        if working > 0 { parts.append(Count(figure: "\(working)", label: "working")) }
        if toContinue > 0 { parts.append(Count(figure: "\(toContinue)", label: "to continue")) }
        if let sessionsToday { parts.append(Count(figure: "\(sessionsToday)", label: sessionsToday == 1 ? "session today" : "sessions today")) }
        return parts
    }

    struct Count: Equatable {
        let figure: String
        let label: String
    }

    /// The one sentence, in the runs it is drawn in: only "needs you" takes the attention colour, and only when something
    /// does.
    struct Sentence: Equatable {
        struct Run: Equatable {
            let text: String
            let attention: Bool
        }

        let runs: [Run]
        var text: String { runs.map(\.text).joined() }

        /// "Two sessions are working. One needs you.", "One session needs you.", "One session is working. Nothing needs you.",
        /// "Nothing is working or waiting." (`MenuBarMenu.emptyTitle`).
        init(working: Int, needsYou: Int) {
            let verb = needsYou == 1 ? "needs you" : "need you"
            if working == 0 {
                if needsYou == 0 {
                    runs = [Run(text: MenuBarMenu.emptyTitle, attention: false)]
                } else {
                    let sessions = needsYou == 1 ? "session" : "sessions"
                    runs = [Run(text: "\(HomeBandText.word(needsYou)) \(sessions) ", attention: false),
                            Run(text: verb, attention: true), Run(text: ".", attention: false)]
                }
                return
            }
            let sessions = working == 1 ? "session is" : "sessions are"
            let first = Run(text: "\(HomeBandText.word(working)) \(sessions) working. ", attention: false)
            if needsYou == 0 {
                runs = [first, Run(text: "Nothing needs you.", attention: false)]
            } else {
                runs = [first, Run(text: "\(HomeBandText.word(needsYou)) ", attention: false),
                        Run(text: verb, attention: true), Run(text: ".", attention: false)]
            }
        }

        /// The sentence as one `Text`, the attention run in the attention text colour.
        var attributed: AttributedString {
            var result = AttributedString()
            for run in runs {
                var piece = AttributedString(run.text)
                if run.attention { piece.foregroundColor = LoomTheme.Status.attentionLight }
                result.append(piece)
            }
            return result
        }
    }
}

// MARK: The layout

/// Where Home's blocks go for a pane width and a catalog: plain values for a test.
enum HomeLayout {
    /// The content's width inside the column: the pane up to `maxWidth`, less the side insets.
    static func contentWidth(paneWidth: CGFloat) -> CGFloat {
        min(paneWidth, LoomTheme.Home.maxWidth) - 2 * LoomTheme.Home.sideInset
    }

    /// The side column sits beside the lists from `wideFrom` of content width, and under them below it.
    static func isWide(paneWidth: CGFloat) -> Bool { contentWidth(paneWidth: paneWidth) >= LoomTheme.Home.wideFrom }

    /// The side column's width: a third of the content, between 316 and 400, so it grows with a wide pane.
    static func sideColumn(paneWidth: CGFloat) -> CGFloat {
        let third = contentWidth(paneWidth: paneWidth) / 3
        return min(LoomTheme.Home.sideColumnMax, max(LoomTheme.Home.sideColumnMin, third))
    }

    /// How many columns the tiles take at a content width: one below 560, two below 840, three above.
    static func tileColumns(contentWidth: CGFloat) -> Int {
        if contentWidth < LoomTheme.Remora.tileOneColumnBelow { return 1 }
        return contentWidth < LoomTheme.Remora.tileTwoColumnsBelow ? 2 : 3
    }

    /// The list cards, top to bottom. Continue comes first, in both layouts (DESIGN §9 Two columns), when it has a session;
    /// Needs you always shows, empty when nothing needs the user; Finished only with something in it.
    enum Card: Hashable { case continueSessions, needsYou, finished }

    static func cards(needsYou: Int, finished: Int, toContinue: Int) -> [Card] {
        var cards: [Card] = []
        if toContinue > 0 { cards.append(.continueSessions) }
        cards.append(.needsYou)
        if finished > 0 { cards.append(.finished) }
        return cards
    }

    /// How much further the band's text keeps from the pane's leading edge so that the window's buttons, when they float over
    /// the top 52 pt, stay clear: `max(the column's own inset, clearance)` less what the column already has.
    static func bandLeadingExtra(paneWidth: CGFloat, clearance: CGFloat) -> CGFloat {
        let columnEdge = max(0, (paneWidth - min(paneWidth, LoomTheme.Home.maxWidth)) / 2) + LoomTheme.Home.sideInset
        return max(0, clearance - columnEdge)
    }
}

// MARK: The view

/// The top band of Home: the date line, the sentence in statement type and the counts line (no art since the rescue, D-100).
/// It is one
/// replaceable unit (Remora takes the band later, DESIGN §9): it draws edge to edge and holds its own column, so the page
/// below it only sees its height.
struct HomeBand: View {
    let model: CatalogModel
    let paneWidth: CGFloat
    /// One line under the sentence, in secondary: what Remora will do before the first session (DESIGN §20 States).
    var note: String?
    @Environment(\.detailLeadingClearance) private var clearance

    var body: some View {
        let board = model.homeBoard()
        let working = model.homeWorkingCount()
        let sentence = HomeBandText.Sentence(working: working, needsYou: board.count)
        let counts = HomeBandText.counts(working: working, toContinue: model.homeContinueEntries().count,
                                         sessionsToday: model.home.sessionsToday)
        VStack(alignment: .leading, spacing: LoomTheme.Home.countsGap) {
            Text(sentence.attributed)
                .homeType(LoomTheme.InkType.statement)
                .foregroundStyle(LoomTheme.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(sentence.text)
                .accessibilityIdentifier("home-sentence")
                // The date line stands above the sentence without moving it: the sentence is 84 under the band's top.
                .overlay(alignment: .topLeading) {
                    HomeDateLine(model: model)
                        .alignmentGuide(.top) { $0[.bottom] + LoomTheme.Home.eyebrowGap }
                }
            if !counts.isEmpty { HomeCountsLine(counts: counts) }
            if let note {
                Text(note).homeType(LoomTheme.Remora.none).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, LoomTheme.Remora.noneTop - LoomTheme.Home.countsGap)
                    .accessibilityIdentifier("home-remora-none")
            }
        }
        .frame(maxWidth: LoomTheme.Home.maxWidth - 2 * LoomTheme.Home.sideInset)
        .padding(.leading, HomeLayout.bandLeadingExtra(paneWidth: paneWidth, clearance: clearance))
        .padding(.horizontal, LoomTheme.Home.sideInset)
        .padding(.top, LoomTheme.Home.bandAbove).padding(.bottom, LoomTheme.Home.bandBelow)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-band")
    }
}

/// "tuesday 20 october · 09:12". It reads the model's minute tick, so the tick redraws this line and nothing else.
private struct HomeDateLine: View {
    let model: CatalogModel

    var body: some View {
        Text(HomeBandText.dateLine(model.now))
            .homeType(LoomTheme.Home.eyebrow)
            .foregroundStyle(LoomTheme.Text.tertiaryStyle)
            .lineLimit(1)
            .accessibilityIdentifier("home-date")
    }
}

/// "2 working · 5 sessions today": figures in primary, medium; labels in secondary.
private struct HomeCountsLine: View {
    let counts: [HomeBandText.Count]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(counts.enumerated()), id: \.offset) { index, count in
                if index > 0 {
                    Text(" \u{00B7} ").homeType(LoomTheme.Home.counts).foregroundStyle(LoomTheme.Text.secondaryStyle)
                }
                Text(count.figure).homeType(LoomTheme.Home.countsFigure).foregroundStyle(LoomTheme.Text.primary)
                Text(" " + count.label).homeType(LoomTheme.Home.counts).foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(counts.map { "\($0.figure) \($0.label)" }.joined(separator: ", "))
        .accessibilityIdentifier("home-counts")
    }
}
