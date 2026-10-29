import AppKit
import LoomCore
import SwiftUI

// The pieces of the session header (DESIGN §6 Header; A3 and A4 of the reference): the state pill right after the title, and
// at the trailing edge the project chip that ends with the Git branch, the model segment, a hairline, the inspector toggle and
// the control group, with the layout that gives them their places while the title gives way first. Values are
// `LoomTheme.Header`'s.

// MARK: State pill

/// How the state pill reads for an indicator: its label, the label's colour and the wash behind it.
/// `.ended` has no label and therefore no pill.
struct StatePillStyle: Equatable {
    let label: String
    let text: LoomTheme.ContrastStyle
    let wash: LoomTheme.Tone
    /// The wash in Light, where the neutral washes are ink and a status wash is the hue's Light step.
    let lightWash: LoomTheme.Tone
    /// Whether the indicator has anything to draw (Ready, Idle, Stale and State unknown draw none, DESIGN §4): without a
    /// mark the label sits between two equal insets instead of after an empty slot.
    let showsIndicator: Bool

    private static let white = LoomTheme.RGB(red: 1, green: 1, blue: 1)

    /// `label` replaces the indicator's own (the subagent panel's "Running 4m"); `suffix` is added after the label (the
    /// work a finished turn left running, "· 1 background", D-103).
    init?(_ indicator: SessionIndicator, label override: String? = nil, suffix: String? = nil) {
        guard let base = override ?? indicator.label else { return nil }
        let label = suffix.flatMap { $0.isEmpty ? nil : $0 }.map { "\(base) · \($0)" } ?? base
        self.label = label
        showsIndicator = ![.ready, .idle, .stale, .unknown].contains(indicator)
        func tone(_ pair: LoomTheme.Adaptive) -> LoomTheme.ContrastStyle {
            LoomTheme.ContrastStyle(
                standard: LoomTheme.Tone(rgb: pair.dark, opacity: 1), increased: LoomTheme.Tone(rgb: pair.dark, opacity: 1),
                lightStandard: LoomTheme.Tone(rgb: pair.light, opacity: 1), lightIncreased: LoomTheme.Tone(rgb: pair.light, opacity: 1))
        }
        func status(_ wash: LoomTheme.AdaptiveTone, label lighter: LoomTheme.Adaptive)
            -> (LoomTheme.ContrastStyle, LoomTheme.Tone, LoomTheme.Tone) {
            (tone(lighter), wash.dark, wash.light)
        }
        switch indicator {
        case .working:
            text = tone(LoomTheme.Text.primaryPair)
            wash = LoomTheme.Tone(rgb: Self.white, opacity: LoomTheme.Header.pillWorkingWash)
            lightWash = LoomTheme.Tone(rgb: LoomTheme.inkRGB, opacity: LoomTheme.Header.pillWorkingLightWash)
        case .ready, .idle, .stale, .unknown, .ended:
            text = LoomTheme.Text.secondaryOnTintStyle
            wash = LoomTheme.Tone(rgb: Self.white, opacity: LoomTheme.Header.pillNeutralWash)
            lightWash = LoomTheme.Tone(rgb: LoomTheme.inkRGB, opacity: LoomTheme.Header.pillNeutralLightWash)
        case .waitingForApproval, .waitingForInput, .identityUnclear:
            (text, wash, lightWash) = status(LoomTheme.Status.attentionWashTone, label: LoomTheme.Header.attentionLabelPair)
        case .failed, .stopUnverified, .problem:
            (text, wash, lightWash) = status(LoomTheme.Status.failureWashTone, label: LoomTheme.Header.failureLabelPair)
        case .unviewedCompletion:
            (text, wash, lightWash) = status(LoomTheme.Status.unviewedWashTone, label: LoomTheme.Header.unviewedLabelPair)
        }
    }
}

/// The indicator and the state's label in a capsule, at a fixed place: it never truncates.
struct StatePill: View {
    let indicator: SessionIndicator
    let style: StatePillStyle

