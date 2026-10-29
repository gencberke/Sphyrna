import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// I5's surfaces as plain values (DESIGN §17's table, Quiet and The budget; §9 The arrival, Later; §20): each place's sharks,
/// alpha and rate kind, the first launch's entry and its remoras, About's one crossing, Home's loop coming back, and the remora:
/// when it arrives, when it swims and that it holds still beside its sentence, never behind it.
@MainActor
@Suite(.timeLimit(.minutes(3)))
struct ArtPlaceTests {
    // MARK: The table

    @Test func eachPlaceDrawsItsSharksAtItsAlphaAndItsRate() {
        #expect(Set(ArtPlaceShared.table.map(\.0)) == Set(ArtPlace.allCases), "every place is in the table, and only these draw art")
        for (place, cast, alpha, kind) in ArtPlaceShared.table {
            #expect(place.cast == cast, "\(place)")
            #expect(abs(place.alpha - alpha) <= 0.07, "\(place): \(place.alpha) is not about \(alpha)")
            #expect(place.kind == kind, "\(place)")
            // The sea it lays holds that cast.
            if case .sea(let specs, let options, _) = place.scene {
                #expect(specs.map(\.kind) == cast, "\(place)")
                #expect(options.alpha == place.alpha, "\(place)")
            }
        }
        // Home's band: one hammerhead on its loop, no plankton and no wake; the panes and the remora have none either.
        for place in ArtPlace.allCases where ![.draftPage, .firstLaunch, .about].contains(place) {
            #expect(place.plankton == 0 && !place.wake, "\(place)")
        }
        if case .homeLoop = ArtPlace.homeBand.scene {} else { Issue.record("the band draws its fixed loop") }
    }

    @Test func noPlaceIsOverItsBudgetAndNoneIsRemorasFace() {
        for place in ArtPlace.allCases {
            let cap: Double = switch place {
            case .draftPage, .firstLaunch, .about: 24
            case .homeBand, .sessionStarting, .readingBranch, .emptyAgents, .emptyChanges, .emptySide, .emptyProject: 12
            }
            #expect(place.kind.maximumRate == cap, "\(place)")
            #expect(place.weight == .regular, "\(place)")
        }
    }

    // MARK: The first launch and About

    private func sea(_ place: ArtPlace, size: CGSize, options change: (inout ArtSea.Options) -> Void = { _ in }) -> ArtSea {
        guard case .sea(let specs, var options, let seed) = place.scene else { fatalError("\(place) is a sea") }
        change(&options)
        return ArtSea(size: size, metrics: ArtMetrics.mono(cell: place.cell), options: options, specs: specs, seed: seed)
    }

    @Test func atTheFirstLaunchTheHammerheadComesInFromTheRightAndTheRemorasKeepToTheBigTwo() {
        let size = ArtEngineTests.draft
        var entering = sea(.firstLaunch, size: size)
        let hammer = entering.sharks[0]
        #expect(hammer.x > size.width * 0.9 && cos(hammer.heading) < -0.9, "in from the right, facing left: \(hammer.x), \(hammer.heading)")
        // Without its entry (Animated art off: one still frame) it is laid like any roaming shark, in view.
        let still = sea(.firstLaunch, size: size) { $0.entering = false }
        #expect(still.sharks[0].x < size.width * 0.9)
        // The remoras keep to their hosts as the school swims.
        for _ in 0..<20 {
            entering.advance(by: 1)
            for remora in entering.sharks.dropFirst(2) {
                let host = entering.sharks[remora.spec.host ?? 0]
                let d = hypot(remora.x - host.x, remora.y - host.y)
                #expect(d < host.length * 1.2, "a remora strays \(d) from its host of \(host.length)")
            }
        }
    }

    @Test func aboutsHammerheadCrossesOnceThenRests() {
        let size = CGSize(width: LoomTheme.Settings.width, height: LoomTheme.Art.aboutHeight)
        var crossing = sea(.about, size: size)
        #expect(crossing.sharks[0].x < 0 && !crossing.hasRested, "it starts left of the page")
        var t = 0.0
        while !crossing.hasRested && t < 30 {
            crossing.advance(by: 0.5)
            t += 0.5
        }
        #expect(crossing.hasRested, "it rests within 30 s")
        #expect(abs(crossing.sharks[0].y - size.height * LoomTheme.Art.aboutStart.y) < 2, "it crosses level, behind the icon")
        #expect(abs(crossing.sharks[0].x - size.width * LoomTheme.Art.aboutRest) < 40, "\(crossing.sharks[0].x)")
        let x = crossing.sharks[0].x
        crossing.advance(by: 5)
        #expect(crossing.sharks[0].x == x, "a rested shark swims no further")
        // Animated art off: it is at rest from the start.
        let still = sea(.about, size: size) { $0.atRest = true }
        #expect(still.hasRested && still.sharks[0].x > size.width * 0.8)
    }

    /// The band's hammerhead swims one closed loop: it reaches both edges of the band, crosses the left edge on the lower pass heading
    /// right, and is where it started after one period.
    @Test func homesLoopCrossesTheBandAndCloses() {
        let size = ArtEngineTests.band
        let loop = ArtHomeLoop(size: size, metrics: ArtMetrics.mono(cell: LoomTheme.Art.bandCell))
        let centreY = size.height * ArtHomeLoop.centre.y
        let samples = (0..<3_600).map { loop.shark(at: Double($0) / 3_600 * ArtHomeLoop.period) }
        #expect(samples.contains { $0.x < 2 } && samples.contains { $0.x > size.width - 2 }, "it reaches both edges")
        #expect(samples.contains { abs($0.x) < 2 && $0.y > centreY && cos($0.heading) > 0.5 },
                "its head crosses the left edge on the lower pass, heading right")
        let start = loop.shark(at: 0), end = loop.shark(at: ArtHomeLoop.period)
        #expect(abs(start.x - end.x) < 0.5 && abs(start.y - end.y) < 0.5, "the loop closes")
    }
}
