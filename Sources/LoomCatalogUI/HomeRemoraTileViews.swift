import LoomCore
import LoomRemora
import SwiftUI

// The brief's tiles, its further and quiet lines, the proposal, the footer with Sources, and the fold (DESIGN §9 and §20; the
// reference's `.tile`, `.rquiet`, `.rprop`, `.bfoot`, `.rfold`, `.rpop` and `.dpop`).

private typealias R = LoomTheme.Remora

/// A link in the reference's style: secondary text, underlined.
struct HomeRemoraLink: View {
    let title: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).underline().foregroundStyle(LoomTheme.Text.secondaryStyle)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: Tiles

/// Up to three tiles in three equal columns.
struct HomeRemoraTileGrid: View {
    let model: CatalogModel
    let ui: HomeRemoraUI
    let reads: HomeRemoraReads
    let tiles: [HomeRemoraTile]
    let now: Date

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: R.tileGap, alignment: .top), count: R.tileColumns),
                  alignment: .leading, spacing: R.tileGap) {
            ForEach(tiles) { tile in
                HomeRemoraTileView(model: model, ui: ui, reads: reads, tile: tile, now: now)
            }
        }
    }
}

/// The tiles' places while Remora reads (the reference's `.tile.wait`): empty frames in the grid's columns, a hairline at the tile's
/// radius and height with nothing inside, so the brief's tiles take their places without a jump. They take no click and VoiceOver
/// does not see them.
struct HomeRemoraReadingFrames: View {
    let count: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Radius.block)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: R.tileGap, alignment: .top), count: R.tileColumns),
                  alignment: .leading, spacing: R.tileGap) {
            ForEach(0..<count, id: \.self) { _ in
                shape.strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline)
                    .frame(maxWidth: .infinity)
                    .frame(height: R.readingFrameHeight)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One tile: the project and the note's day, the session and how it ended, "Next:" from the note, Put in Draft and Open.
struct HomeRemoraTileView: View {
    let model: CatalogModel
    let ui: HomeRemoraUI
    let reads: HomeRemoraReads
    let tile: HomeRemoraTile
    let now: Date

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Radius.block)
        let session = tile.session
        VStack(alignment: .leading, spacing: 0) {
            head(session)
            HStack(spacing: R.tileTitleGap) {
                HarnessMark(provider: session.provider)
                Text(session.title).homeType(R.tileTitle).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
            }
            .padding(.top, R.tileTitleTop)
            HStack(spacing: R.tileStateGap) {
                IndicatorView(indicator: session.indicator).frame(width: LoomTheme.Layout.indicatorSlot.width)
                    .accessibilityHidden(true)
                Text(HomeRemoraTiles.stateText(session.indicator, lastActivityAt: session.lastActivityAt, now: now))
                    .homeType(R.tileState).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle).lineLimit(1)
            }
            .padding(.top, R.tileStateTop)
            if let next = tile.next {
                Text("\(Text("Next: ").font(R.tileNextBold.font).foregroundStyle(LoomTheme.Text.primary))\(Text(next).font(R.tileNext.font).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle))")
                    .lineSpacing(R.tileNextLineSpacing).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, R.tileNextTop)
                    .accessibilityIdentifier("home-remora-next")
            }
            actions(session)
        }
        .padding(.horizontal, R.tilePaddingH).padding(.top, R.tilePaddingTop).padding(.bottom, R.tilePaddingBottom)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(shape.fill(LoomTheme.Surface.card))
        .overlay(shape.strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
        .depth(LoomTheme.Elevation.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-remora-tile")
    }

    private func head(_ session: HomeRemoraSession) -> some View {
        HStack(spacing: R.tileHeadGap) {
            if let name = session.projectName { ProjectMarkView(name: name, tone: session.tone, size: .chip) }
            Text(session.projectName ?? "").homeType(R.tileHead).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Text(timeLabel(session)).homeType(R.tileHead).foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1)
        }
    }

    /// The note's day for a tile of the brief, the session's age for a catalog tile.
    private func timeLabel(_ session: HomeRemoraSession) -> String {
        if !tile.isCatalog, let day = tile.noteDay, let label = HomeRemoraText.noteDay(day, now: now) { return label }
        return RelativeTime.string(from: session.lastActivityAt, to: now)
    }

    @ViewBuilder
    private func actions(_ session: HomeRemoraSession) -> some View {
        if let result = ui.placed[tile.id] {
            HStack(spacing: R.placedGap) {
                Text(HomeRemoraText.placed(result)).homeType(R.placedBold).foregroundStyle(LoomTheme.Text.primary)
                Spacer(minLength: 0)
                HomeRemoraLink(title: "Open", identifier: "home-remora-open") { model.select(tile.id) }
                    .homeType(R.placed)
            }
            .frame(height: R.placedHeight)
            .padding(.top, R.tileActionsTop)
            .accessibilityIdentifier("home-remora-placed")
        } else {
            HStack(spacing: R.tileActionsGap) {
                if let draft = tile.draft {
                    HomeRemoraPutInDraft(model: model, ui: ui, reads: reads, sessionID: tile.id, line: draft)
                }
                Button("Open") { model.select(tile.id) }
                    .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
                    .accessibilityLabel("Open \(session.title)")
                    .accessibilityIdentifier("home-remora-open")
            }
            .padding(.top, R.tileActionsTop)
        }
    }
}