    var body: some View {
        HStack(spacing: LoomTheme.Header.pillGap) {
            if style.showsIndicator { IndicatorView(indicator: indicator) }
            Text(style.label).font(LoomTheme.Header.pillFont).foregroundStyle(style.text)
                .lineLimit(1).fixedSize()
        }
        .padding(.leading, style.showsIndicator ? LoomTheme.Header.pillLeading : LoomTheme.Header.pillTrailing)
        .padding(.trailing, LoomTheme.Header.pillTrailing)
        .frame(height: LoomTheme.Header.pillHeight)
        .background(Capsule().fill(LoomTheme.AdaptiveTone(dark: style.wash, light: style.lightWash).color))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: Project chip

/// What the project chip shows: the project (name and tone), then the branch after a hairline. The branch
/// is shown for a named branch and a detached HEAD, hidden when it is unavailable or not read yet. No
/// project and no branch: no chip. A session without a project shows the branch alone, neutral.
struct SessionHeaderChip: Equatable {
    let project: String?
    let tone: ProjectTone?
    let branch: String?

    init?(project: ProjectMark?, branch: GitBranch?) {
        let shown: String?
        switch branch {
        case let .named(name)?: shown = name
        case .detached?: shown = GitBranch.detached.label
        case .unavailable?, nil: shown = nil
        }
        guard project != nil || shown != nil else { return nil }
        self.project = project?.name
        self.tone = project?.tone
        self.branch = shown
    }

    /// "Project: <name>, branch <branch>", or whichever parts exist.
    var accessibilityLabel: String {
        [project.map { "Project: \($0)" }, branch.map { "branch \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }

    /// Whether the chip has a branch it can give up when the row is narrow.
    var dropsBranch: Bool { project != nil && branch != nil }
}

/// The project chip: the project's mark, the name, a hairline, the branch glyph and name. The project's tone tints it (10 %
/// with a 1 pt edge of the tone at 32 %); without a tone it is the neutral chip. Clipped, 22 pt high, radius 6.
struct ProjectBranchChip: View {
    let chip: SessionHeaderChip

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Header.chipRadius)
        Group {
            if let project = chip.project {
                // The first form that fits the proposed width is drawn: with the branch, then without it,
                // then (whatever the width) the name alone, which shortens.
                ViewThatFits(in: .horizontal) {
                    if let branch = chip.branch { named(project, branch: branch) }
                    named(project, branch: nil)
                }
            } else if let branch = chip.branch {
                HStack(spacing: 0) {
                    branchLabel(branch).padding(.horizontal, LoomTheme.Header.chipInset)
                }
            }
        }
        .frame(height: LoomTheme.Header.chipHeight)
        .background(wash)
        .clipShape(shape)
        .overlay(shape.strokeBorder(edge, lineWidth: LoomTheme.Line.hairline).allowsHitTesting(false))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chip.accessibilityLabel)
    }

    private var wash: Color {
        chip.tone.map { LoomTheme.ProjectColor.wash($0, opacity: LoomTheme.ProjectColor.chipWash).color }
            ?? LoomTheme.Header.chipNeutral
    }

    private var edge: AnyShapeStyle {
        chip.tone.map { AnyShapeStyle(LoomTheme.ProjectColor.chipEdge($0)) } ?? AnyShapeStyle(LoomTheme.Surface.strongEdgeStyle)
    }

    private func named(_ project: String, branch: String?) -> some View {
        HStack(spacing: 0) {
            ProjectMarkView(name: project, tone: chip.tone, size: .chip).padding(.leading, LoomTheme.Header.chipMarkInset)
            // The name is laid out first: the branch's capped frame would otherwise take more than its text and
            // leave the name shortened in a chip that has room.
            Text(project).font(LoomTheme.Header.chipNameFont).foregroundStyle(LoomTheme.Text.primary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                .padding(.leading, LoomTheme.Header.chipMarkGap)
            if let branch {
                Rectangle().fill(LoomTheme.Surface.strongEdgeStyle)
                    .frame(width: LoomTheme.Line.hairline, height: LoomTheme.Header.chipRuleHeight)
                    .padding(.leading, LoomTheme.Header.chipRuleGap).padding(.trailing, LoomTheme.Header.chipRuleAfter)
                    .accessibilityHidden(true)
                branchLabel(branch)
            }
            Color.clear.frame(width: LoomTheme.Header.chipInset, height: 0)
        }
    }

    private func branchLabel(_ branch: String) -> some View {
        HStack(spacing: LoomTheme.Header.chipBranchGap) {
            InkIcon(.branch, size: LoomTheme.Icon.small)
            Text(branch).font(LoomTheme.Header.chipBranchFont).lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(LoomTheme.Text.secondaryOnTintStyle)
        .cappedWidth(LoomTheme.Header.branchMaxWidth)
        .help("Git branch")
    }
}

/// Proposes at most `maxWidth` to its one child and takes the child's size. Unlike `frame(maxWidth:)` it
/// never grows beyond what the child uses, so a siblings' share is not eaten by the cap.
struct CappedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: min(bounds.width, maxWidth), height: bounds.height))
    }
}

extension View {
    func cappedWidth(_ maxWidth: CGFloat) -> some View { CappedWidth(maxWidth: maxWidth) { self } }
}

