import LoomCore
import SwiftUI

// The composer bar's three pickers (D-63, after Codex's): the mode list, the model list and the effort slider. The draft's
// composer and the session's own composer both draw them, with the same pieces and their own actions.

// MARK: Look of a mode

/// A permission mode's icon and colour: minimal outline glyphs and soft tones (`LoomTheme.Composer.ModeTone`).
enum ComposerModeLook {
    /// `raw` is the mode as Loom stores it. A word that is not one of ours gets the plain shield.
    static func symbol(forRaw raw: String?) -> String {
        switch raw.flatMap(ClaudePermissionMode.init(rawValue:)) {
        case .ask?: "bubble.left"
        case .askBeforeEdits?: "shield"
        case .acceptEdits?: "pencil.line"
        case .auto?: "bolt"
        case .fullAccess?: "exclamationmark.circle"
        case .plan?: "list.bullet.rectangle"
        case nil: "shield"
        }
    }

    static func color(forRaw raw: String?) -> Color { LoomTheme.Composer.ModeTone.color(forRaw: raw) }
}

// MARK: Chip parts

extension View {
    /// The shared pill under the pointer, for the bar's chips (the popovers' own rows draw it through `ComposerPickList`).
    func composerChipHover(key: String? = nil) -> some View {
        rowPill(radius: LoomTheme.Composer.chipRadius, key: key)
    }
}

// MARK: Pick list

/// One row of a pick list: an optional icon in its own tone, a title with an optional second line, and a check mark.
struct ComposerPickRow: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String?
    var symbol: String?
    var tint: Color?
    var checked: Bool
    /// A row that cannot be chosen here shows its reason as the second line (Ask on a terminal start: "Chat only").
    var isEnabled = true
}

/// The rows of a popover, as in Codex's model list: a header, rows with a rounded highlight under the pointer or the arrow
/// keys, and a check mark on the chosen one. ↑ and ↓ move, ↵ and Space choose.
struct ComposerPickList: View {
    var header: String?
    var rows: [ComposerPickRow]
    var identifier: String
    var width: CGFloat = LoomTheme.Composer.pickWidth
    var onPick: (String) -> Void
    @State private var highlighted: Int?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header).font(LoomTheme.Composer.pickHeaderFont).foregroundStyle(LoomTheme.OnPopover.placeholder)
                    .padding(.horizontal, LoomTheme.Composer.pickRowPaddingH).frame(height: LoomTheme.Composer.pickHeaderHeight)
                    .accessibilityAddTraits(.isHeader)
            }
            ScrollView {
                VStack(spacing: LoomTheme.Composer.pickRowSpacing) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, index: index)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: LoomTheme.Composer.pickMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(LoomTheme.Composer.pickInset)
        .frame(width: width)
        .background(LoomTheme.Surface.popover)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .return, .space]) { press in handle(press.key) }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func handle(_ key: KeyEquivalent) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        switch key {
        case .downArrow: highlighted = min((highlighted ?? -1) + 1, rows.count - 1)
        case .upArrow: highlighted = max((highlighted ?? rows.count) - 1, 0)
        case .return, .space:
            guard let highlighted, rows.indices.contains(highlighted), rows[highlighted].isEnabled else { return .ignored }
            onPick(rows[highlighted].id)
        default: return .ignored
        }
        return .handled
    }

    private func rowView(_ row: ComposerPickRow, index: Int) -> some View {
        Button { if row.isEnabled { onPick(row.id) } } label: {
            HStack(alignment: row.subtitle == nil ? .center : .top, spacing: LoomTheme.Space.requestPadding) {
                if let symbol = row.symbol {
                    Image(systemName: symbol).font(LoomTheme.Composer.pickIcon)
                        .foregroundStyle(row.isEnabled ? row.tint ?? LoomTheme.Text.secondary : LoomTheme.OnPopover.placeholder)
                        .frame(width: LoomTheme.Composer.pickIconSide, height: LoomTheme.Composer.pickIconSide)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(LoomTheme.Composer.pickTitleFont)
                        .foregroundStyle(row.isEnabled ? row.tint ?? LoomTheme.Text.primary : LoomTheme.OnPopover.placeholder)
                    if let subtitle = row.subtitle {
                        Text(subtitle).font(LoomTheme.Composer.pickSubtitleFont).foregroundStyle(LoomTheme.OnPopover.placeholder)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: LoomTheme.Space.requestPadding)
                if row.checked {
                    Image(systemName: "checkmark").font(LoomTheme.Composer.pickCheck).foregroundStyle(LoomTheme.Text.primary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, LoomTheme.Composer.pickRowPaddingH).padding(.vertical, LoomTheme.Composer.pickRowPaddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RowHighlight(
                state: .resolve(selected: false, hovering: highlighted == index || LookEvidence.forcesHover("pick:\(row.id)"),
                                enabled: row.isEnabled),
                radius: LoomTheme.Composer.pickRowRadius))
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Composer.pickRowRadius))
        }
        .buttonStyle(.plain)
        .disabled(!row.isEnabled)
        .onHover { inside in
            if inside { highlighted = index } else if highlighted == index { highlighted = nil }
        }
        .accessibilityLabel(row.subtitle.map { "\(row.title), \($0)" } ?? row.title)
        .accessibilityAddTraits(row.checked ? .isSelected : [])
        .accessibilityIdentifier("\(identifier)-\(row.id)")
    }
}

