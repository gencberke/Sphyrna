import LoomCore
import SwiftUI

/// The launch view (V05, DESIGN §9): the band that says the state in one sentence, then what wants the user (Continue, Needs
/// you, Finished, not read), and beside them the plan limits and Today. It summarises what Loom already knows; it starts
/// nothing by itself and has no timer of its own. There is no session header and no start box (V19): sessions start from the
/// sidebar's New session. `DetailContent` draws it for `.home`.
struct HomeView: View {
    let model: CatalogModel
    /// What Remora's section reads for itself, and keeps of the user's own choices, while Home is on screen. Both go with the view.
    @State private var reads: HomeRemoraReads
    @State private var remoraUI = HomeRemoraUI()
    @State private var windowProbe = HomeWindowProbe()
    @State private var windowAttached = false

    init(model: CatalogModel) {
        self.model = model
        _reads = State(initialValue: HomeRemoraReads(baselineUndo: model.remora.lastUndo))
    }

    var body: some View {
        Group {
            if !model.isReady {
                Color.clear
            } else if model.homeCatalogIsEmpty {
                HomeEmptyCatalog(model: model)
            } else {
                HomeBoardView(model: model, reads: reads, remoraUI: remoraUI)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HomeWindowProbeView(probe: windowProbe) { windowAttached = true })
        .task(id: model.homeReadKey) {
            await model.refreshHome()
        }
        // Each time Home shows (and once more when its window is known, and when Remora's host arrives after Home showed, as on a
        // launch that restores Home): the day's kept brief is read again and, with the brief on Automatic, the model decides the
        // morning brief. This is the one place the automatic brief is asked.
        .task(id: HomeRemoraShowKey(windowAttached: windowAttached, hasHost: model.hasRemora)) {
            await HomeRemoraCalls.homeShown(model: model, window: windowProbe.facts)
        }
        .task(id: model.homeRemoraReadKey) {
            await reads.read(model: model)
        }
        .task(id: model.homeTodayKey) {
            await model.refreshHomeToday()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home")
    }
}

/// Home with something in the catalog: the band, the notice while a connected agent needs attention, and the blocks.
private struct HomeBoardView: View {
    let model: CatalogModel
    let reads: HomeRemoraReads
    let remoraUI: HomeRemoraUI

    var body: some View {
        GeometryReader { proxy in
            let paneWidth = proxy.size.width
            ScrollView {
                VStack(spacing: 0) {
                    HomeTop(model: model, paneWidth: paneWidth, reads: reads, remoraUI: remoraUI)
                    VStack(alignment: .leading, spacing: LoomTheme.Home.blockGap) {
                        if model.homeConnect.showsNotice { HomeConnectNotice(model: model) }
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

/// The top of Home: Remora's section when it is on and has something to say, else the band (DESIGN §9). Before any session the band
/// stays and one line says what Remora will do.
private struct HomeTop: View {
    let model: CatalogModel
    let paneWidth: CGFloat
    let reads: HomeRemoraReads
    let remoraUI: HomeRemoraUI

    var body: some View {
        let context = HomeRemoraContext.make(model: model, reads: reads, ui: remoraUI)
        if context.state.replacesBand {
            HomeRemoraSection(model: model, paneWidth: paneWidth, ui: remoraUI, reads: reads)
        } else {
            HomeBand(model: model, paneWidth: paneWidth,
                     note: context.state == .beforeAnySession ? HomeRemoraText.beforeAnySession : nil)
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
    static let text = "A session that waits for your answer is listed here."

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
