import LoomChat
import LoomCore
import Observation
import SwiftUI

/// The pieces of the composer's bar, which the draft's composer and the session's own composer share (D-58, after Codex's
/// bar; Ink, DESIGN §11): + on the left, the permission mode as plain text in its tone, then the context ring, the one
/// model chip and a round Send that says what Return does. No boxes around the controls, and no mode gets a warning colour
/// or mark.

/// The bar's frame: leading controls, a gap, trailing controls.
struct ComposerBarFrame<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: LoomTheme.Composer.barSpacing) {
            leading
            Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            trailing
        }
        .padding(.horizontal, LoomTheme.Composer.barInsetH)
        .padding(.bottom, LoomTheme.Composer.barInsetBottom)
        .frame(minHeight: LoomTheme.Composer.barHeight)
    }
}

// MARK: Card

extension View {
    /// The composer's surface (DESIGN §3 Depth): raised 2, radius 18, a 12 % ring, a 1 pt highlight along the top inside edge
    /// in Ink and the 90 pt shadow. The draft's card and the live card draw it alike.
    func composerCard() -> some View { modifier(ComposerCardSurface()) }
}

private struct ComposerCardSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let depth = LoomTheme.Composer.depth[LoomTheme.Appearance(scheme)]
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Composer.radius)
        content
            .background { shape.fill(LoomTheme.Composer.fill).depth(LoomTheme.Composer.depth) }
            .overlay {
                if let ring = depth.ring { shape.strokeBorder(ring.color, lineWidth: LoomTheme.Line.hairline).allowsHitTesting(false) }
            }
    }
}

// MARK: Chip

/// A chip of the bar (`.cchip`): no box until the pointer is on it, then the control's pill. Its text is secondary and
/// primary under the pointer, unless the chip has a tone of its own (the mode).
struct ComposerChipStyle: ButtonStyle {
    var tint: Color?
    /// Names the chip for the evidence run's `hover:` command.
    var key: String?

    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, tint: tint, key: key)
    }

    private struct Chip: View {
        let configuration: ButtonStyle.Configuration
        let tint: Color?
        let key: String?
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let _ = SidebarRenderProbe.pill(key)
            let lit = enabled && (hovering || LookEvidence.forcesHover(key))
            let state = HighlightState.resolve(selected: false, hovering: lit, pressed: configuration.isPressed, enabled: enabled)
            let ring = ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled)
            configuration.label
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? (lit ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle)))
                .background(RowHighlight(state: state, radius: LoomTheme.Composer.chipRadius))
                .overlay(RoundedRectangle(cornerRadius: LoomTheme.Composer.chipRadius)
                    .strokeBorder(ring ? LoomTheme.Surface.focusRing : .clear, lineWidth: LoomTheme.Line.focusRing(for: contrast)))
                .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Composer.chipRadius))
                .onHover { hovering = $0 }
        }
    }
}

/// A text control of the bar: an optional symbol and the title, 6 apart (the mode chip; it has no chevron).
struct ComposerChipLabel: View {
    var symbol: String?
    var title: String

    var body: some View {
        HStack(spacing: LoomTheme.Composer.chipPartGap) {
            if let symbol { Image(systemName: symbol).font(LoomTheme.Composer.barIcon) }
            Text(title).font(LoomTheme.Composer.barFont).lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, LoomTheme.Composer.chipPaddingH)
        .frame(minHeight: LoomTheme.Composer.controlSide)
        .contentShape(Rectangle())
    }
}

// MARK: Send

/// What the Send button looks like (DESIGN §11: Send says what Return does).
enum ComposerSendLook: Equatable, CaseIterable {
    case disabled
    case send
    /// A message while Claude works: Claude reads it after the current step.
    case sendNow
    case afterTurn
    case stop
    case update
    case resume

    /// The round disc of a plain send, an off one and Interrupt.
    enum Disc: Equatable {
        /// Off: nothing to send, or a card or a handover holds the text.
        case faint
        /// A plain send: the accent.
        case accent
        /// Interrupt: primary text, with a square.
        case primary
    }

    /// The word of a capsule; nil for a round Send.
    var word: String? {
        switch self {
        case .sendNow: "Send Now"
        case .afterTurn: "After This Turn"
        case .update: "Update"
        case .resume: "Resume"
        case .disabled, .send, .stop: nil
        }
    }

    /// The disc's fill; nil where the button is an accent capsule.
    var disc: Disc? {
        switch self {
        case .disabled: .faint
        case .send: .accent
        case .stop: .primary
        case .sendNow, .afterTurn, .update, .resume: nil
        }
    }

