import LoomCore
import SwiftUI

/// The launch view (V05): what needs you, what finished unread, the plan limits, Today, what Quit cut short,
/// and a box to start a session. It summarises what Loom already knows; it starts nothing by itself and has
/// no timer of its own. `DetailContent` draws it for `.home`.
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

/// Home with something in the catalog: the header, the start box and the sections.
private struct HomeBoardView: View {
    let model: CatalogModel

    var body: some View {
        GeometryReader { proxy in
            let content = min(proxy.size.width, LoomTheme.Home.maxWidth) - 2 * LoomTheme.Home.sideInset
            ScrollView {
                VStack(alignment: .leading, spacing: LoomTheme.Home.blockGap) {
                    HomeHeader(model: model)
                    if model.homeClaudeCLIMissing {
                        HomeNoClaudeNotice(model: model)
                    } else {
                        HomeStartBox(model: model)
                    }
                    if content >= LoomTheme.Home.wideFrom {
                        HStack(alignment: .top, spacing: LoomTheme.Home.columnGap) {
                            HomeLists(model: model).frame(maxWidth: .infinity, alignment: .topLeading)
                            HomeSide(model: model, continueFirst: false).frame(width: LoomTheme.Home.sideColumn)
                        }
                    } else {
                        HomeLists(model: model)
                        HomeSide(model: model, continueFirst: true)
                    }
                }
                .frame(maxWidth: LoomTheme.Home.maxWidth - 2 * LoomTheme.Home.sideInset)
                .padding(.horizontal, LoomTheme.Home.sideInset)
                .padding(.top, LoomTheme.Home.top).padding(.bottom, LoomTheme.Home.bottom)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { model.prepareHomeStart() }
        // The last-used project arrives with the catalog read: the start box follows it to that project's slot.
        .onChange(of: model.homeStartProjectID) { model.prepareHomeStart() }
    }
}

/// The title with the date, and the way to the palette.
private struct HomeHeader: View {
    let model: CatalogModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Space.detailTitleSpacing) {
            Text("Home").font(LoomTheme.TypeScale.display).foregroundStyle(LoomTheme.Text.primary)
                .accessibilityAddTraits(.isHeader)
            Text(model.today.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "en_US"))))
                .font(LoomTheme.Typography.body).foregroundStyle(LoomTheme.Text.secondaryStyle)
            Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            Button { model.openPalette() } label: {
                HStack(spacing: LoomTheme.Space.hintSpacing) {
                    Image(systemName: "magnifyingglass").font(LoomTheme.Typography.small)
                    Text("Jump to")
                    Text("⌘K").foregroundStyle(LoomTheme.Text.secondaryStyle)
                }
            }
            .buttonStyle(ChipButtonStyle())
            .help("Open the command palette")
            .accessibilityLabel("Jump to, Command K")
            .accessibilityIdentifier("home-jump")
        }
    }
}

/// The left column: what needs the user, then what finished unread. With nothing in either, one quiet card.
private struct HomeLists: View {
    let model: CatalogModel

    var body: some View {
        let board = model.homeBoard()
        VStack(alignment: .leading, spacing: LoomTheme.Home.blockGap) {
            if board.count == 0 {
                HomeNothingWaiting()
            }
            if !board.needsYou.isEmpty {
                HomeSectionCard(title: "Needs you", count: board.needsYou.count, pip: LoomTheme.Status.attention,
                                identifier: "home-needs-you") {
                    ForEach(Array(board.needsYou.enumerated()), id: \.element.id) { index, entry in
                        HomeEntryRow(model: model, entry: entry, showsRule: index > 0)
                    }
                }
            }
            if !board.finished.isEmpty {
                HomeSectionCard(title: "Finished, not read", count: board.finished.count, pip: LoomTheme.Status.unviewed,
                                identifier: "home-finished") {
                    ForEach(Array(board.finished.enumerated()), id: \.element.id) { index, entry in
                        HomeEntryRow(model: model, entry: entry, showsRule: index > 0)
                    }
                }
            }
        }
    }
}

/// The right column (below the lists in a narrow panel): plan limits, Today, Continue. A block with nothing to
/// say is left out. Under the lists Continue comes first: it is the one block there that asks for a click.
private struct HomeSide: View {
    let model: CatalogModel
    let continueFirst: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Home.blockGap) {
            if continueFirst { HomeContinue(model: model) }
            HomePlanLimits(model: model)
            HomeToday(model: model)
            if !continueFirst { HomeContinue(model: model) }
        }
    }
}

/// Both lists are empty: say so once, and what would show up here.
private struct HomeNothingWaiting: View {
    var body: some View {
        HomeCard(identifier: "home-nothing-waiting") {
            VStack(alignment: .leading, spacing: LoomTheme.Space.headerSpacing) {
                Text("Nothing needs you").font(LoomTheme.Typography.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
                Text("A session that waits for an answer, or finished while you were away, is listed here.")
                    .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(LoomTheme.Home.itemPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
