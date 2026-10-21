import LoomCore
import SwiftUI

/// The launch view (V05, DESIGN §9): the band that says the state in one sentence, then what wants the user (Continue, Needs
/// you, Finished, not read), and beside them the plan limits and Today. It summarises what Loom already knows; it starts
/// nothing by itself and has no timer of its own. There is no session header and no start box (V19): sessions start from the
/// sidebar's New session. `DetailContent` draws it for `.home`.
struct HomeView: View {
    let model: CatalogModel

    var body: some View {
        Group {
            if !model.isReady {
                Color.clear
            } else if model.homeCatalogIsEmpty {
                HomeEmptyCatalog(model: model)
            } else {
                HomeBoardView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: model.homeReadKey) {
            await model.refreshHome()
        }
        .task(id: model.homeTodayKey) {
            await model.refreshHomeToday()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home")
    }
}

/// Home with something in the catalog: the band, the notice when Claude is missing, and the blocks.
private struct HomeBoardView: View {
    let model: CatalogModel

    var body: some View {
        GeometryReader { proxy in
            let paneWidth = proxy.size.width
            ScrollView {
                VStack(spacing: 0) {
                    HomeBand(model: model, paneWidth: paneWidth)
                    VStack(alignment: .leading, spacing: LoomTheme.Home.blockGap) {
                        if model.homeClaudeCLIMissing { HomeNoClaudeNotice(model: model) }
                        if HomeLayout.isWide(paneWidth: paneWidth) {
                            HStack(alignment: .top, spacing: LoomTheme.Home.columnGap) {
                                HomeLists(model: model).frame(maxWidth: .infinity, alignment: .topLeading)
                                HomeUsage(model: model).frame(width: LoomTheme.Home.sideColumn)
                            }
                        } else {
                            HomeLists(model: model)
                            HomeUsage(model: model)
                        }
                    }
                    .frame(maxWidth: LoomTheme.Home.maxWidth - 2 * LoomTheme.Home.sideInset)
                    .padding(.horizontal, LoomTheme.Home.sideInset)
                    .padding(.bottom, LoomTheme.Home.bottom)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// The left column (under the band in a narrow pane, with the side cards below): Continue when a quit cut sessions short,
/// then Needs you, which stays when empty with the one line that says what appears there, then Finished, not read when
/// something finished. `HomeLayout.cards` decides which show.
private struct HomeLists: View {
    let model: CatalogModel

    var body: some View {
        let board = model.homeBoard()
        let cards = HomeLayout.cards(needsYou: board.needsYou.count, finished: board.finished.count,
                                     toContinue: model.homeContinueEntries().count)
        VStack(alignment: .leading, spacing: LoomTheme.Home.blockGap) {
            ForEach(cards, id: \.self) { card in
                switch card {
                case .continueSessions:
                    HomeContinue(model: model)
                case .needsYou:
                    HomeListCard(title: "Needs you", count: board.needsYou.isEmpty ? nil : board.needsYou.count,
                                 pip: board.needsYou.isEmpty ? nil : LoomTheme.Status.attention, identifier: "home-needs-you") {
                        if board.needsYou.isEmpty {
                            HomeBlankRow()
                        } else {
                            ForEach(board.needsYou) { HomeEntryRow(model: model, entry: $0) }
                        }
                    }
                case .finished:
                    HomeListCard(title: "Finished, not read", count: board.finished.count, pip: LoomTheme.Status.unviewed,
                                 identifier: "home-finished") {
                        ForEach(board.finished) { HomeEntryRow(model: model, entry: $0) }
                    }
                }
            }
        }
    }
}

/// The empty Needs you card's one row: it says what appears there (DESIGN §9 Nothing waiting).
private struct HomeBlankRow: View {
    static let text = "A session that waits for an answer, or finished while you were away, is listed here."

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline).accessibilityHidden(true)
            Text(Self.text)
                .homeType(LoomTheme.Home.blank).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LoomTheme.Home.itemPadding)
                .padding(.top, LoomTheme.Home.blankTop).padding(.bottom, LoomTheme.Home.blankBottom)
                .accessibilityIdentifier("home-needs-you-empty")
        }
    }
}