// MARK: Mode chip

/// The permission mode on the bar: its icon and name in the mode's tone, and the mode list in a popover. The draft passes a
/// `reset` ("Use the default for this project") when its pick differs from what the project would start in.
struct ComposerModeChip: View {
    /// The mode as Loom stores it; nil while nothing says which mode runs.
    var selected: String?
    var title: String
    var help: String
    var identifier: String
    var reset: (() -> Void)?
    /// Ask works in Chat only: false where the session will start in the terminal, and the row says so.
    var askAllowed = true
    @Binding var isOpen: Bool
    var onPick: (ClaudePermissionMode) -> Void

    var body: some View {
        let tint = selected == nil ? LoomTheme.Composer.modeColor : ComposerModeLook.color(forRaw: selected)
        Button { isOpen.toggle() } label: {
            ComposerChipLabel(symbol: ComposerModeLook.symbol(forRaw: selected), title: title, titleColor: tint)
        }
        .buttonStyle(.plain)
        .composerChipHover()
        .help(help)
        .accessibilityLabel("Permission mode, \(title)")
        .accessibilityIdentifier(identifier)
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            VStack(spacing: 0) {
                ComposerPickList(header: "Permission mode", rows: Self.rows(selected: selected, askAllowed: askAllowed), identifier: "\(identifier)-list") { id in
                    isOpen = false
                    if let mode = ClaudePermissionMode(rawValue: id) { onPick(mode) }
                }
                if let reset {
                    Divider().overlay(LoomTheme.Composer.pickDivider)
                    Button("Use the default for this project") {
                        isOpen = false
                        reset()
                    }
                    .buttonStyle(.plain).font(LoomTheme.Composer.pickSubtitleFont).foregroundStyle(LoomTheme.OnPopover.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LoomTheme.Composer.pickInset + LoomTheme.Composer.pickRowPaddingH)
                    .padding(.vertical, LoomTheme.Composer.pickRowPaddingV)
                    .accessibilityIdentifier("\(identifier)-reset")
                }
            }
            .background(LoomTheme.Surface.popover)
        }
    }

    /// The mode list: the five modes the menus offer, with the chosen one checked. A session in plan mode (not offered) has no check.
    static func rows(selected: String?, askAllowed: Bool = true) -> [ComposerPickRow] {
        ClaudePermissionMode.menuModes.map { mode in
            let blocked = mode == .ask && !askAllowed
            return ComposerPickRow(
                id: mode.rawValue, title: mode.title, subtitle: blocked ? "Chat only" : ComposerBarText.modeDetail(mode),
                symbol: ComposerModeLook.symbol(forRaw: mode.rawValue), tint: ComposerModeLook.color(forRaw: mode.rawValue),
                checked: selected == mode.rawValue, isEnabled: !blocked)
        }
    }
}

// MARK: Model and effort chip

/// What the model chip and its two popovers show, for the draft and the live session alike.
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
}