// MARK: Hairline and control group

/// The 1×16 hairline before the control group, with its margin.
struct HeaderRule: View {
    var body: some View {
        Rectangle().fill(LoomTheme.Surface.hairlineStyle)
            .frame(width: LoomTheme.Line.hairline, height: LoomTheme.Header.ruleHeight)
            .padding(.horizontal, LoomTheme.Header.ruleMargin)
            .accessibilityHidden(true)
    }
}

/// A segment of the control group: the hover fill under the pointer and the pressed fill while pressed (DESIGN §6 Header: a
/// segment's hover is the hover fill), with the shared focus halo. The label is primary, or
/// secondary until hovered (`secondaryUntilHovered`, the ⋯ glyph).
struct HeaderSegmentStyle: ButtonStyle {
    var secondaryUntilHovered = false

    func makeBody(configuration: Configuration) -> some View {
        Segment(configuration: configuration, secondaryUntilHovered: secondaryUntilHovered)
    }

    private struct Segment: View {
        let configuration: ButtonStyle.Configuration
        let secondaryUntilHovered: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused

        var body: some View {
            let active = hovering || configuration.isPressed
            let fill: Color = !enabled ? .clear : (configuration.isPressed ? LoomTheme.Highlight.pressed
                : (hovering ? LoomTheme.Highlight.hover : .clear))
            configuration.label
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(secondaryUntilHovered && !active ? LoomTheme.Text.secondary : LoomTheme.Text.primary)
                .frame(height: LoomTheme.Header.sessionGroupHeight)
                .background(RoundedRectangle(cornerRadius: LoomTheme.Control.iconRadius).fill(fill))
                .controlFocusRing(
                    visible: ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled),
                    radius: LoomTheme.Control.iconRadius)
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
                .onHover { hovering = $0 }
        }
    }
}

/// The inspector toggle: a 28 pt icon button (`sidebar.right`), on the selected fill while the inspector is open. It does what
/// View > Toggle Inspector does.
struct HeaderInspectorToggle: View {
    let model: CatalogModel
    let sessionID: UUID

    var body: some View {
        let open = model.inspector.isOpen(for: sessionID)
        Button { model.setInspector(open: !open, for: sessionID) } label: {
            InkIcon(.sidebarRight)
        }
        .buttonStyle(ChromeButtonStyle(selected: open, key: "inspector-toggle")).focusEffectDisabled()
        .help(open ? "Hide Inspector (⌥⌘B)" : "Show Inspector (⌥⌘B)")
        .accessibilityLabel(open ? "Hide inspector" : "Show inspector")
        .accessibilityIdentifier("inspector-toggle")
    }
}

/// One container, 28 pt high, radius 8, with an input edge: a Stop segment (only while the run can be
/// stopped) and the ⋯ menu segment, with a hairline between them. When the run ends Stop goes and ⋯ stays at the trailing edge.
struct HeaderControlGroup<MenuItems: View>: View {
    let canStop: Bool
    let stop: () -> Void
    @ViewBuilder let menuItems: () -> MenuItems

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Header.sessionGroupRadius)
        HStack(spacing: 0) {
            if canStop {
                Button(action: stop) {
                    HStack(spacing: LoomTheme.Header.stopGap) {
                        RoundedRectangle(cornerRadius: LoomTheme.Header.stopGlyphRadius)
                            .frame(width: LoomTheme.Header.stopGlyph, height: LoomTheme.Header.stopGlyph)
                        Text("Stop").font(LoomTheme.InkType.button.font)
                    }
                    .padding(.horizontal, LoomTheme.Header.stopPadding)
                }
                .buttonStyle(HeaderSegmentStyle()).focusEffectDisabled()
                .accessibilityLabel("Stop session")
                Rectangle().fill(LoomTheme.Surface.strongEdgeStyle).frame(width: LoomTheme.Line.hairline)
                    .accessibilityHidden(true)
            }
            Menu {
                menuItems()
            } label: {
                InkIcon(.more).frame(width: LoomTheme.Header.menuSegmentWidth)
            }
            .menuStyle(.button).buttonStyle(HeaderSegmentStyle(secondaryUntilHovered: true))
            .menuIndicator(.hidden).fixedSize().focusEffectDisabled()
            .accessibilityLabel("Session actions")
        }
        .frame(height: LoomTheme.Header.sessionGroupHeight)
        .background(shape.fill(LoomTheme.Surface.inputFill))
        .overlay(shape.strokeBorder(LoomTheme.Surface.inputEdge, lineWidth: LoomTheme.Line.hairline).allowsHitTesting(false))
        .fixedSize()
    }
}