/// Put in Draft: a small secondary button. The pointer on it shows the whole line and where it will go; a click leaves the line in an
/// empty Chat composer, or copies it, and never sends.
struct HomeRemoraPutInDraft: View {
    let model: CatalogModel
    let ui: HomeRemoraUI
    let reads: HomeRemoraReads
    let sessionID: UUID
    let line: String

    var body: some View {
        let hover = ui.hoverBinding(sessionID)
        Button("Put in Draft") {
            guard let record = reads.record(of: sessionID, model: model) else { return }
            ui.placed[sessionID] = model.putRemoraLineInDraft(line, record: record)
            hover.wrappedValue = false
        }
        .buttonStyle(ControlButtonStyle(kind: .secondary, size: .small))
        .onHover { hover.wrappedValue = $0 }
        .accessibilityHint("Leaves the next step in the session's composer without sending it")
        .accessibilityIdentifier("home-remora-put-in-draft")
        .inkPopover(isPresented: hover, id: "home-remora-draft", label: "Put in Draft", side: .above, alignment: .leading,
                    takesKeyboard: false, content: {
            HomeRemoraDraftHover(line: line, plan: reads.record(of: sessionID, model: model).map { model.remoraDraftPlan(for: $0) } ?? .copyTerminal)
        })
    }
}

