import AppKit
import Foundation
import Testing
@testable import LoomCatalogUI

/// I5's spike, the clock (DESIGN §17 The budget): the rule as a table, and the ticker that follows it.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ArtClockTests {
    private func input(onScreen: Bool = true, visible: Bool = true, unoccluded: Bool = true, active: Bool = true,
                       animated: Bool = true, kind: ArtSurfaceKind = .ambient) -> ArtClockInput {
        ArtClockInput(viewOnScreen: onScreen, windowVisible: visible, windowUnoccluded: unoccluded, appActive: active,
                      animatedArt: animated, kind: kind)
    }

    @Test func theRuleAsATable() {
        let rows: [(ArtClockInput, ArtTick)] = [
            // Seen, in the active app, Animated art on: each kind's cap.
            (input(kind: .ambient), .rate(24)),
            (input(kind: .inPlace), .rate(12)),
            (input(kind: .homeLoop), .rate(12)),
            (input(kind: .arrival), .rate(60)),
            (input(kind: .resting), .still),
            // Animated art off: one still frame, for every kind.
            (input(animated: false, kind: .ambient), .still),
            (input(animated: false, kind: .homeLoop), .still),
            (input(animated: false, kind: .arrival), .still),
            // Nobody can see it: no timer, whatever else holds.
            (input(onScreen: false), .none),
            (input(visible: false), .none),
            (input(unoccluded: false), .none),
            (input(active: false), .none),
            (input(onScreen: false, animated: false), .none),
            (input(unoccluded: false, kind: .homeLoop), .none),
            (input(active: false, kind: .arrival), .none),
        ]
        for (given, expected) in rows { #expect(ArtClock.tick(given) == expected, "\(given)") }
    }

    @Test func everyHiddenCaseHasNoTimerAndNoRateIsOverTheBudget() {
        let flags = [true, false]
        for onScreen in flags {
            for visible in flags {
                for unoccluded in flags {
                    for active in flags {
                        for animated in flags {
                            for kind in ArtSurfaceKind.allCases {
                                let given = input(onScreen: onScreen, visible: visible, unoccluded: unoccluded, active: active,
                                                  animated: animated, kind: kind)
                                let tick = ArtClock.tick(given)
                                let seen = onScreen && visible && unoccluded && active
                                if !seen { #expect(tick == .none, "\(given)") }
                                if seen && !animated { #expect(tick == .still, "\(given)") }
                                if case .rate(let rate) = tick {
                                    let cap: Double = switch kind {
                                    case .ambient: 24
                                    case .inPlace, .homeLoop: 12
                                    case .arrival: 60
                                    case .resting: 0
                                    }
                                    #expect(rate <= cap, "\(given)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The view in a window nobody sees (never ordered front): the rule reads it as hidden, so it has no timer; the ticker
    /// itself starts a link at the rule's rate and drops it for no timer and for a still frame.
    @Test func theViewHasNoTimerWhileHiddenAndTheTickerFollowsTheRule() async throws {
        let view = ArtLayerView(scene: .homeLoop(precomputed: false, seed: 1), cell: LoomTheme.Art.bandCell, kind: .homeLoop)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        try await Task.sleep(for: .milliseconds(50))
        #expect(view.clockInput.windowVisible == false)
        #expect(!view.tickerRunning)
        view.animatedArt = false
        view.animatedArt = true
        #expect(!view.tickerRunning)

        let ticker = ArtTicker(view: view) { _ in }
        ticker.apply(.rate(12))
        #expect(ticker.isRunning && ticker.rate == 12)
        ticker.apply(.rate(24))
        #expect(ticker.isRunning && ticker.rate == 24)
        ticker.apply(.still)
        #expect(!ticker.isRunning && ticker.rate == nil)
        ticker.apply(.rate(12))
        ticker.apply(.none)
        #expect(!ticker.isRunning)
    }
}
