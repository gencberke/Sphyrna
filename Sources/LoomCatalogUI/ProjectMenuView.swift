import LoomCore
import Observation
import SwiftUI

// The project menu as the reference draws it (`pmenu`, DESIGN §10 Project menu, §6 Project colour and Controls → Menus and
// pickers), in the window's host: 276 wide, below the ⋯ and trailing-aligned, the project's name as a label, rows of 28 with the
// pill, notes under the rows that need them, and Color as the tone's name over a row of seven swatches. Its content is
// `ProjectMenuPlan` (pure, tested, shared with the right-click menu, which stays native).

// MARK: The swatch row

/// The seven swatches of the Color row: the six tones in the palette's order, then None. Pure, so the order, the current one and the
/// names are tested without a view.
enum ProjectSwatchRow {
    struct Item: Equatable {
        /// nil is None.
        let tone: ProjectTone?
        let name: String
        let isCurrent: Bool
    }

    static let none = "None"

    /// `tone` is the project's tone and `isNone` is true when the user chose None. A tone this build does not know is neither, so no
    /// swatch is current.
    static func items(tone: ProjectTone?, isNone: Bool) -> [Item] {
        ProjectTone.allCases.map { Item(tone: $0, name: $0.title, isCurrent: $0 == tone) } + [Item(tone: nil, name: none, isCurrent: isNone)]
    }

    /// The tone's name on the Color row; empty for a tone this build does not know.
    static func currentName(tone: ProjectTone?, isNone: Bool) -> String { items(tone: tone, isNone: isNone).first(where: \.isCurrent)?.name ?? "" }

    /// The index of the current swatch, or nil.
    static func currentIndex(tone: ProjectTone?, isNone: Bool) -> Int? { items(tone: tone, isNone: isNone).firstIndex(where: \.isCurrent) }
}

// MARK: Keys

/// What the project menu's keys do. ↑ ↓ move between the rows that can be used (wrapping; the Color row is one stop), ← → move between
/// the swatches while the Color row is the stop, and ↵ or Space uses it: a row runs its action and closes the menu, a swatch sets
/// the tone and leaves the menu open, as the reference's does. Pure.
enum ProjectMenuKeys {
    struct State: Equatable {
        /// The index of the entry under the cursor in the plan.
        var stop: Int?
        /// The swatch the arrow keys are on while the Color row is the stop.
        var swatch = 0
    }

    enum Action: Equatable {
        case start(ManagedSession.Provider)
        case setTone(ProjectTone?)
        case moveUp, moveDown, removeEmpty
    }

    struct Outcome: Equatable {
        var state: State
        var action: Action?
        var closes = false
        var handled = false
    }

    /// The entries the cursor can stand on: a new session that is on, Color, a move that is on, and Remove when it is on.
    static func stops(_ plan: ProjectMenuPlan) -> [Int] {
        plan.entries.indices.filter { index in
            switch plan.entries[index] {
            case .start(_, _, let enabled), .moveUp(let enabled), .moveDown(let enabled), .removeEmpty(let enabled): enabled
            case .color: true
            case .note, .divider: false
            }
        }
    }

    /// The action of a row (nil for Color, which acts through its swatches).
    static func action(of entry: ProjectMenuPlan.Entry) -> Action? {
        switch entry {
        case .start(let provider, _, _): .start(provider)
        case .moveUp: .moveUp
        case .moveDown: .moveDown
        case .removeEmpty: .removeEmpty
        case .color, .note, .divider: nil
        }
    }