    /// The SF Symbol in the disc or the capsule; Interrupt draws a square instead.
    var symbol: String? {
        switch self {
        case .disabled, .send, .sendNow: "arrow.up"
        case .afterTurn: "clock"
        case .update: "checkmark"
        case .resume: "play.fill"
        case .stop: nil
        }
    }

    var isEnabled: Bool { self != .disabled }
}

extension ComposerSendKind {
    /// How Send looks for what Return does now.
    var look: ComposerSendLook {
        switch self {
        case .sendDisabled: .disabled
        case .send: .send
        case .sendNow: .sendNow
        case .afterTurn: .afterTurn
        case .interrupt: .stop
        case .update: .update
        case .resume: .resume
        }
    }

    /// The button's name for VoiceOver: the capsule's word, else "Send" or "Interrupt".
    var label: String {
        switch self {
        case .sendDisabled, .send: "Send"
        case .interrupt: "Interrupt"
        default: look.word ?? "Send"
        }
    }
}

/// The Send button: an accent disc for a plain send, a faint one when off, a primary disc with a square for Interrupt, and an
/// accent capsule with a word where Return does something else.
struct ComposerSendButton: View {
    var look: ComposerSendLook
    var label: String
    var help: String
    var identifier: String
    var action: (_ commandHeld: Bool) -> Void

    var body: some View {
        Button {
            action(NSEvent.modifierFlags.contains(.command))
        } label: {
            content
        }
        .buttonStyle(.plain).disabled(!look.isEnabled)
        .padding(.leading, LoomTheme.Composer.sendGap)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var content: some View {
        if let word = look.word {
            HStack(spacing: LoomTheme.Composer.sendWordGap) {
                if let symbol = look.symbol { Image(systemName: symbol).font(LoomTheme.Composer.sendWordIcon) }
                Text(word).font(LoomTheme.Composer.sendWordFont).lineLimit(1)
            }
            .foregroundStyle(LoomTheme.Accent.onAccent)
            .padding(.leading, LoomTheme.Composer.sendWordPaddingLeading).padding(.trailing, LoomTheme.Composer.sendWordPaddingTrailing)
            .frame(height: LoomTheme.Composer.sendSide)
            .background(Capsule().fill(LoomTheme.Composer.sendReadyFill))
            .contentShape(Capsule())
        } else {
            let accent = look.disc == .accent
            glyph(color: accent ? LoomTheme.Accent.onAccent : LoomTheme.Composer.sendOnDiscGlyph)
                .frame(width: LoomTheme.Composer.sendSide, height: LoomTheme.Composer.sendSide)
                .background(Circle().fill(Self.fill(look.disc)))
                .contentShape(Circle())
        }
    }

    static func fill(_ disc: ComposerSendLook.Disc?) -> Color {
        switch disc {
        case .accent?: LoomTheme.Composer.sendReadyFill
        case .primary?: LoomTheme.Composer.sendStopFill
        case .faint?, nil: LoomTheme.Composer.sendOffFill
        }
    }

    @ViewBuilder private func glyph(color: Color) -> some View {
        if let symbol = look.symbol {
            Image(systemName: symbol).font(LoomTheme.Composer.sendIcon).foregroundStyle(color)
        } else {
            RoundedRectangle(cornerRadius: LoomTheme.Composer.stopRadius).fill(color)
                .frame(width: LoomTheme.Composer.stopGlyph, height: LoomTheme.Composer.stopGlyph)
        }
    }
}

// MARK: Plus

/// What the + popover offers: the three ways to put something into the message, each with its key.
enum ComposerPlusItem: CaseIterable, Identifiable {
    case attach, mention, commands

    var id: Self { self }

    var title: String {
        switch self {
        case .attach: "Add images and files"
        case .mention: "Mention a file or session"
        case .commands: "Commands and skills"
        }
    }

    var symbol: String {
        switch self {
        case .attach: "paperclip"
        case .mention: "at"
        case .commands: "slash.circle"
        }
    }

    var shortcut: String {
        switch self {
        case .attach: ComposerKeys.attachShortcut
        case .mention: ComposerKeys.mentionShortcut
        case .commands: ComposerKeys.commandsShortcut
        }
    }

    var identifier: String {
        switch self {
        case .attach: "composer-plus-attach"
        case .mention: "composer-plus-mention"
        case .commands: "composer-plus-commands"
        }
    }
}

/// The + chip (28 square, a 14 pt glyph) and its popover in the window's host, above the chip with their leading edges aligned: icon,
/// name and the key cap on each row (the reference's `plusA`). ↑ ↓ move between the three rows and ↵ picks.
struct ComposerPlusChip: View {
    @Binding var isOpen: Bool
    /// Gives the keyboard back to the composer's text when the popover closes.
    var restoreFocus: (() -> Void)?
    var onChoose: (ComposerPlusItem) -> Void
    @State private var cursor = ComposerPickCursor()

