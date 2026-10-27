import LoomCore
import Observation
import SwiftUI

// The one model chip of the composer's bar and its one popover (D-75, DESIGN §11): the models grouped by harness, then the
// effort. The draft's composer and the session's own composer draw the same pieces with their own actions.

// MARK: What the chip and the popover show

/// What the model chip and its popover show, for the draft and the live session alike.
struct ComposerModelPicker: Equatable {
    /// The chip's name for the model, and the lighter word after it (nil: no effort known).
    var modelTitle: String
    var effortTitle: String?
    /// The models after Default, and the model choice (nil or `default`: Default).
    var rows: [ComposerBarText.ModelRow]
    var chosenModel: String?
    /// The effort levels the model takes, lowest first (empty: it has no effort), and the level chosen or reported.
    var levels: [String]
    var chosenLevel: String?
    /// Reset is offered when the effort differs from what it would be without a choice of the user.
    var canResetEffort: Bool
    var resetHelp = "Back to the effort this session opened with"
    /// The note after Claude Code's name ("this session") and after Codex's ("in a new session"; on the new-session page of a
    /// build that cannot start Codex, the build's own words).
    var claudeNote = ComposerModelNotes.thisSession
    var codexNote = ComposerModelNotes.inNewSession

    /// The effort as the chip's lighter word: none for a model that takes no effort.
    var chipEffortWord: String? { levels.isEmpty ? nil : effortTitle }

    /// The id of the chosen row: `default` while no model is chosen.
    var chosenID: String { ComposerBarText.isDefaultModelChosen(chosenModel) ? Self.defaultID : (chosenModel ?? Self.defaultID) }

    static let defaultID = "default"
}

/// The words the popover owns. A model's note is keyed by its alias and is read from `ModelCatalog` (LoomCore); a model the
/// catalog does not know has none.
enum ComposerModelNotes {
    static let thisSession = "this session"
    static let inNewSession = "in a new session"
    /// The tooltip of the other harness's group on a live session.
    static let keepsItsHarness = "A session keeps its harness: Codex models start a new Codex session"

    static func note(forAlias alias: String) -> String? { ModelCatalog.claudeNote(forAlias: alias) }
}

/// One harness in the popover: its mark, its name, its note in mono and its rows.
struct ComposerModelGroup: Equatable, Identifiable {
    var provider: ManagedSession.Provider
    var name: String
    var note: String
    var rows: [ComposerPickRow]
    /// A live group's rows can be picked; the other harness's are dimmed.
    var isLive: Bool
    var help: String?

    var id: String { provider.rawValue }
}

extension ComposerModelPicker {
    /// The groups, the session's harness first. Claude Code is the only harness a session runs in this build, so its group is
    /// live and Codex's is static and dimmed. Codex's rows are `codex`, the catalog's list (`ModelCatalog`): today's names
    /// until a probe has read the real ones, and no group at all when the harness is switched off (an empty list).
    func groups(codex: [ModelCatalogEntry] = ModelCatalog.codexFallback) -> [ComposerModelGroup] {
        let defaultChosen = ComposerBarText.isDefaultModelChosen(chosenModel)
        var claudeRows = [ComposerPickRow(id: Self.defaultID, title: "Default",
                                          subtitle: ComposerModelNotes.note(forAlias: Self.defaultID), checked: defaultChosen)]
        claudeRows += rows.map {
            ComposerPickRow(id: $0.value, title: $0.title, subtitle: ComposerModelNotes.note(forAlias: $0.value),
                            checked: !defaultChosen && chosenModel == $0.value)
        }
        let codexRows = codex.map {
            ComposerPickRow(id: "codex:\($0.id)", title: $0.title, subtitle: $0.note, checked: false, isEnabled: false)
        }
        var groups = [ComposerModelGroup(provider: .claude, name: "Claude Code", note: claudeNote, rows: claudeRows, isLive: true, help: nil)]
        if !codexRows.isEmpty {
            groups.append(ComposerModelGroup(provider: .codex, name: "Codex", note: codexNote, rows: codexRows, isLive: false,
                                             help: ComposerModelNotes.keepsItsHarness))
        }
        return groups
    }
}

// MARK: Keys