// MARK: Layout

/// The places of the header row's flexible part, from the left: the title and right after it the status (the pill or a plain
/// text), then at the trailing edge the project chip, the model segment, the hairline and the inspector toggle with the
/// control group (the `group` slot).
enum HeaderSlot: Hashable { case title, status, chip, model, rule, group }

struct HeaderSlotKey: LayoutValueKey { static let defaultValue = HeaderSlot.title }
/// Whether the status may shorten when the row is too narrow for everything (a transient text, not the pill).
struct HeaderShrinksKey: LayoutValueKey { static let defaultValue = false }
/// Whether the chip has a branch it can give up (it also has a project).
struct HeaderDropsBranchKey: LayoutValueKey { static let defaultValue = false }

extension View {
    func headerSlot(_ slot: HeaderSlot, shrinks: Bool = false, dropsBranch: Bool = false) -> some View {
        layoutValue(key: HeaderSlotKey.self, value: slot)
            .layoutValue(key: HeaderShrinksKey.self, value: shrinks)
            .layoutValue(key: HeaderDropsBranchKey.self, value: dropsBranch)
    }
}

/// The widths of the header row's parts for a given width, by the rules of the design: the title gives way
/// first, down to `titleMinWidth`; then the model segment goes, before the branch does; then the chip gives up its
/// branch; then the project name shortens, down to `chipFloorWidth`. The pill and the control group never shorten.
/// Only when even that is not enough does the title shrink further, and last a status that may (a transient text).
struct HeaderFlowPlan: Equatable {
    struct Status: Equatable {
        var ideal: CGFloat
        var shrinks = false
    }
    struct Chip: Equatable {
        var full: CGFloat
        /// The width without the branch; equal to `full` when the chip has none to give up.
        var compact: CGFloat
    }

    var title: CGFloat
    var status: CGFloat?
    var chip: CGFloat?
    var showsBranch: Bool
    /// The model segment's width; nil when it is dropped (or there is none).
    var model: CGFloat?

    /// `model` is the segment's full width, nil or 0 for none. It is drawn only with the title at its floor or more and
    /// the chip whole; otherwise it goes before the chip gives up anything.
    static func make(width: CGFloat, title: CGFloat, status: Status?, chip: Chip?, model: CGFloat? = nil, rule: CGFloat,
                     group: CGFloat, spacing: CGFloat) -> HeaderFlowPlan {
        let titleFloor = min(title, LoomTheme.Header.titleMinWidth)
        var statusWidth = status?.ideal
        let modelWidth = model.flatMap { $0 > 0 ? $0 : nil }
        /// What the items right of the title take, each with the gap before it.
        func rest(chip chipWidth: CGFloat?, model shown: CGFloat? = nil) -> CGFloat {
            [statusWidth, chipWidth, shown, rule > 0 ? rule : nil, group > 0 ? group : nil].compactMap { $0 }
                .reduce(0) { $0 + spacing + $1 }
        }
        func room(_ chipWidth: CGFloat?, model shown: CGFloat? = nil) -> CGFloat { width - rest(chip: chipWidth, model: shown) }
        func result(title room: CGFloat, chip chipWidth: CGFloat?, showsBranch: Bool, model shown: CGFloat? = nil) -> HeaderFlowPlan {
            var titleWidth = max(0, min(title, room))
            if room < 0, let status, status.shrinks {
                statusWidth = max(0, status.ideal + room)
                titleWidth = 0
            }
            return HeaderFlowPlan(title: titleWidth, status: statusWidth, chip: chipWidth, showsBranch: showsBranch, model: shown)
        }

        // The model segment comes first in the order of giving way: with the chip whole it needs the title at its floor.
        if let modelWidth {
            if let chip {
                if room(chip.full, model: modelWidth) >= titleFloor {
                    return result(title: room(chip.full, model: modelWidth), chip: chip.full,
                                  showsBranch: chip.full > chip.compact, model: modelWidth)
                }
            } else if room(nil, model: modelWidth) >= titleFloor {
                return result(title: room(nil, model: modelWidth), chip: nil, showsBranch: false, model: modelWidth)
            }
        }
        guard let chip else { return result(title: room(nil), chip: nil, showsBranch: false) }
        if room(chip.full) >= titleFloor {
            return result(title: room(chip.full), chip: chip.full, showsBranch: chip.full > chip.compact)
        }
        if room(chip.compact) >= titleFloor { return result(title: room(chip.compact), chip: chip.compact, showsBranch: false) }
        // The title is at its floor: the name shortens to what is left, down to the floor of the chip.
        let left = width - titleFloor - rest(chip: nil) - spacing
        let squeezed = max(min(chip.compact, LoomTheme.Header.chipFloorWidth), min(chip.compact, left))
        return result(title: room(squeezed), chip: squeezed, showsBranch: false)
    }
}