/// The hover popover (330 wide): where the line goes, the line whole, and that the composer's own ↵ sends it.
struct HomeRemoraDraftHover: View {
    let line: String
    let plan: RemoraDraftPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(HomeRemoraText.hoverWhere(plan)).homeType(R.draftHoverWhere).foregroundStyle(LoomTheme.OnPopover.placeholder)
                .padding(.bottom, R.draftHoverGap)
            Text(line).homeType(R.draftHoverLine).foregroundStyle(LoomTheme.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, R.draftHoverBoxV).padding(.horizontal, R.draftHoverBoxH)
                .background(RoundedRectangle(cornerRadius: R.draftHoverBoxRadius).fill(LoomTheme.Surface.raised2))
                .overlay(RoundedRectangle(cornerRadius: R.draftHoverBoxRadius)
                    .strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
            Text(HomeRemoraText.hoverKey).homeType(R.draftHoverKey).foregroundStyle(LoomTheme.OnPopover.placeholder)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, R.draftHoverKeyTop)
        }
        .padding(.vertical, R.draftHoverPaddingV).padding(.horizontal, R.draftHoverPaddingH)
        .frame(width: R.draftHoverWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Further and quiet projects

/// A further project that moved: one line, a click opens its session.
struct HomeRemoraFurtherLine: View {
    let model: CatalogModel
    let line: HomeRemoraFurther

    var body: some View {
        let session = line.session
        Button { model.select(session.id) } label: {
            HStack(spacing: R.quietGap) {
                Image(systemName: "chevron.right").font(R.chevronGlyph.font)
                    .foregroundStyle(LoomTheme.Text.tertiaryStyle).frame(width: R.chevron, height: R.chevron).accessibilityHidden(true)
                if let name = session.projectName { ProjectMarkView(name: name, tone: session.tone, size: .chip) }
                Text(session.projectName ?? "").homeType(R.quiet).foregroundStyle(LoomTheme.Text.secondaryStyle)
                Text(session.title).homeType(R.quietMeta).foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.projectName ?? "Project"), \(session.title)")
        .accessibilityIdentifier("home-remora-further")
    }
}

/// A quiet project: "website  quiet since Wednesday".
struct HomeRemoraQuietLine: View {
    let quiet: HomeRemoraQuiet
    let now: Date

    var body: some View {
        HStack(spacing: R.quietGap) {
            Image(systemName: "chevron.right").font(R.chevronGlyph.font)
                .foregroundStyle(LoomTheme.Text.tertiaryStyle).frame(width: R.chevron, height: R.chevron).accessibilityHidden(true)
            ProjectMarkView(name: quiet.project.name, tone: quiet.project.tone, size: .chip)
            Text(quiet.project.name).homeType(R.quiet).foregroundStyle(LoomTheme.Text.secondaryStyle)
            Text(HomeRemoraText.quietSince(quiet.since, now: now)).homeType(R.quietMeta).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-remora-quiet")
    }
}

// MARK: Remember

/// "Remember this?" with the fact, Save and Not Now; after a Save, what was saved with Undo; or why nothing was saved.
struct HomeRemoraProposal: View {
    let model: CatalogModel
    let reads: HomeRemoraReads

    var body: some View {
        let remora = model.remora
        Group {
            if let fact = remora.proposedFacts.first {
                HStack(spacing: R.proposalGap) {
                    Text("Remember this?").homeType(R.proposal).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    Text(fact).homeType(R.proposalFact).foregroundStyle(LoomTheme.Text.primary).lineLimit(2)
                    HStack(spacing: R.proposalActionsGap) {
                        Button("Save") { model.confirmRemoraFact(fact) }
                            .buttonStyle(ControlButtonStyle(kind: .secondary, size: .small))
                            .accessibilityIdentifier("home-remora-save")
                        Button("Not Now") { model.dismissRemoraFact(fact) }
                            .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
                            .accessibilityIdentifier("home-remora-not-now")
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: R.proposalMinHeight)
                .padding(.top, R.proposalTop)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home-remora-proposal")
            } else if let undo = remora.lastUndo, undo != reads.baselineUndo, let fact = remora.lastRemembered {
                HStack(spacing: R.proposalGap) {
                    Text("Remembered:").homeType(R.proposal).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    Text(fact).homeType(R.proposalFact).foregroundStyle(LoomTheme.Text.primary).lineLimit(2)
                    Button("Undo") { model.undoRemora(undo) }
                        .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
                        .accessibilityIdentifier("home-remora-undo")
                    Spacer(minLength: 0)
                }
                .frame(minHeight: R.proposalMinHeight)
                .padding(.top, R.proposalTop)
                .accessibilityIdentifier("home-remora-remembered")
            } else if let reason = remora.notSavedReason {
                Text(reason).homeType(R.proposal).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .frame(minHeight: R.proposalMinHeight, alignment: .leading)
                    .padding(.top, R.proposalTop)
                    .accessibilityIdentifier("home-remora-not-saved")
            }
        }
    }
}

// MARK: Footer and Sources

/// "Remora read 6 sessions and 3 project notes · 4.6 s", then Sources and Memory….
struct HomeRemoraFooter: View {
    let model: CatalogModel
    let ui: HomeRemoraUI
    let reads: HomeRemoraReads
    let brief: HomeRemoraBrief
    let openMemory: (@MainActor () -> Void)?

    var body: some View {
        let sources = ui.binding(.sources)
        HStack(spacing: R.footGap) {
            Text(HomeRemoraText.footer(brief.footer, duration: brief.duration)).homeType(R.foot)
                .foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .accessibilityIdentifier("home-remora-footer")
            HomeRemoraLink(title: HomeRemoraText.sources, identifier: "home-remora-sources") { sources.wrappedValue.toggle() }
                .homeType(R.footLink)
                .inkPopover(isPresented: sources, id: "home-remora-sources", label: "Read for this brief", side: .above, alignment: .leading,
                            content: {
                    HomeRemoraSourcesView(model: model, reads: reads, label: HomeRemoraText.sourcesLabel(brief: true),
                                          sessionIDs: brief.readSessionIDs, tokens: brief.tokens, duration: brief.duration,
                                          close: { sources.wrappedValue = false })
                })
            if let openMemory {
                HomeRemoraLink(title: HomeRemoraText.memory, identifier: "home-remora-memory") { openMemory() }.homeType(R.footLink)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, R.footTop)
        .opacity(1)
    }
}

/// What a brief or an answer read, each with its age; the project notes; and the call's size (340 wide).
struct HomeRemoraSourcesView: View {
    let model: CatalogModel
    let reads: HomeRemoraReads
    let label: String
    let sessionIDs: [UUID]
    let tokens: Int?
    let duration: TimeInterval?
    let close: () -> Void

    var body: some View {
        let excluded = model.remora.preferences.excludedProjects
        let sessions = sessionIDs.compactMap { id in reads.sessions[id].flatMap { model.homeRemoraSession($0) } }
            .filter { session in session.projectID.map { !excluded.contains($0) } ?? true }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        let notes = reads.notes.filter { !excluded.contains($0.project) }
        VStack(alignment: .leading, spacing: 0) {
            heading(label)
            ForEach(sessions) { session in
                Button {
                    model.select(session.id)
                    close()
                } label: {
                    HStack(spacing: R.sourcesRowGap) {
                        Group {
                            if let name = session.projectName { ProjectMarkView(name: name, tone: session.tone, size: .chip) } else { Color.clear }
                        }
                        .frame(width: R.sourcesMarkColumn).accessibilityHidden(true)
                        Text(session.title).homeType(R.sourcesText).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Text(RelativeTime.string(from: session.lastActivityAt, to: model.now)).homeType(R.sourcesMeta)
                            .foregroundStyle(LoomTheme.OnPopover.placeholder)
                    }
                    .padding(.horizontal, R.sourcesRowPadding)
                    .frame(height: R.sourcesRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(session.title), \(RelativeTime.string(from: session.lastActivityAt, to: model.now))")
            }
            if !notes.isEmpty {
                heading("Memory")
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    HStack(spacing: R.sourcesRowGap) {
                        Image(systemName: "doc.text").font(R.docGlyph.font).foregroundStyle(LoomTheme.OnPopover.placeholder)
                            .frame(width: R.sourcesMarkColumn).accessibilityHidden(true)
                        Text("\(note.name ?? "Project")\u{2019}s note").homeType(R.sourcesText).foregroundStyle(LoomTheme.Text.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, R.sourcesRowPadding)
                    .frame(height: R.sourcesRowHeight)
                }
            }
            Rectangle().fill(LoomTheme.Surface.hairline).frame(height: LoomTheme.Line.hairline)
                .padding(.top, R.sourcesFootTop).padding(.horizontal, -R.sourcesInset)
            Text(HomeRemoraText.sourcesFoot(sessions: sessions.count, notes: notes.count, tokens: tokens, duration: duration))
                .homeType(R.sourcesMeta).foregroundStyle(LoomTheme.OnPopover.placeholder)
                .padding(.horizontal, R.sourcesFootH - R.sourcesInset).padding(.top, R.sourcesFootV)
                .accessibilityIdentifier("home-remora-sources-foot")
        }
        .padding(R.sourcesInset)
        .frame(width: R.sourcesWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func heading(_ text: String) -> some View {
        Text(text).homeType(LoomTheme.InkType.label).textCase(.uppercase).foregroundStyle(LoomTheme.OnPopover.placeholder)
            .padding(.horizontal, R.sourcesLabelAside).padding(.top, R.sourcesLabelTop).padding(.bottom, R.sourcesLabelBottom)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: The fold

/// Once one entry was picked up: "Remora · morning brief 09:12 · 2 of 3 picked up" with Show Brief, one line for each entry, then the
/// field. The remora's 84 × 30 slot stands at the line's start, empty.
struct HomeRemoraFold: View {
    let model: CatalogModel
    let ui: HomeRemoraUI
    let reads: HomeRemoraReads
    let context: HomeRemoraContext

    private var foldTail: String {
        " \u{00B7} " + HomeRemoraText.foldTail(startedAt: context.brief?.startedAt, pickedUp: context.pickedUp, of: context.tiles.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: R.foldHeadGap) {
                HomeRemoraArtPlace(identifier: "home-remora-fold-slot", fold: true).frame(width: R.foldSlot.width, height: R.foldSlot.height)
                Text("\(Text("Remora").font(R.foldHeadBold.font).foregroundStyle(LoomTheme.Text.primary))\(Text(foldTail).font(R.foldHead.font).foregroundStyle(LoomTheme.Text.secondaryStyle))")
                    .accessibilityIdentifier("home-remora-fold-head")
                Spacer(minLength: 0)
                HomeRemoraLink(title: HomeRemoraText.showBrief, identifier: "home-remora-show-brief") { ui.expanded = true }
                    .homeType(R.foldLink)
            }
            VStack(spacing: 0) {
                ForEach(Array(context.tiles.enumerated()), id: \.element.id) { index, tile in
                    if index > 0 {
                        Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
                    }
                    HomeRemoraFoldLine(model: model, ui: ui, reads: reads, tile: tile, now: context.now,
                                       pickedUp: tile.session.lastActivityAt > (context.brief?.startedAt ?? .distantFuture))
                }
            }
            .padding(.vertical, R.foldLinesPadding)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.block).fill(LoomTheme.Surface.card))
            .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.block)
                .strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
            .depth(LoomTheme.Elevation.card)
            .padding(.top, R.foldLinesTop)
        }
    }
}

private struct HomeRemoraFoldLine: View {
    let model: CatalogModel
    let ui: HomeRemoraUI
    let reads: HomeRemoraReads
    let tile: HomeRemoraTile
    let now: Date
    let pickedUp: Bool

    var body: some View {
        let session = tile.session
        HStack(spacing: R.foldColumnGap) {
            Button { model.select(tile.id) } label: {
                HStack(spacing: R.foldColumnGap) {
                    tick.frame(width: R.foldTick).accessibilityHidden(true)
                    HStack(spacing: R.tileHeadGap) {
                        if let name = session.projectName { ProjectMarkView(name: name, tone: session.tone, size: .chip) }
                        Text(session.projectName ?? "").homeType(R.foldMeta).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .frame(width: R.foldProject, alignment: .leading)
                    HStack(spacing: R.foldWhatGap) {
                        Text(session.title).homeType(R.foldText).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                        Text(stateLine).homeType(R.foldText).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(session.projectName ?? "Project"), \(session.title), \(pickedUp ? "picked up" : "not picked up")")
            trailing
        }
        .padding(.leading, R.foldPaddingLeading).padding(.trailing, R.foldPaddingTrailing)
        .frame(height: R.foldLineHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-remora-fold-line")
    }

    private var stateLine: String {
        if let next = tile.next, !pickedUp { return "Next: " + next }
        return HomeRemoraTiles.stateText(tile.session.indicator, lastActivityAt: tile.session.lastActivityAt, now: now)
    }

    @ViewBuilder
    private var tick: some View {
        if pickedUp {
            Image(systemName: "checkmark").font(R.tickGlyph.font).foregroundStyle(LoomTheme.Text.secondaryStyle)
        } else {
            Circle().strokeBorder(LoomTheme.Text.tertiaryStyle, lineWidth: R.foldRingWidth).frame(width: R.foldRing, height: R.foldRing)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if pickedUp {
            Text(LoomDateFormat.time24(tile.session.lastActivityAt)).homeType(R.foldMeta).foregroundStyle(LoomTheme.Text.tertiaryStyle)
        } else if let result = ui.placed[tile.id] {
            Text(HomeRemoraText.placed(result)).homeType(R.foldMeta).foregroundStyle(LoomTheme.Text.secondaryStyle)
        } else if let draft = tile.draft {
            HomeRemoraPutInDraft(model: model, ui: ui, reads: reads, sessionID: tile.id, line: draft)
        }
    }
}