/// What the popover's keys do, pure so each rule is tested without a view: ↑ ↓ move between the models that can be picked
/// (wrapping), ← → step the effort (stopping at the ends), ↵ picks the highlighted model if it is not the chosen one and closes.
enum ComposerPopoverKeys {
    /// The row under the cursor after a step of `delta`; with no cursor, ↓ starts at the first row and ↑ at the last.
    static func cursor(from current: Int?, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return delta > 0 ? 0 : count - 1 }
        return ((current + delta) % count + count) % count
    }

    /// The model ↵ picks: the highlighted one when it is not already the chosen one; nil when it only closes.
    static func pickOnDone(cursor: String?, chosen: String?) -> String? {
        guard let cursor, cursor != chosen else { return nil }
        return cursor
    }
}

/// Where the stops of the slider sit and which one a point is nearest to. Pure, so it is tested without a view.
enum EffortSliderMath {
    /// The x of each stop's centre, from the first to the last, in a track `width` wide with a thumb of `thumb`.
    static func positions(count: Int, width: CGFloat, thumb: CGFloat, inset: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        let first = inset + thumb / 2
        let span = max(0, width - 2 * first)
        guard count > 1 else { return [first + span / 2] }
        return (0..<count).map { first + span * CGFloat($0) / CGFloat(count - 1) }
    }

    /// The stop nearest to `x`.
    static func nearest(to x: CGFloat, in positions: [CGFloat]) -> Int? {
        positions.indices.min { abs(positions[$0] - x) < abs(positions[$1] - x) }
    }

    /// The stop a step of `delta` leads to from `selected` (none selected: ← starts at the last stop, → at the first); nil
    /// when the step leaves the track or changes nothing.
    static func step(from selected: Int?, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let target = min(max((selected ?? (delta > 0 ? -1 : count)) + delta, 0), count - 1)
        return target == selected ? nil : target
    }
}

// MARK: The chip

/// The one model chip (D-75): the harness's mark, the model, the effort as a lighter word and a chevron. One target, one
/// popover, in the window's host with its trailing edge on the chip's: above it in the live composer, below it on the draft page
/// (`InkOpeners`). In this build every session runs on Claude Code.
struct ComposerModelChip: View {
    var picker: ComposerModelPicker
    var identifier: String
    var help: String
    /// The draft page's chip opens its popover below it (DESIGN §8); the live composer's dock opens it above.
    var onDraft = false
    /// Gives the keyboard back to the composer's text when the popover closes.
    var restoreFocus: (() -> Void)?
    @Binding var isOpen: Bool
    /// `nil`: Default.
    var onPickModel: (String?) -> Void
    var onPickEffort: (String) -> Void
    var onResetEffort: () -> Void

    static let defaultID = ComposerModelPicker.defaultID
    @State private var cursor = ComposerModelCursor()

    var body: some View {
        let spot = InkOpeners.placement(.model, onDraft: onDraft) ?? InkOpeners.Spot(side: .above, alignment: .trailing)
        Button { isOpen.toggle() } label: {
            HStack(spacing: LoomTheme.Composer.chipPartGap) {
                ProviderIcon(provider: .claude, size: LoomTheme.Composer.harnessMark)
                Text(picker.modelTitle).font(LoomTheme.Composer.barFont).lineLimit(1).truncationMode(.tail)
                if let word = picker.chipEffortWord {
                    Text(word).font(LoomTheme.Composer.effortWordFont).foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1)
                }
                Image(systemName: "chevron.down").font(LoomTheme.Composer.chevron).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            }
            .padding(.leading, LoomTheme.Composer.modelChipPaddingLeading).padding(.trailing, LoomTheme.Composer.modelChipPaddingTrailing)
            .frame(minHeight: LoomTheme.Composer.controlSide)
            .contentShape(Rectangle())
        }
        .buttonStyle(ComposerChipStyle(key: identifier))
        .help(help)
        .accessibilityLabel(picker.chipEffortWord.map { "Model, \(picker.modelTitle), effort \($0)" } ?? "Model, \(picker.modelTitle)")
        .accessibilityIdentifier(identifier)
        .inkPopover(isPresented: $isOpen, id: identifier, label: "Model and effort", side: spot.side, alignment: spot.alignment,
                    keys: { key in
            let outcome = ComposerModelPopover.resolve(key, picker: picker, cursor: cursor.id)
            cursor.id = outcome.cursor
            if let level = outcome.effort { onPickEffort(level) }
            if let model = outcome.pickModel { onPickModel(model == ComposerModelPicker.defaultID ? nil : model) }
            if outcome.done { isOpen = false }
            return outcome.handled
        }, restoreFocus: restoreFocus, content: {
            ComposerModelPopover(picker: picker, identifier: identifier, onPickModel: onPickModel, onPickEffort: onPickEffort,
                                 onResetEffort: onResetEffort, cursor: cursor) { isOpen = false }
        })
        .onChange(of: isOpen) { _, open in if !open { cursor.id = nil } }
    }
}

