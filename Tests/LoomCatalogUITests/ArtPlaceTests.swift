import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import LoomCatalogUI

/// I5's surfaces as plain values (DESIGN §17's table, Quiet and The budget; §9 The arrival, Later; §20): each place's sharks,
/// alpha and rate kind, the first launch's entry and its remoras, About's one crossing, Home's loop coming back, and the remora:
/// when it arrives, when it swims and that it holds still beside its sentence, never behind it.
@MainActor
@Suite(.timeLimit(.minutes(3)))
struct ArtPlaceTests {
    // MARK: The table

    /// §17's numbers, written here rather than read from the theme: "about 0.5", "about 0.45", "about 0.4", "about 0.7", "about 0.8".
    private static let table: [(ArtPlace, [ArtKind], Double, ArtSurfaceKind)] = [
        (.homeBand, [.hammerhead], 0.4, .homeLoop),
        (.draftPage, [.hammerhead, .hammerhead, .whale], 0.5, .ambient),
        (.firstLaunch, [.hammerhead, .whale, .remora, .remora, .remora, .remora], 0.45, .ambient),
        (.about, [.hammerhead], 0.5, .ambient),
        (.sessionStarting, [.hammerhead], 0.7, .inPlace),
        (.readingBranch, [.hammerhead], 0.7, .inPlace),
        (.emptyAgents, [.hammerhead], 0.7, .inPlace),
        (.emptyChanges, [.thresher], 0.7, .inPlace),
        (.emptySide, [.whale], 0.7, .inPlace),
        (.emptyProject, [.hammerhead], 0.7, .inPlace),
        (.remoraLane, [.hammerhead, .remora], 0.8, .arrival),
        (.remoraFold, [.remora], 0.8, .resting),
    ]