/// The chip after the model's name: "Sonnet 5.5 High". The model's name opens the model list, the lighter effort word opens
/// the effort slider, and the slider's own model name opens the list again.
struct ComposerModelChip: View {
    var picker: ComposerModelPicker
    var identifier: String
    var help: String
    @Binding var modelOpen: Bool
    @Binding var effortOpen: Bool
    /// `nil`: Default.
    var onPickModel: (String?) -> Void
    var onPickEffort: (String) -> Void
    var onResetEffort: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button { modelOpen.toggle() } label: {
                Text(picker.modelTitle).font(LoomTheme.Composer.barFont).foregroundStyle(LoomTheme.Composer.modelColor)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.leading, LoomTheme.Space.cardH).padding(.trailing, LoomTheme.Space.headerSpacing)
                    .frame(minHeight: LoomTheme.Composer.controlSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).composerChipHover()
            .help(help)
            .accessibilityLabel("Model, \(picker.modelTitle)")
            .accessibilityIdentifier(identifier)
            .popover(isPresented: $modelOpen, arrowEdge: .top) { modelList }
            Button { effortOpen.toggle() } label: {
                HStack(spacing: LoomTheme.Space.headerSpacing) {
                    Text(picker.effortTitle ?? "Effort").font(LoomTheme.Composer.barFont)
                        .foregroundStyle(LoomTheme.Composer.effortColor).lineLimit(1)
                    Image(systemName: "chevron.down").font(LoomTheme.Composer.chevron).foregroundStyle(LoomTheme.Text.tertiary)
                }
                .padding(.leading, LoomTheme.Space.headerSpacing).padding(.trailing, LoomTheme.Space.cardH)
                .frame(minHeight: LoomTheme.Composer.controlSide)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).composerChipHover()
            .help("Effort of \(picker.modelTitle)")
            .accessibilityLabel(picker.effortTitle.map { "Effort, \($0)" } ?? "Effort, not set")
            .accessibilityIdentifier("\(identifier)-effort")
            .popover(isPresented: $effortOpen, arrowEdge: .top) { effortSlider }
        }
    }

    private var modelList: some View {
        ComposerPickList(header: "Select model", rows: Self.rows(picker), identifier: "\(identifier)-list",
                         width: LoomTheme.Composer.pickWidth - 22) { id in
            modelOpen = false
            onPickModel(id == Self.defaultID ? nil : id)
        }
    }

    private var effortSlider: some View {
        ComposerEffortPopover(modelTitle: picker.modelTitle, levels: picker.levels, chosen: picker.chosenLevel,
                              canReset: picker.canResetEffort, resetHelp: picker.resetHelp, identifier: "\(identifier)-slider",
                              onPick: onPickEffort, onReset: onResetEffort) {
            effortOpen = false
            // The model list opens where the slider was, once the slider's popover is gone.
            Task { @MainActor in modelOpen = true }
        }
    }

    static let defaultID = "default"

    /// Default ("Recommended") first, then the models; the chosen one is checked.
    static func rows(_ picker: ComposerModelPicker) -> [ComposerPickRow] {
        let defaultChosen = ComposerBarText.isDefaultModelChosen(picker.chosenModel)
        var rows = [ComposerPickRow(id: defaultID, title: "Default", subtitle: "Recommended", checked: defaultChosen)]
        rows += picker.rows.map { ComposerPickRow(id: $0.value, title: $0.title, checked: !defaultChosen && picker.chosenModel == $0.value) }
        return rows
    }
}

// MARK: Effort popover

/// The effort popover: the level's name on top, the model's name with a chevron that opens the model list, a reset, and the
/// slider.
struct ComposerEffortPopover: View {
    var modelTitle: String
    var levels: [String]
    var chosen: String?
    var canReset: Bool
    var resetHelp: String
    var identifier: String
    var onPick: (String) -> Void
    var onReset: () -> Void
    var onOpenModels: () -> Void
    /// The level under the thumb while it is dragged.
    @State private var preview: Int?

    private var chosenIndex: Int? { chosen.flatMap(levels.firstIndex(of:)) }