/// The row under the pointer or the arrow keys in the model popover. The chip holds it, because the host (not the popover) reads
/// the keys (`ComposerModelPopover.resolve`).
@MainActor @Observable
final class ComposerModelCursor {
    var id: String?
}

// MARK: The popover

/// The model popover (332 wide): the groups with their rows, the effort and the keys line.
struct ComposerModelPopover: View {
    var picker: ComposerModelPicker
    var identifier: String
    var onPickModel: (String?) -> Void
    var onPickEffort: (String) -> Void
    var onResetEffort: () -> Void
    /// The row under the pointer or the arrow keys; it starts on the chosen model. A test hosting the popover alone gets its own.
    var cursor = ComposerModelCursor()
    /// Closes the popover. The host reads the keys, so ↵ closes through the chip; a host that closes it another way passes its own.
    var onDone: () -> Void
    /// The level under the thumb while it is dragged.
    @State private var preview: Int?

    private var groups: [ComposerModelGroup] { picker.groups(codex: ModelCatalog.shared.models(for: .codex)) }
    private var chosenIndex: Int? { Self.chosenIndex(picker) }

    private static func pickableIDs(_ picker: ComposerModelPicker) -> [String] {
        picker.groups().filter(\.isLive).flatMap { $0.rows.filter(\.isEnabled).map(\.id) }
    }