    @Test func eachPlaceDrawsItsSharksAtItsAlphaAndItsRate() {
        #expect(Set(Self.table.map(\.0)) == Set(ArtPlace.allCases), "every place is in the table, and only these draw art")
        for (place, cast, alpha, kind) in Self.table {
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

    @Test func noPlaceIsOverItsBudgetAndOnlyTheRemoraIsSemibold() {
        for place in ArtPlace.allCases {
            let cap: Double? = switch place {
            case .draftPage, .firstLaunch, .about: 24
            case .homeBand, .sessionStarting, .readingBranch, .emptyAgents, .emptyChanges, .emptySide, .emptyProject: 12
            case .remoraLane: 60
            case .remoraFold: nil
            }
            #expect(place.kind.maximumRate == cap, "\(place)")
            #expect((place.weight == .semibold) == (place == .remoraLane || place == .remoraFold), "\(place)")
        }
        // The remora's grid is finer than the other sharks'.
        #expect(ArtPlace.remoraLane.cell < ArtPlace.homeBand.cell && ArtPlace.remoraFold.cell < ArtPlace.homeBand.cell)
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

    @Test func homesLoopGivesItsHammerheadBackAtTheLeftOnTheLowerPass() {
        let size = ArtEngineTests.band
        let loop = ArtHomeLoop(size: size, metrics: ArtMetrics.mono(cell: LoomTheme.Art.bandCell))
        let back = loop.shark(at: ArtHomeLoop.backTime)
        #expect(abs(back.x) < 2, "its head at the left edge: \(back.x)")
        #expect(back.y > size.height * ArtHomeLoop.centre.y, "on the lower pass: \(back.y)")
        #expect(cos(back.heading) > 0.5, "heading right: \(back.heading)")
    }

    // MARK: The remora

    @Test func theRemoraSwimsOnlyWhileRemoraReadsWithNothingWrittenAndArrivesOnlyForANewBrief() {
        let rows: [(HomeRemoraState, Bool, HomeRemoraArtPose)] = [
            (.off, false, .none), (.beforeAnySession, false, .none),
            (.reading, false, .swims), (.reading, true, .rests),
            (.brief, true, .rests), (.whenIAsk, false, .rests), (.stoppedBrief, true, .rests),
            (.cannotAnswer(.login), false, .rests), (.cannotAnswer(.wait), false, .rests),
            (.folded, true, .fold),
        ]
        for (state, started, pose) in rows {
            #expect(HomeRemoraArtPose.of(state, sentenceStarted: started) == pose, "\(state) \(started)")
            #expect(HomeRemoraArtPose.arrives(state) == (state == .reading), "\(state)")
        }
    }

    private static let lane = CGSize(width: 1019, height: LoomTheme.Remora.arrivalHeight)
    /// The place and its sentence as the brief lays them: the column starts at the 32 inset, 110 under the section's top.
    private static let row = CGRect(x: 32, y: 110, width: 900, height: LoomTheme.Remora.sentenceRoom)

    @Test func theArrivalPlaysAt60ThenSwimsAt12WhileRemoraReadsThenStandsStill() {
        let metrics = ArtMetrics.mono(cell: LoomTheme.Art.remoraCell, weight: LoomTheme.Art.remoraWeight)
        var arrival = ArtArrival(size: Self.lane, metrics: metrics, rest: HomeRemoraArtLayout.rest(row: Self.row), arriving: true)
        #expect(arrival.kind == .arrival && arrival.sharks.count == 2, "it starts with the host carrying the remora")
        #expect(arrival.host.x > Self.lane.width, "the host comes in from the right")
        var left = 0, t = 0.0
        let dt = 1 / 60.0
        while t < LoomTheme.Art.arrivalTurnEnd - dt {
            if arrival.step(by: dt, swimming: true) { left += 1 }
            t += dt
            #expect(arrival.kind == .arrival, "the 60 fps part lasts its 2.2 s: \(t)")
        }
        // On past 2.2 s: the remora is at its place, swimming at 12 while Remora reads.
        for _ in 0..<60 {
            if arrival.step(by: 1 / 12, swimming: true) { left += 1 }
        }
        #expect(arrival.kind == .inPlace && arrival.stage == .inPlace)
        #expect(left == 1 && arrival.hostGone && arrival.bandReleased && arrival.sharks.count == 1,
                "the host left at the left, and the band had its hammerhead back once")
        // The sentence comes in: it slows and stands still, one frame and no timer.
        var steps = 0
        while arrival.stage != .resting && steps < 60 {
            arrival.step(by: 1 / 12, swimming: false)
            steps += 1
        }
        #expect(arrival.kind == .resting && Double(steps) / 12 <= LoomTheme.Art.arrivalSlow + 0.2, "\(steps) steps at 12")
        // Where it ends is where a remora laid at rest is.
        let raster = ArtRaster()
        let resting = ArtArrival(size: Self.lane, metrics: metrics, rest: HomeRemoraArtLayout.rest(row: Self.row), arriving: false)
        #expect(resting.kind == .resting)
        let a = Set(arrival.frame(raster: raster).packed.map(ArtPackedCell.index))
        let b = Set(resting.frame(raster: raster).packed.map(ArtPackedCell.index))
        #expect(Double(a.symmetricDifference(b).count) <= Double(b.count) * 0.25, "the arrival ends at the rest pose")
    }

    @Test func theRestingRemoraIsBesideItsSentenceNeverBehindIt() {
        let metrics = ArtMetrics.mono(cell: LoomTheme.Art.remoraCell, weight: LoomTheme.Art.remoraWeight)
        let rest = HomeRemoraArtLayout.rest(row: Self.row)
        let resting = ArtArrival(size: Self.lane, metrics: metrics, rest: rest, arriving: false)
        let frame = resting.frame(raster: ArtRaster())
        let lit = frame.packed.map(ArtPackedCell.index)
        #expect(lit.count > 60, "the remora is drawn: \(lit.count)")
        let sentenceStarts = Double(Self.row.minX + LoomTheme.Remora.placeWidth + LoomTheme.Remora.placeGap)
        let rightmost = lit.map { Double($0 % frame.columns + 1) * metrics.cellWidth }.max() ?? 0
        #expect(rightmost <= sentenceStarts, "its cells end at \(rightmost), the sentence starts at \(sentenceStarts)")
        let rows = lit.map { $0 / frame.columns }
        let top = Double(rows.min() ?? 0) * metrics.cellHeight, bottom = Double((rows.max() ?? 0) + 1) * metrics.cellHeight
        #expect(top < Double(Self.row.maxY) && bottom > Double(Self.row.minY), "it rises toward the sentence, in its row: \(top)…\(bottom)")
        // Its disc shows: the plates are bars across the head.
        let bars = [ArtGlyphs.barUpright, ArtGlyphs.barRising, ArtGlyphs.barLevel, ArtGlyphs.barFalling]
        #expect(bars.map { frame.count(of: $0) }.reduce(0, +) > 4)
        // The folded line's remora fits its slot.
        let slot = CGSize(width: LoomTheme.Remora.foldSlot.width, height: LoomTheme.Remora.foldSlot.height)
        let fold = ArtFoldRemora.frame(size: slot, metrics: ArtMetrics.mono(cell: LoomTheme.Art.foldCell, weight: LoomTheme.Art.remoraWeight),
                                       raster: ArtRaster())
        #expect(fold.packed.count > 30)
    }
}