    /// `currentSwatch` is where the swatch cursor starts when it reaches the Color row (the current tone, else the first).
    static func resolve(_ key: InkKey, plan: ProjectMenuPlan, state: State, currentSwatch: Int?) -> Outcome {
        var outcome = Outcome(state: state)
        let stops = stops(plan)
        let onColor = state.stop.map { plan.entries.indices.contains($0) && plan.entries[$0] == .color } ?? false
        switch key {
        case .down, .up:
            guard let next = ComposerPopoverKeys.cursor(from: state.stop.flatMap(stops.firstIndex(of:)), delta: key == .down ? 1 : -1,
                                                        count: stops.count).map({ stops[$0] }) else { return outcome }
            outcome.state.stop = next
            if plan.entries[next] == .color { outcome.state.swatch = currentSwatch ?? 0 }
        case .left, .right:
            guard onColor else { return outcome }
            let last = ProjectTone.allCases.count
            outcome.state.swatch = min(max(state.swatch + (key == .right ? 1 : -1), 0), last)
        case .return, .space:
            guard let stop = state.stop, plan.entries.indices.contains(stop) else { return outcome }
            if onColor {
                outcome.action = .setTone(ProjectTone.allCases.indices.contains(state.swatch) ? ProjectTone.allCases[state.swatch] : nil)
            } else if let action = action(of: plan.entries[stop]) {
                outcome.action = action
                outcome.closes = true
            } else {
                return outcome
            }
        case .escape: return outcome
        }
        outcome.handled = true
        return outcome
    }
}

/// The menu's cursor: the row under the pointer or the arrow keys. The button that opens the menu holds it, because the host (not
/// the menu) reads the keys.
@MainActor @Observable
final class ProjectMenuCursor {
    var state = ProjectMenuKeys.State()
}

// MARK: Actions

/// What a row does. The native menus (`ProjectActionsMenu`) make the same calls.
@MainActor
enum ProjectMenuActions {
    static func run(_ action: ProjectMenuKeys.Action, model: CatalogModel, projectID: UUID) {
        switch action {
        case .start(let provider):
            NewConversationAction.listed(on: model).first { $0.provider == provider }?.perform(on: model, projectID: projectID)
        case .setTone(let tone): Task { await model.setProjectTone(projectID, tone) }
        case .moveUp: Task { await model.moveProject(projectID, by: -1) }
        case .moveDown: Task { await model.moveProject(projectID, by: 1) }
        case .removeEmpty: Task { await model.removeProject(projectID) }
        }
    }
}

// MARK: The button

/// A project's ⋯ (the sidebar head's and the project page's): an icon button that opens the project menu in the window's host. The
/// right-click menu stays the native `ProjectActionsMenu`. VoiceOver reads a button that opens a menu.
struct ProjectMenuButton: View {
    let model: CatalogModel
    let project: CatalogProject
    let origin: InkOpenState.MenuOrigin
    var style = ChromeButtonStyle()
    var help = "Project actions"
    @State private var cursor = ProjectMenuCursor()

    var body: some View {
        let isOpen = model.inkOpenState.menuBinding(projectID: project.id, origin: origin)
        let spot = InkOpeners.placement(.projectMenu, onDraft: false) ?? InkOpeners.Spot(side: .below, alignment: .trailing)
        Button { isOpen.wrappedValue.toggle() } label: {
            InkIcon(.more, size: LoomTheme.Icon.compact)
        }
        .buttonStyle(style)
        .fixedSize()
        .help(help)
        .accessibilityLabel("Actions for \(project.name)")
        .accessibilityHint("Opens a menu")
        .accessibilityIdentifier(origin == .page ? "project-actions" : "sidebar-project-actions")
        .inkPopover(isPresented: isOpen, id: "project-menu-\(origin.rawValue)", label: "Actions for \(project.name)", side: spot.side,
                    alignment: spot.alignment, keys: { key in handle(key, isOpen: isOpen) }, content: {
            ProjectMenuView(model: model, projectID: project.id, cursor: cursor) { isOpen.wrappedValue = false }
        })
        .onChange(of: isOpen.wrappedValue) { _, shown in if !shown { cursor.state = ProjectMenuKeys.State() } }
        // A menu does not outlive its page: coming back to it finds it shut.
        .onDisappear { if model.inkOpenState.projectMenu?.projectID == project.id { model.inkOpenState.projectMenu = nil } }
    }

    private func handle(_ key: InkKey, isOpen: Binding<Bool>) -> Bool {
        guard let current = model.projects.first(where: { $0.id == project.id }) else { return false }
        let plan = ProjectMenuPlan.make(model: model, project: current)
        let outcome = ProjectMenuKeys.resolve(key, plan: plan, state: cursor.state,
                                              currentSwatch: ProjectSwatchRow.currentIndex(tone: current.tone, isNone: current.colorIsNone))
        cursor.state = outcome.state
        if let action = outcome.action { ProjectMenuActions.run(action, model: model, projectID: current.id) }
        if outcome.closes { isOpen.wrappedValue = false }
        return outcome.handled
    }
}