    var body: some View {
        let shown = preview ?? chosenIndex
        ZStack(alignment: .topTrailing) {
            VStack(spacing: LoomTheme.Composer.effortSpacing) {
                Text(levels.isEmpty ? "No effort setting" : shown.map { ComposerBarText.effortLabel(levels[$0]) } ?? "Default")
                    .font(LoomTheme.Composer.effortNameFont).foregroundStyle(LoomTheme.Composer.effortNameColor)
                    .accessibilityIdentifier("\(identifier)-name")
                Button(action: onOpenModels) {
                    HStack(spacing: 3) {
                        Text(modelTitle)
                        Image(systemName: "chevron.right").font(LoomTheme.Typography.chevron)
                    }
                    .font(LoomTheme.Composer.effortModelFont).foregroundStyle(LoomTheme.OnPopover.placeholder)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Model, \(modelTitle). Opens the model list")
                .accessibilityIdentifier("\(identifier)-model")
                if levels.isEmpty {
                    Text("\(modelTitle) does not take an effort level.").font(LoomTheme.Composer.pickSubtitleFont)
                        .foregroundStyle(LoomTheme.OnPopover.placeholder).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, LoomTheme.Space.requestPadding)
                } else {
                    ComposerEffortSlider(levels: levels, selected: chosenIndex, preview: $preview, identifier: identifier) { index in
                        onPick(levels[index])
                    }
                }
            }
            if canReset {
                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise").font(LoomTheme.Composer.effortResetIcon)
                        .foregroundStyle(LoomTheme.OnPopover.placeholder)
                        .frame(width: LoomTheme.Composer.effortResetSide, height: LoomTheme.Composer.effortResetSide)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).composerChipHover()
                .help(resetHelp)
                .accessibilityLabel("Reset effort")
                .accessibilityIdentifier("\(identifier)-reset")
            }
        }
        .padding(LoomTheme.Composer.effortPadding)
        .frame(width: LoomTheme.Composer.effortWidth)
        .background(LoomTheme.Surface.popover)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
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
}

/// The segmented track with a thumb: a click or a drag picks the nearest stop (the level is set when the pointer is
/// released), and ← → step it from the keyboard. Each stop is a level the model takes.
struct ComposerEffortSlider: View {
    var levels: [String]
    var selected: Int?
    @Binding var preview: Int?
    var identifier: String
    var onCommit: (Int) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { proxy in
            let side = LoomTheme.Composer.effortThumb
            let inset = LoomTheme.Composer.effortTrackInset
            let positions = EffortSliderMath.positions(count: levels.count, width: proxy.size.width, thumb: side, inset: inset)
            let index = preview ?? selected
            ZStack(alignment: .leading) {
                Capsule().fill(LoomTheme.Composer.effortTrack)
                if let index, positions.indices.contains(index) {
                    Capsule().fill(LoomTheme.Composer.effortFill).frame(width: positions[index] + side / 2 + inset)
                }
                ForEach(Array(positions.enumerated()), id: \.offset) { stop, x in
                    Circle().fill(index.map { stop <= $0 } == true ? LoomTheme.Composer.effortDotOnFill : LoomTheme.Composer.effortDotOffFill)
                        .frame(width: LoomTheme.Composer.effortDot, height: LoomTheme.Composer.effortDot)
                        .position(x: x, y: proxy.size.height / 2)
                }
                if let index, positions.indices.contains(index) {
                    Circle().fill(LoomTheme.Composer.effortThumbFill).frame(width: side, height: side)
                        .shadow(color: LoomTheme.Composer.effortThumbShadow, radius: LoomTheme.Composer.effortThumbShadowRadius, y: 1)
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
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .home, .end]) { press in step(press.key) }
        .onAppear { focused = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Effort")
        .accessibilityValue(selected.map { ComposerBarText.effortLabel(levels[$0]) } ?? "Default")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(by: 1)
            case .decrement: move(by: -1)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("\(identifier)-track")
    }

    private func step(_ key: KeyEquivalent) -> KeyPress.Result {
        switch key {
        case .leftArrow: move(by: -1)
        case .rightArrow: move(by: 1)
        case .home: onCommit(0)
        case .end: onCommit(levels.count - 1)
        default: return .ignored
        }
        return .handled
    }

    private func move(by delta: Int) {
        guard !levels.isEmpty else { return }
        let target = min(max((selected ?? (delta > 0 ? -1 : levels.count)) + delta, 0), levels.count - 1)
        if target != selected { onCommit(target) }
    }
}
