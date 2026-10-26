import AppKit
import LoomCore
import SwiftUI

/// design/DESIGN.md §4: small colored indicators. Working is the braille spinner (`BrailleSpinner`); attention and
/// results are 7 pt dots, State unknown a hollow 8 pt ring in faint.
extension EnvironmentValues {
    /// Whether working indicators may animate: the window is visible and
    /// active and the surface carrying them is on screen. Set by the root views
    /// from the model; static by default.
    @Entry var indicatorsAnimate = false
}

struct IndicatorView: View {
    let indicator: SessionIndicator
    /// False: a working indicator stands on its first frame whatever the window does. A subagent's mark is still; only a
    /// session's own spinner animates (FB6-11).
    var animates = true
    @Environment(\.indicatorsAnimate) private var indicatorsAnimate
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// Failure is a diamond while macOS "Differentiate without color" is on, so it is told from attention and an
    /// unviewed finish by its shape and not by its colour alone; the dot otherwise (D-69, O-12).
    static func drawsDiamond(_ indicator: SessionIndicator, differentiateWithoutColor: Bool) -> Bool {
        ProjectAttention.drawsDiamond(ProjectAttention(indicator), differentiateWithoutColor: differentiateWithoutColor)
    }

    /// Stepped, low-rate animation (not display-rate).
    static let framesPerSecond = LoomTheme.Spinner.framesPerSecond

    /// The spinner runs only for a working conversation in an active, visible
    /// window (contract §10); otherwise it stands on its first frame. Like the system's
    /// own small progress spinners it keeps running under Reduce Motion (user
    /// decision, 6 Oct 2026).
    static func isAnimating(_ indicator: SessionIndicator, indicatorsAnimate: Bool, animates: Bool = true) -> Bool {
        indicator == .working && indicatorsAnimate && animates
    }

    var body: some View {
        Group {
            switch indicator {
            case .working:
                let animating = Self.isAnimating(indicator, indicatorsAnimate: indicatorsAnimate, animates: animates)
                BrailleSpinner(animating: animating)
            case .waitingForApproval, .waitingForInput:
                dot(LoomTheme.Status.attention)
            case .unviewedCompletion:
                dot(LoomTheme.Status.unviewed)
            case .failed, .stopUnverified, .problem:
                if Self.drawsDiamond(indicator, differentiateWithoutColor: differentiateWithoutColor) {
                    Diamond().fill(LoomTheme.Status.failure)
                        .frame(width: LoomTheme.Layout.failureDiamond, height: LoomTheme.Layout.failureDiamond)
                } else {
                    dot(LoomTheme.Status.failure)
                }
            case .identityUnclear:
                ring(LoomTheme.Status.attention)
            case .unknown:
                ring(LoomTheme.Text.faint)
            case .ready, .idle, .stale, .ended:
                Color.clear
            }
        }
        .frame(width: LoomTheme.Layout.indicatorSlot.width, height: LoomTheme.Layout.indicatorSlot.height)
        .accessibilityHidden(true)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: LoomTheme.StatusMark.dot, height: LoomTheme.StatusMark.dot)
    }

    private func ring(_ color: Color) -> some View {
        Circle().strokeBorder(color, lineWidth: LoomTheme.Line.indicatorRing)
            .frame(width: LoomTheme.StatusMark.ring, height: LoomTheme.StatusMark.ring)
    }
}

/// A square standing on its corner, filling its frame.
struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

extension SessionIndicator {
    var labelColor: Color {
        switch self {
        case .waitingForApproval, .waitingForInput, .identityUnclear: LoomTheme.Status.attention
        case .failed, .stopUnverified, .problem: LoomTheme.Status.failure
        case .unviewedCompletion: LoomTheme.Status.unviewed
        default: LoomTheme.Text.secondary
        }
    }
}

extension ProjectAttention {
    var color: Color {
        switch self {
        case .failure: LoomTheme.Status.failure
        case .attention: LoomTheme.Status.attention
        case .unviewed: LoomTheme.Status.unviewed
        }
    }
}

/// Evidence: the spinner animations currently installed in a window's view tree.
public enum IndicatorEvidence {
    @MainActor public static func chases(in view: NSView) -> [String: Any] {
        func find(_ view: NSView) -> [BrailleSpinner.LayerView] {
            (view as? BrailleSpinner.LayerView).map { [$0] } ?? view.subviews.flatMap(find)
        }
        let all = find(view)
        return ["total": all.count, "running": all.filter(\.isRunning).count,
                "presentedFrame": all.first(where: \.isRunning)?.presentedFrame ?? NSNull()]
    }
}
