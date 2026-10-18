import LoomChat
import LoomCore
import SwiftUI

/// The pieces of the composer's bar, which the draft's composer and the session's own composer share (D-58, after Codex's
/// bar): + on the left, the permission mode as plain text with a shield, then the context ring, the model with its effort
/// in a lighter tone, and a round Send. No boxes around the controls, and no mode gets a warning colour or mark.

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

/// A plain-text control of the bar: an optional symbol, the title, an optional lighter word after it, and a chevron.
struct ComposerChipLabel: View {
    var symbol: String?
    var title: String
    var lighter: String?
    var titleColor: Color = LoomTheme.Composer.modeColor

    var body: some View {
        HStack(spacing: LoomTheme.Composer.chipGap) {
            if let symbol { Image(systemName: symbol).font(LoomTheme.Composer.barIcon) }
            Text(title).font(LoomTheme.Composer.barFont).lineLimit(1).truncationMode(.tail)
            if let lighter {
                Text(lighter).font(LoomTheme.Composer.barFont).foregroundStyle(LoomTheme.Composer.effortColor).lineLimit(1)
            }
            Image(systemName: "chevron.down").font(LoomTheme.Composer.chevron).foregroundStyle(LoomTheme.Text.tertiary)
        }
        .foregroundStyle(titleColor)
        .padding(.horizontal, LoomTheme.Space.cardH - 1)
        .frame(minHeight: LoomTheme.Composer.controlSide)
        .contentShape(Rectangle())
    }
}

extension View {
    /// A menu that is only its label, in the bar's style.
    func composerMenuStyle() -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// What the Send button looks like.
enum ComposerSendLook: Equatable {
    case disabled
    case send
    case afterTurn
    case stop
    case update
    case resume
}

/// The round Send button: light when it can act, dim when there is nothing to send, a square for Interrupt.
struct ComposerSendButton: View {
    var look: ComposerSendLook
    var label: String
    var help: String
    var identifier: String
    var action: (_ commandHeld: Bool) -> Void

    var body: some View {
        let enabled = look != .disabled
        Button {
            action(NSEvent.modifierFlags.contains(.command))
        } label: {
            glyph(enabled: enabled)
                .frame(width: LoomTheme.Composer.sendSide, height: LoomTheme.Composer.sendSide)
                .background(Circle().fill(enabled ? LoomTheme.Composer.sendFill : LoomTheme.Surface.controlPressed))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .padding(.leading, LoomTheme.Composer.sendGap)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private func glyph(enabled: Bool) -> some View {
        let color = enabled ? LoomTheme.Accent.onAccent : LoomTheme.Text.tertiary
        switch look {
        case .stop:
            RoundedRectangle(cornerRadius: LoomTheme.Composer.stopRadius).fill(color)
                .frame(width: LoomTheme.Composer.stopGlyph, height: LoomTheme.Composer.stopGlyph)
        case .afterTurn:
            Image(systemName: "clock").font(LoomTheme.Composer.sendIcon).foregroundStyle(color)
        case .update:
            Image(systemName: "checkmark").font(LoomTheme.Composer.sendIcon).foregroundStyle(color)
        case .resume:
            Image(systemName: "play.fill").font(LoomTheme.Composer.barIcon).foregroundStyle(color)
        case .send, .disabled:
            Image(systemName: "arrow.up").font(LoomTheme.Composer.sendIcon).foregroundStyle(color)
        }
    }
}

/// The context ring of the bar (CHAT-SPEC → The bar): the ring alone while the window is known, a short token count in its
/// place when it is not; red above 90 %. After 150 ms of hover (or a click) a popover shows the figures.
struct ComposerRing: View {
    var usage: ContextUsage?
    var canCompact: Bool
    var onCompact: () -> Void
    @Binding var showsPopover: Bool
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Button { showsPopover.toggle() } label: {
            ring
                .frame(minWidth: LoomTheme.Composer.controlSide, minHeight: LoomTheme.Composer.controlSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoverTask?.cancel()
            if inside {
                hoverTask = Task {
                    try? await Task.sleep(for: .seconds(LoomTheme.Composer.ringHoverDelay))
                    guard !Task.isCancelled else { return }
                    showsPopover = true
                }
            }
        }
        .popover(isPresented: $showsPopover, arrowEdge: .top) {
            ComposerContextPopover(usage: usage, canCompact: canCompact) {
                showsPopover = false
                onCompact()
            }
        }
        .accessibilityLabel(usage.map { ContextRingText.spoken($0) } ?? "Context, not known yet")
        .accessibilityIdentifier("composer-ring")
    }

    @ViewBuilder private var ring: some View {
        if let usage, usage.window == nil {
            // Without a window the share is unknown: a short count takes the ring's place.
            Text(UsageFormat.tokens(usage.tokens)).font(LoomTheme.Typography.statusLabel).monospacedDigit()
                .foregroundStyle(LoomTheme.Text.secondary)
        } else {
            let fraction = usage?.fraction
            ZStack {
                Circle().stroke(LoomTheme.ContextRing.track, lineWidth: LoomTheme.ContextRing.lineWidth)
                if let fraction, fraction > 0 {
                    Circle().trim(from: 0, to: fraction)
                        .stroke(fraction >= LoomTheme.Composer.ringRed ? LoomTheme.Status.failure : LoomTheme.ContextRing.arc,
                                style: StrokeStyle(lineWidth: LoomTheme.ContextRing.lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
            }
            .padding(LoomTheme.ContextRing.lineWidth / 2)
            .frame(width: LoomTheme.ContextRing.diameter, height: LoomTheme.ContextRing.diameter)
        }
    }
}

/// "Context · 120K of 1M (12%)", a bar, Compact now, and a note that Claude compacts by itself.
struct ComposerContextPopover: View {
    var usage: ContextUsage?
    var canCompact: Bool
    var onCompact: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.headerSpacing * 2) {
            Text(usage.map(ComposerBarText.contextLine) ?? "Context \u{00B7} not known yet")
                .font(LoomTheme.Typography.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
            if let fraction = usage?.fraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: LoomTheme.Composer.ringBarRadius).fill(LoomTheme.Surface.chipMeterTrack)
                        RoundedRectangle(cornerRadius: LoomTheme.Composer.ringBarRadius)
                            .fill(fraction >= LoomTheme.Composer.ringRed ? LoomTheme.Status.failure : LoomTheme.Text.primary)
                            .frame(width: max(2, proxy.size.width * fraction))
                    }
                }
                .frame(height: LoomTheme.Composer.ringBarHeight)
            }
            Button("Compact now", action: onCompact)
                .buttonStyle(ChipButtonStyle()).disabled(!canCompact)
                .help(canCompact ? "Ask Claude to compact this session now" : "Available when Claude is idle and nothing waits for you")
                .accessibilityIdentifier("composer-compact")
            Text("Claude compacts by itself when the context nears its limit.")
                .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.OnPopover.placeholder)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(LoomTheme.Space.requestPadding + LoomTheme.Space.headerSpacing)
        .frame(width: LoomTheme.Composer.ringPopoverWidth, alignment: .leading)
        .background(LoomTheme.Surface.popover)
    }
}
