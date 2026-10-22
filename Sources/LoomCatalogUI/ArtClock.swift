import AppKit
import QuartzCore

// When the art draws (DESIGN §17 The budget): a pure rule from where the view is and what Settings says to no timer, one
// still frame or a rate, and the ticker that follows it.

/// What a drawing is, for its frame-rate cap.
enum ArtSurfaceKind: Sendable, CaseIterable {
    /// The new-session page and the first launch: at most 24 frames a second.
    case ambient
    /// A small shark swimming in place in a pane: at most 12.
    case inPlace
    /// Home's band: at most 12.
    case homeLoop
    /// Remora's arrival on Home, the one scripted motion: at most 60 for its 2.2 s.
    case arrival
    /// A drawing that never moves (the resting remora): one frame.
    case resting

    var maximumRate: Double? {
        switch self {
        case .ambient: LoomTheme.Art.ambientFPS
        case .inPlace: LoomTheme.Art.inPlaceFPS
        case .homeLoop: LoomTheme.Art.homeLoopFPS
        case .arrival: LoomTheme.Art.arrivalFPS
        case .resting: nil
        }
    }
}

/// What the rule reads.
struct ArtClockInput: Sendable, Equatable {
    /// The view is in a window, not hidden and has some of itself on screen.
    var viewOnScreen: Bool
    /// The window is visible: ordered in, not minimised.
    var windowVisible: Bool
    /// macOS says some of the window can be seen (not occluded).
    var windowUnoccluded: Bool
    /// Sphyrna is the active app.
    var appActive: Bool
    /// Settings → Theme → Animated art (on by default, D-79).
    var animatedArt: Bool
    var kind: ArtSurfaceKind
}

/// What the rule decides.
enum ArtTick: Sendable, Equatable {
    /// No timer and no wakeups: nothing can see it.
    case none
    /// One frame, drawn once, then no timer.
    case still
    /// A timer at this many frames a second.
    case rate(Double)
}

enum ArtClock {
    /// Off screen, in the background, or under an occluded or hidden window: no timer. Animated art off, or a drawing that
    /// never moves: one still frame. Otherwise the kind's cap.
    static func tick(_ input: ArtClockInput) -> ArtTick {
        guard input.viewOnScreen, input.windowVisible, input.windowUnoccluded, input.appActive else { return .none }
        guard input.animatedArt, let rate = input.kind.maximumRate else { return .still }
        return .rate(rate)
    }
}

/// Follows the rule for one view: a display link at the rule's rate while it says so, and none otherwise. A frame comes
/// at most every 1/rate s; the time it hands on is the time since the last frame, at most `LoomTheme.Art.longestStep`,
/// so a pause never jumps the art on.
@MainActor
final class ArtTicker: NSObject {
    private weak var view: NSView?
    private let onFrame: @MainActor (Double) -> Void
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private(set) var tick: ArtTick = .none

    /// The rate the link runs at, nil when there is no link.
    var rate: Double? {
        guard case .rate(let rate) = tick, link != nil else { return nil }
        return rate
    }
    var isRunning: Bool { link != nil }

    init(view: NSView, onFrame: @escaping @MainActor (Double) -> Void) {
        self.view = view
        self.onFrame = onFrame
    }

    func apply(_ next: ArtTick) {
        guard next != tick || (link == nil && isRate(next)) else { return }
        tick = next
        switch next {
        case .none, .still:
            stop()
        case .rate(let rate):
            if link == nil, let view {
                let link = view.displayLink(target: self, selector: #selector(step(_:)))
                link.add(to: .main, forMode: .common)
                self.link = link
            }
            let range = Float(rate)
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: range / 2, maximum: range, preferred: range)
            last = nil
        }
    }

    private func isRate(_ tick: ArtTick) -> Bool {
        guard case .rate = tick else { return false }
        return true
    }

    func stop() {
        link?.invalidate()
        link = nil
        last = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard case .rate(let rate) = tick else { return }
        let now = link.timestamp
        guard let previous = last else {
            last = now
            return
        }
        let elapsed = now - previous
        // The cap: a link that comes early (a 60 Hz display under a 24 cap) waits for the next.
        if elapsed < 0.9 / rate { return }
        last = now
        onFrame(min(LoomTheme.Art.longestStep, elapsed))
    }
}