    private static func chosenIndex(_ picker: ComposerModelPicker) -> Int? { picker.chosenLevel.flatMap(picker.levels.firstIndex(of:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 {
                        Rectangle().fill(LoomTheme.Surface.hairline).frame(height: LoomTheme.Line.hairline)
                            .padding(.vertical, LoomTheme.Composer.groupSeparation)
                    }
                    groupView(group)
                }
            }
            effortSection
            keysLine
        }
        .padding(LoomTheme.Composer.modelPopoverInset)
        .frame(width: LoomTheme.Composer.modelPopoverWidth)
        .onAppear { if cursor.id == nil { cursor.id = picker.chosenID } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifier)-list")
    }

    // MARK: Groups and rows

    private func groupView(_ group: ComposerModelGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LoomTheme.Composer.groupHeadGap) {
                ProviderIcon(provider: group.provider, size: LoomTheme.Composer.harnessMark)
                    .opacity(group.isLive ? 1 : LoomTheme.Opacity.disabled)
                Text(group.name).font(group.isLive ? LoomTheme.Composer.groupNameFont : LoomTheme.Composer.groupDimmedNameFont)
                    .foregroundStyle(group.isLive ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.OnPopover.placeholder))
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
                Text(group.note).font(LoomTheme.Composer.groupNoteFont).foregroundStyle(LoomTheme.OnPopover.placeholder).lineLimit(1)
                    .accessibilityIdentifier("\(identifier)-group-\(group.id)-note")
            }
            .padding(.horizontal, LoomTheme.Composer.groupHeadPaddingH).frame(height: LoomTheme.Composer.groupHeadHeight)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(group.rows) { row in
                if group.isLive { liveRow(row) } else { dimmedRow(row, help: group.help) }
            }
        }
    }

    private func liveRow(_ row: ComposerPickRow) -> some View {
        let lit = cursor.id == row.id || LookEvidence.forcesHover("pick:\(row.id)")
        return Button {
            cursor.id = row.id
            onPickModel(row.id == ComposerModelPicker.defaultID ? nil : row.id)
        } label: {
            rowLabel(row, name: LoomTheme.Composer.modelNameFont, nameStyle: AnyShapeStyle(LoomTheme.Text.primary),
                     noteStyle: AnyShapeStyle(LoomTheme.OnPopover.secondary(lit: lit)))
                .background(RowHighlight(state: .resolve(selected: false, hovering: lit), radius: LoomTheme.Composer.modelRowRadius))
                .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Composer.modelRowRadius))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { cursor.id = row.id } else if cursor.id == row.id { cursor.id = nil }
        }
        .accessibilityLabel(row.subtitle.map { "\(row.title), \($0)" } ?? row.title)
        .accessibilityAddTraits(row.checked ? .isSelected : [])
        .accessibilityIdentifier("\(identifier)-list-\(row.id)")
    }

    /// The other harness's row: no button, no pill, name and note quiet.
    private func dimmedRow(_ row: ComposerPickRow, help: String?) -> some View {
        rowLabel(row, name: LoomTheme.Composer.modelDimmedNameFont, nameStyle: AnyShapeStyle(LoomTheme.OnPopover.placeholder),
                 noteStyle: AnyShapeStyle(LoomTheme.Text.faint))
            .help(help ?? "")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(row.title), \(row.subtitle ?? ""), not available here")
            .accessibilityIdentifier("\(identifier)-list-\(row.id)")
    }

    private func rowLabel(_ row: ComposerPickRow, name: Font, nameStyle: AnyShapeStyle, noteStyle: AnyShapeStyle) -> some View {
        HStack(spacing: LoomTheme.Composer.modelColumnGap) {
            Text(row.title).font(name).foregroundStyle(nameStyle).lineLimit(1).fixedSize()
                .frame(minWidth: LoomTheme.Composer.modelNameColumn, alignment: .leading)
            if let note = row.subtitle {
                Text(note).font(LoomTheme.Composer.modelNoteFont).foregroundStyle(noteStyle).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            ZStack {
                if row.checked {
                    Image(systemName: "checkmark").font(LoomTheme.Composer.modelCheck).foregroundStyle(LoomTheme.Text.primary)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: LoomTheme.Composer.modelCheckSlot)
        }
        .padding(.horizontal, LoomTheme.Composer.modelRowPaddingH)
        .frame(height: LoomTheme.Composer.modelRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Effort

    private var effortSection: some View {
        let shown = preview ?? chosenIndex
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LoomTheme.Composer.effortHeadGap) {
                Text("Effort").font(LoomTheme.Composer.effortLabelFont).foregroundStyle(LoomTheme.OnPopover.placeholder)
                if !picker.levels.isEmpty {
                    Text(shown.map { ComposerBarText.effortLabel(picker.levels[$0]) } ?? "Default")
                        .font(LoomTheme.Composer.effortNameFont).foregroundStyle(LoomTheme.Text.primary)
                        .accessibilityIdentifier("\(identifier)-slider-name")
                }
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
                Button("Reset", action: onResetEffort)
                    .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small)).disabled(!picker.canResetEffort)
                    .help(picker.resetHelp)
                    .accessibilityLabel("Reset effort")
                    .accessibilityIdentifier("\(identifier)-slider-reset")
            }
            if picker.levels.isEmpty {
                Text("This model has no effort setting.").font(LoomTheme.Composer.effortNoneFont)
                    .foregroundStyle(LoomTheme.OnPopover.placeholder)
                    .padding(.top, LoomTheme.Composer.effortHeadGap)
                    .accessibilityIdentifier("\(identifier)-slider-none")
            } else {
                ComposerEffortSlider(levels: picker.levels, selected: chosenIndex, preview: $preview, identifier: "\(identifier)-slider") { index in
                    onPickEffort(picker.levels[index])
                }
                .padding(.top, LoomTheme.Composer.effortSliderTop)
                levelNames(shown)
            }
        }
        .padding(.top, LoomTheme.Composer.effortSectionTop).padding(.horizontal, LoomTheme.Composer.effortSectionH)
        .padding(.bottom, LoomTheme.Composer.effortSectionBottom)
        .overlay(alignment: .top) {
            Rectangle().fill(LoomTheme.Surface.hairline).frame(height: LoomTheme.Line.hairline)
        }
        .padding(.top, LoomTheme.Composer.effortSectionGap)
    }

    /// The names under the track: the model's levels, spread over its width, the shown one in primary.
    private func levelNames(_ shown: Int?) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(picker.levels.enumerated()), id: \.offset) { index, level in
                if index > 0 { Spacer(minLength: 0) }
                Text(level).font(LoomTheme.Composer.effortLevelFont)
                    .foregroundStyle(index == shown ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.OnPopover.placeholder))
            }
        }
        .padding(.top, LoomTheme.Composer.effortLevelsTop)
        .accessibilityHidden(true)
    }

    private var keysLine: some View {
        HStack(spacing: LoomTheme.Composer.keysLineGap) {
            ForEach(Array(Self.keys.enumerated()), id: \.offset) { _, item in
                HStack(spacing: LoomTheme.Composer.hintKeyGap) {
                    Text(item.key).foregroundStyle(LoomTheme.Text.secondaryStyle).fontWeight(.medium)
                    Text(item.words)
                }
            }
            Spacer(minLength: 0)
        }
        .font(LoomTheme.Composer.keysLineFont).foregroundStyle(LoomTheme.OnPopover.placeholder)
        .padding(.top, LoomTheme.Composer.keysLinePaddingTop).padding(.bottom, LoomTheme.Composer.keysLinePaddingBottom)
        .padding(.horizontal, LoomTheme.Composer.effortSectionH)
        .overlay(alignment: .top) { Rectangle().fill(LoomTheme.Surface.hairline).frame(height: LoomTheme.Line.hairline) }
        .padding(.top, LoomTheme.Composer.keysLineTop)
        .accessibilityHidden(true)
    }

    /// The keys line: "↑↓ model  ←→ effort  ↵ done".
    static let keys: [(key: String, words: String)] = [("\u{2191}\u{2193}", "model"), ("\u{2190}\u{2192}", "effort"), ("\u{21B5}", "done")]

    // MARK: Keys

    /// What a key does in the popover. Pure, so each rule is tested without a view.
    struct Outcome: Equatable {
        /// The row under the cursor after the key.
        var cursor: String?
        /// A level the key sets (← →).
        var effort: String?
        /// A model ↵ picks (the highlighted one, when it is not already the chosen one).
        var pickModel: String?
        /// ↵ closes the popover.
        var done = false
        var handled = false
    }

    /// ↑ ↓ move between the models that can be picked (wrapping), ← → step the effort (stopping at the ends), ↵ picks the
    /// highlighted model if it is not the chosen one and closes. Space and the other keys are not used.
    static func resolve(_ key: InkKey, picker: ComposerModelPicker, cursor: String?) -> Outcome {
        var outcome = Outcome(cursor: cursor)
        switch key {
        case .down, .up:
            let ids = pickableIDs(picker)
            let delta = key == .down ? 1 : -1
            outcome.cursor = ComposerPopoverKeys.cursor(from: cursor.flatMap(ids.firstIndex(of:)), delta: delta, count: ids.count).map { ids[$0] }
        case .left, .right:
            if let target = EffortSliderMath.step(from: chosenIndex(picker), delta: key == .right ? 1 : -1, count: picker.levels.count) {
                outcome.effort = picker.levels[target]
            }
        case .return:
            outcome.pickModel = ComposerPopoverKeys.pickOnDone(cursor: cursor, chosen: picker.chosenID)
            outcome.done = true
        case .space, .escape: return outcome
        }
        outcome.handled = true
        return outcome
    }
}