// MARK: The menu

struct ProjectMenuView: View {
    let model: CatalogModel
    let projectID: UUID
    let cursor: ProjectMenuCursor
    let close: () -> Void

    private typealias H = LoomTheme.Host

    var body: some View {
        if let project = model.projects.first(where: { $0.id == projectID }) {
            let plan = ProjectMenuPlan.make(model: model, project: project)
            VStack(alignment: .leading, spacing: 0) {
                Text(project.name).draftType(LoomTheme.InkType.label).foregroundStyle(LoomTheme.OnPopover.placeholder)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, H.labelAside).padding(.top, H.labelTop).padding(.bottom, H.labelBottom)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(plan.entries.enumerated()), id: \.offset) { index, entry in
                    entryView(entry, index: index, project: project)
                }
            }
            .padding(H.menuInset)
            .frame(width: H.menuWidth)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("project-menu")
        }
    }

    @ViewBuilder
    private func entryView(_ entry: ProjectMenuPlan.Entry, index: Int, project: CatalogProject) -> some View {
        switch entry {
        case .start(let provider, let title, let enabled):
            row(index: index, title: title, enabled: enabled, action: .start(provider)) {
                ProviderIcon(provider: provider, size: LoomTheme.Layout.harnessMarkMenu)
                    .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
            }
        case .note(let text):
            Text(text).font(H.noteFont).foregroundStyle(LoomTheme.OnPopover.placeholder)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, H.noteIndent).padding(.trailing, H.noteTrailing).padding(.bottom, H.noteBottom)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .color:
            colorRow(project: project, index: index)
        case .moveUp(let enabled):
            row(index: index, title: "Move Up", enabled: enabled, action: .moveUp) { glyph("arrow.up", enabled: enabled) }
        case .moveDown(let enabled):
            row(index: index, title: "Move Down", enabled: enabled, action: .moveDown) { glyph("arrow.down", enabled: enabled) }
        case .removeEmpty(let enabled):
            row(index: index, title: "Remove Empty Project", enabled: enabled, action: .removeEmpty) { glyph("trash", enabled: enabled) }
        case .divider:
            Rectangle().fill(LoomTheme.Surface.hairline).frame(height: LoomTheme.Line.hairline)
                .padding(.vertical, H.separatorGap).padding(.horizontal, -H.menuInset)
        }
    }

    private func glyph(_ name: String, enabled: Bool) -> some View {
        InkIcon(systemName: name, size: LoomTheme.Icon.navigation)
            .foregroundStyle(enabled ? AnyShapeStyle(LoomTheme.OnPopover.secondary(lit: false)) : AnyShapeStyle(LoomTheme.Text.faint))
    }

    private func row<Icon: View>(index: Int, title: String, enabled: Bool, action: ProjectMenuKeys.Action,
                                 @ViewBuilder icon: () -> Icon) -> some View {
        let lit = enabled && cursor.state.stop == index
        return Button {
            ProjectMenuActions.run(action, model: model, projectID: projectID)
            close()
        } label: {
            HStack(spacing: H.rowGap) {
                icon().frame(width: H.iconColumn).accessibilityHidden(true)
                Text(title).font(H.rowFont).lineLimit(1)
                    .foregroundStyle(enabled ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.OnPopover.placeholder))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, H.rowPaddingH)
            .frame(height: H.rowHeight)
            .background(RowHighlight(state: .resolve(selected: false, hovering: lit, enabled: enabled), radius: H.rowRadius))
            .contentShape(RoundedRectangle(cornerRadius: H.rowRadius))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { inside in
            guard enabled else { return }
            if inside { cursor.state.stop = index } else if cursor.state.stop == index { cursor.state.stop = nil }
        }
        .accessibilityLabel(title)
    }

    // MARK: Color

    /// The Color row with the tone's name at its trailing end, and under it the seven swatches, aligned with the labels.
    private func colorRow(project: CatalogProject, index: Int) -> some View {
        let items = ProjectSwatchRow.items(tone: project.tone, isNone: project.colorIsNone)
        let lit = cursor.state.stop == index
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: H.rowGap) {
                glyph("square.grid.2x2", enabled: true).frame(width: H.iconColumn).accessibilityHidden(true)
                Text("Color").font(H.rowFont).foregroundStyle(LoomTheme.Text.primary)
                Spacer(minLength: 0)
                Text(ProjectSwatchRow.currentName(tone: project.tone, isNone: project.colorIsNone))
                    .font(H.toneNameFont).foregroundStyle(LoomTheme.OnPopover.placeholder)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, H.rowPaddingH)
            .frame(height: H.rowHeight)
            .background(RowHighlight(state: .resolve(selected: false, hovering: lit), radius: H.rowRadius))
            .onHover { inside in
                if inside { cursor.state.stop = index } else if cursor.state.stop == index { cursor.state.stop = nil }
            }
            HStack(spacing: H.swatchGap) {
                ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                    ProjectSwatchButton(item: item, focused: lit && cursor.state.swatch == position) {
                        cursor.state.stop = index
                        cursor.state.swatch = position
                        ProjectMenuActions.run(.setTone(item.tone), model: model, projectID: projectID)
                    }
                }
            }
            .padding(.leading, H.swatchRowLeading).padding(.trailing, H.swatchRowTrailing)
            .padding(.top, H.swatchRowTop).padding(.bottom, H.swatchRowBottom)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Color of \(project.name)")
            .accessibilityIdentifier("project-menu-colors")
        }
    }
}