    /// What a key does to the rows: the new highlight, the item it picks, and whether the popover used the key (↑ ↓ wrap).
    struct Step: Equatable {
        var highlighted: Int?
        var pick: ComposerPlusItem?
        var handled: Bool
    }

    static func resolve(_ key: InkKey, highlighted: Int?) -> Step {
        let items = ComposerPlusItem.allCases
        switch key {
        case .down, .up:
            return Step(highlighted: ComposerPopoverKeys.cursor(from: highlighted, delta: key == .down ? 1 : -1, count: items.count),
                        pick: nil, handled: true)
        case .return, .space:
            guard let highlighted, items.indices.contains(highlighted) else { return Step(highlighted: highlighted, pick: nil, handled: false) }
            return Step(highlighted: highlighted, pick: items[highlighted], handled: true)
        case .left, .right, .escape: return Step(highlighted: highlighted, pick: nil, handled: false)
        }
    }

    var body: some View {
        let spot = InkOpeners.placement(.plus, onDraft: false) ?? InkOpeners.Spot(side: .above, alignment: .leading)
        Button { isOpen.toggle() } label: {
            Image(systemName: "plus").font(LoomTheme.Composer.plusIcon)
                .frame(width: LoomTheme.Composer.controlSide, height: LoomTheme.Composer.controlSide).contentShape(Rectangle())
        }
        .buttonStyle(ComposerChipStyle(key: "composer-plus"))
        .help("Add images and files, mention a file or session, or run a command")
        .accessibilityLabel("Add")
        .accessibilityIdentifier("composer-plus")
        .inkPopover(isPresented: $isOpen, id: "composer-plus", label: "Add", side: spot.side, alignment: spot.alignment, keys: { key in
            let step = Self.resolve(key, highlighted: cursor.highlighted)
            cursor.highlighted = step.highlighted
            if let item = step.pick { choose(item) }
            return step.handled
        }, restoreFocus: restoreFocus, content: {
            VStack(spacing: 0) {
                ForEach(Array(ComposerPlusItem.allCases.enumerated()), id: \.element) { index, item in
                    row(item, lit: cursor.highlighted == index, index: index)
                }
            }
            .padding(LoomTheme.Composer.modelPopoverInset)
            .frame(width: LoomTheme.Composer.plusPopoverWidth)
        })
        .onChange(of: isOpen) { _, open in if !open { cursor.highlighted = nil } }
    }

    private func choose(_ item: ComposerPlusItem) {
        isOpen = false
        onChoose(item)
    }