// MARK: The track

/// The segmented track with a thumb: a click or a drag picks the nearest stop (the level is set when the pointer is
/// released); the popover's ← → step it from the keyboard. Each stop is a level the model takes.
struct ComposerEffortSlider: View {
    var levels: [String]
    var selected: Int?
    @Binding var preview: Int?
    var identifier: String
    var onCommit: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let side = LoomTheme.Composer.effortThumb
            let positions = EffortSliderMath.positions(count: levels.count, width: proxy.size.width, thumb: side, inset: 0)
            let index = preview ?? selected
            ZStack(alignment: .leading) {
                // The track runs from the first stop to the last; the thumb's centre never leaves it.
                Capsule().fill(LoomTheme.Composer.effortTrack)
                    .frame(height: LoomTheme.Composer.effortTrackThickness).padding(.horizontal, side / 2)
                if let index, positions.indices.contains(index) {
                    Capsule().fill(LoomTheme.Composer.effortFill)
                        .frame(width: max(0, positions[index] - side / 2), height: LoomTheme.Composer.effortTrackThickness)
                        .padding(.leading, side / 2)
                }
                ForEach(Array(positions.enumerated()), id: \.offset) { stop, x in
                    Circle().fill(index.map { stop <= $0 } == true ? LoomTheme.Composer.effortDotOnFill : LoomTheme.Composer.effortDotOffFill)
                        .frame(width: LoomTheme.Composer.effortDot, height: LoomTheme.Composer.effortDot)
                        .position(x: x, y: proxy.size.height / 2)
                }
                if let index, positions.indices.contains(index) {
                    Circle().fill(LoomTheme.Composer.effortThumbFill).frame(width: side, height: side)
                        .position(x: positions[index], y: proxy.size.height / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in preview = EffortSliderMath.nearest(to: value.location.x, in: positions) }
                .onEnded { value in
                    preview = nil
                    if let stop = EffortSliderMath.nearest(to: value.location.x, in: positions) { onCommit(stop) }
                })
        }
        .frame(height: LoomTheme.Composer.effortTrackHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Effort")
        .accessibilityValue(selected.map { ComposerBarText.effortLabel(levels[$0]) } ?? "Default")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 1 : -1
            if let target = EffortSliderMath.step(from: selected, delta: delta, count: levels.count) { onCommit(target) }
        }
        .accessibilityIdentifier("\(identifier)-track")
    }
}