// MARK: One swatch

/// A swatch: 18 × 18 at radius 5, filled with its tone at 24 % (Paper 15 %) and a 1 pt inset ring of the tone at 46 %. The current one
/// stands in a gap and a 3 pt ring of the full tone. None is hollow with a diagonal. VoiceOver reads a button named for the tone,
/// selected when it is the current one; the tooltip is the name.
struct ProjectSwatchButton: View {
    let item: ProjectSwatchRow.Item
    /// The keyboard's cursor is on this swatch.
    let focused: Bool
    let action: () -> Void
    private typealias H = LoomTheme.Host

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: H.swatchRadius)
        Button(action: action) {
            ZStack {
                if let tone = item.tone {
                    shape.fill(H.swatchFillTone(tone).color)
                    shape.strokeBorder(H.swatchRingTone(tone).color, lineWidth: H.swatchRingWidth)
                    if item.isCurrent {
                        // The gap (1.5) is the popover showing between the swatch and a ring of the full tone out to 3.
                        RoundedRectangle(cornerRadius: H.swatchRadius + H.swatchCurrentRing)
                            .strokeBorder(LoomTheme.ProjectColor.stripe(tone), lineWidth: H.swatchCurrentRing - H.swatchGapRing)
                            .padding(-H.swatchCurrentRing)
                    }
                } else {
                    shape.strokeBorder(H.noneEdgeTone.color, lineWidth: H.swatchRingWidth)
                    Rectangle().fill(H.noneEdgeTone.color)
                        .frame(width: H.swatchSide - 2 * H.noneDiagonalInset, height: H.noneDiagonalWidth)
                        .rotationEffect(.degrees(-45))
                    if item.isCurrent {
                        RoundedRectangle(cornerRadius: H.swatchRadius + H.swatchCurrentRing)
                            .strokeBorder(LoomTheme.Text.primary, lineWidth: H.swatchCurrentRing - H.swatchGapRing)
                            .padding(-H.swatchCurrentRing)
                    }
                }
            }
            .frame(width: H.swatchSide, height: H.swatchSide)
            .padding(H.swatchCurrentRing)
            .controlFocusRing(visible: focused, radius: H.swatchRadius + H.swatchCurrentRing)
            .padding(-H.swatchCurrentRing)
            // It answers over 24 × 24 while drawn at 18 × 18.
            .contentShape(Rectangle().inset(by: -(H.swatchHit - H.swatchSide) / 2))
        }
        .buttonStyle(.plain)
        .help(item.name)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(item.isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("project-menu-color-\(item.name.lowercased())")
    }
}