/// Lays out the header row's flexible part by `HeaderFlowPlan`. Children carry a `headerSlot`.
struct HeaderFlow: Layout {
    private func slots(_ subviews: Subviews) -> [HeaderSlot: LayoutSubview] {
        var map: [HeaderSlot: LayoutSubview] = [:]
        for subview in subviews { map[subview[HeaderSlotKey.self]] = subview }
        return map
    }

    private func plan(width: CGFloat, _ map: [HeaderSlot: LayoutSubview]) -> HeaderFlowPlan {
        let chip = map[.chip].map { subview -> HeaderFlowPlan.Chip in
            let full = subview.sizeThatFits(.unspecified).width
            // Narrower than the full form, the chip draws without its branch: that is its compact width.
            let compact = subview[HeaderDropsBranchKey.self]
                ? min(full, subview.sizeThatFits(ProposedViewSize(width: full - 1, height: nil)).width) : full
            return HeaderFlowPlan.Chip(full: full, compact: compact)
        }
        return HeaderFlowPlan.make(
            width: width,
            title: map[.title]?.sizeThatFits(.unspecified).width ?? 0,
            status: map[.status].map {
                HeaderFlowPlan.Status(ideal: $0.sizeThatFits(.unspecified).width, shrinks: $0[HeaderShrinksKey.self])
            },
            chip: chip,
            model: map[.model]?.sizeThatFits(.unspecified).width,
            rule: map[.rule]?.sizeThatFits(.unspecified).width ?? 0,
            group: map[.group]?.sizeThatFits(.unspecified).width ?? 0,
            spacing: LoomTheme.Space.detailSpacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let map = slots(subviews)
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        if let width = proposal.width, width.isFinite { return CGSize(width: width, height: height) }
        // Unconstrained: everything at its ideal width.
        let ideal = plan(width: .greatestFiniteMagnitude / 4, map)
        let width = ideal.title + [ideal.status, ideal.chip, ideal.model,
                                   map[.rule]?.sizeThatFits(.unspecified).width,
                                   map[.group]?.sizeThatFits(.unspecified).width].compactMap { $0 }
            .reduce(0) { $0 + LoomTheme.Space.detailSpacing + $1 }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let map = slots(subviews)
        let plan = plan(width: bounds.width, map)
        var edge = bounds.maxX
        /// Places a part at the trailing side of `edge` at the width it really takes (a shortened name may
        /// take a little less than it was given), so the gaps stay exact.
        func put(_ slot: HeaderSlot, width: CGFloat?, extra: CGFloat = 0) {
            guard let subview = map[slot], let width else { return }
            let proposed = ProposedViewSize(width: width + extra, height: nil)
            let taken = subview.sizeThatFits(proposed).width
            subview.place(at: CGPoint(x: edge, y: bounds.midY), anchor: .trailing, proposal: proposed)
            edge -= taken + LoomTheme.Space.detailSpacing
        }
        put(.group, width: map[.group]?.sizeThatFits(.unspecified).width)
        put(.rule, width: map[.rule]?.sizeThatFits(.unspecified).width)
        // The model segment draws in its full form only when it is proposed its width and a hair more; otherwise it draws
        // nothing (it is placed all the same, at no width).
        if let model = map[.model], plan.model == nil {
            model.place(at: CGPoint(x: edge, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(width: 0, height: nil))
        }
        put(.model, width: plan.model, extra: 0.25)
        // The chip is proposed its planned width; a hair more keeps the full form when the plan chose it.
        put(.chip, width: plan.chip, extra: plan.showsBranch ? 0.25 : 0)
        // The title keeps the leading edge and the status follows it, 8 apart: when the title is shorter than its room the
        // gap opens between the status and the chip, not between the title and its status.
        var titleEdge = bounds.minX
        if let title = map[.title] {
            let proposed = ProposedViewSize(width: plan.title, height: nil)
            title.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: proposed)
            let taken = title.sizeThatFits(proposed).width
            titleEdge += taken + (taken > 0 ? LoomTheme.Space.detailSpacing : 0)
        }
        if let status = map[.status], let width = plan.status {
            status.place(at: CGPoint(x: titleEdge, y: bounds.midY), anchor: .leading,
                         proposal: ProposedViewSize(width: width, height: nil))
        }
    }
}