    private func row(_ item: ComposerPlusItem, lit: Bool, index: Int) -> some View {
        Button { choose(item) } label: {
            HStack(spacing: LoomTheme.Composer.modelColumnGap) {
                Image(systemName: item.symbol).font(LoomTheme.Composer.menuIconFont)
                    .foregroundStyle(LoomTheme.OnPopover.secondary(lit: lit))
                    .frame(width: LoomTheme.Composer.menuIconSlot)
                Text(item.title).font(LoomTheme.Composer.modelNameFont).foregroundStyle(LoomTheme.Text.primary)
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
                SidebarKeyCap(text: item.shortcut)
            }
            .padding(.horizontal, LoomTheme.Composer.modelRowPaddingH)
            .frame(height: LoomTheme.Composer.modelRowHeight)
            .background(RowHighlight(state: .resolve(selected: false, hovering: lit), radius: LoomTheme.Composer.modelRowRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { cursor.highlighted = index } else if cursor.highlighted == index { cursor.highlighted = nil }
        }
        .accessibilityLabel(item.title)
        .accessibilityIdentifier(item.identifier)
    }
}

// MARK: Context ring

/// The context ring of the bar (CHAT-SPEC → The bar): the ring alone while the window is known, a short token count in its
/// place when it is not; red above 90 %. After 150 ms of hover (or a click) a popover shows the figures.
struct ComposerRing: View {
    var usage: ContextUsage?
    var canCompact: Bool
    var onCompact: () -> Void
    /// Gives the keyboard back to the composer's text when the popover closes.
    var restoreFocus: (() -> Void)?
    @Binding var showsPopover: Bool
    @State private var hoverTask: Task<Void, Never>?
    /// A popover the pointer opened leaves the keyboard in the composer, so typing is not interrupted by a pointer passing over.
    @State private var openedByHover = false

    private func compact() {
        showsPopover = false
        onCompact()
    }

    var body: some View {
        let spot = InkOpeners.placement(.ring, onDraft: false) ?? InkOpeners.Spot(side: .above, alignment: .trailing)
        Button {
            openedByHover = false
            showsPopover.toggle()
        } label: {
            ring
                .frame(minWidth: LoomTheme.Composer.controlSide, minHeight: LoomTheme.Composer.controlSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(ComposerChipStyle(key: "composer-ring"))
        .onHover { inside in
            hoverTask?.cancel()
            if inside {
                hoverTask = Task {
                    try? await Task.sleep(for: .seconds(LoomTheme.Composer.ringHoverDelay))
                    guard !Task.isCancelled, !showsPopover else { return }
                    openedByHover = true
                    showsPopover = true
                }
            }
        }
        .inkPopover(isPresented: $showsPopover, id: "composer-ring", label: "Context", side: spot.side, alignment: spot.alignment,
                    takesKeyboard: !openedByHover, keys: { key in
            // The only button is Compact Now: ↵ and Space press it while it is on.
            guard (key == .return || key == .space) && canCompact else { return false }
            compact()
            return true
        }, restoreFocus: restoreFocus, content: {
            ComposerContextPopover(usage: usage, canCompact: canCompact) { compact() }
        })
        .onChange(of: showsPopover) { _, open in if !open { openedByHover = false } }
        .accessibilityLabel(usage.map { ContextRingText.spoken($0) } ?? "Context, not known yet")
        .accessibilityIdentifier("composer-ring")
    }

    @ViewBuilder private var ring: some View {
        if let usage, usage.window == nil {
            // Without a window the share is unknown: a short count takes the ring's place.
            Text(UsageFormat.tokens(usage.tokens)).font(LoomTheme.Typography.statusLabel).monospacedDigit()
        } else {
            let fraction = usage?.fraction
            ZStack {
                Circle().stroke(LoomTheme.ContextRing.track, lineWidth: LoomTheme.ContextRing.lineWidth)
                if let fraction, fraction > 0 {
                    Circle().trim(from: 0, to: fraction)
                        .stroke(fraction >= LoomTheme.Composer.ringRed ? LoomTheme.Status.failure : LoomTheme.ContextRing.arc,
                                style: StrokeStyle(lineWidth: LoomTheme.ContextRing.lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .padding(LoomTheme.ContextRing.lineWidth / 2)
            .frame(width: LoomTheme.ContextRing.diameter, height: LoomTheme.ContextRing.diameter)
        }
    }
}

/// "Context · 120K of 1M (12%)", a bar, Compact Now, and a note that Claude compacts by itself.
struct ComposerContextPopover: View {
    var usage: ContextUsage?
    var canCompact: Bool
    var onCompact: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(usage.map(ComposerBarText.contextLine) ?? "Context \u{00B7} not known yet")
                .font(LoomTheme.Composer.ringPopoverTitle).foregroundStyle(LoomTheme.Text.primary)
            if let fraction = usage?.fraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: LoomTheme.Composer.ringBarRadius).fill(LoomTheme.Surface.chipMeterTrack)
                        RoundedRectangle(cornerRadius: LoomTheme.Composer.ringBarRadius)
                            .fill(fraction >= LoomTheme.Composer.ringRed ? LoomTheme.Status.failure : LoomTheme.Text.secondary)
                            .frame(width: max(2, proxy.size.width * fraction))
                    }
                }
                .frame(height: LoomTheme.Composer.ringBarHeight)
                .padding(.top, LoomTheme.Composer.ringBarMarginTop).padding(.bottom, LoomTheme.Composer.ringBarMarginBottom)
            }
            Text("Claude compacts by itself when it needs room.")
                .font(LoomTheme.Composer.ringPopoverNote).foregroundStyle(LoomTheme.OnPopover.placeholder)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, usage?.fraction == nil ? LoomTheme.Composer.ringBarMarginTop : 0)
            Button("Compact Now", action: onCompact)
                .buttonStyle(ControlButtonStyle(kind: .outline, size: .small)).disabled(!canCompact)
                .help(canCompact ? "Ask Claude to compact this session now" : "Available when Claude is idle and nothing waits for you")
                .padding(.top, LoomTheme.Composer.ringBarMarginTop)
                .accessibilityIdentifier("composer-compact")
        }
        .padding(.horizontal, LoomTheme.Composer.ringPopoverPaddingH).padding(.vertical, LoomTheme.Composer.ringPopoverPaddingV)
        .frame(width: LoomTheme.Composer.ringPopoverWidth, alignment: .leading)
    }
}
