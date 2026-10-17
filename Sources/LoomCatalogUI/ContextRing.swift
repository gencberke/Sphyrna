import LoomCore
import SwiftUI

/// The words of the context ring: tokens first, a percentage only where the model's window is known.
enum ContextRingText {
    /// `84K` or `84K · 42%`; the label beside the ring and the head of its tooltip.
    static func label(_ usage: ContextUsage) -> String {
        let tokens = UsageFormat.tokens(usage.tokens)
        guard let percent = usage.percent else { return tokens }
        return "\(tokens) · \(percent)%"
    }

    /// The tooltip: `Context: 84,200 of 200,000 tokens (42%)`, or without the window `Context: 84,200 tokens`.
    static func detail(_ usage: ContextUsage) -> String {
        let used = UsageFormat.grouped(usage.tokens)
        guard let window = usage.window, let percent = usage.percent else { return "Context: \(used) tokens" }
        return "Context: \(used) of \(UsageFormat.grouped(window)) tokens (\(percent)%)"
    }

    /// What VoiceOver says: the same facts with spoken counts.
    static func spoken(_ usage: ContextUsage) -> String {
        let used = UsageFormat.spokenTokens(usage.tokens)
        guard let window = usage.window, let percent = usage.percent else { return "Context, \(used) tokens" }
        return "Context, \(used) of \(UsageFormat.spokenTokens(window)) tokens, \(percent) percent"
    }
}

/// One session's context as a ring (the composer's, the sidebar's and the inspector's). With a known
/// window the arc shows the share; without one the track alone is drawn, since a share would be a guess.
/// `ContextUsage` comes from `UsageModel.contexts`; the ring reads nothing itself.
struct ContextRing: View {
    let usage: ContextUsage
    /// Tokens (and the share) as text beside the ring.
    var showsLabel = false

    var body: some View {
        HStack(spacing: LoomTheme.ContextRing.labelGap) {
            ring
            if showsLabel {
                Text(ContextRingText.label(usage))
                    .font(LoomTheme.Typography.statusLabel).monospacedDigit()
                    .foregroundStyle(LoomTheme.Text.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: LoomTheme.ContextRing.hitSide, minHeight: LoomTheme.ContextRing.hitSide)
        .help(ContextRingText.detail(usage))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ContextRingText.spoken(usage))
    }

    private var ring: some View {
        let fraction = usage.fraction
        return ZStack {
            Circle().stroke(LoomTheme.ContextRing.track, lineWidth: LoomTheme.ContextRing.lineWidth)
            if let fraction, fraction > 0 {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(fraction >= LoomTheme.ContextRing.nearlyFull ? LoomTheme.ContextRing.arcFull : LoomTheme.ContextRing.arc,
                            style: StrokeStyle(lineWidth: LoomTheme.ContextRing.lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
        // The stroke is centred on the circle's edge: inset by half of it so the ring is `diameter` wide.
        .padding(LoomTheme.ContextRing.lineWidth / 2)
        .frame(width: LoomTheme.ContextRing.diameter, height: LoomTheme.ContextRing.diameter)
    }
}

#Preview("Context ring") {
    VStack(alignment: .leading, spacing: 8) {
        ContextRing(usage: ContextUsage(tokens: 76_000, window: 200_000, model: "claude-opus-5-5"), showsLabel: true)
        ContextRing(usage: ContextUsage(tokens: 190_000, window: 200_000, model: "claude-opus-5-5"), showsLabel: true)
        ContextRing(usage: ContextUsage(tokens: 84_200, window: nil, model: "claude-new-model"), showsLabel: true)
    }
    .padding(16)
    .background(LoomTheme.Surface.card)
    .environment(\.colorScheme, .dark)
}
