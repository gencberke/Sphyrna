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

    @Test func homesLoopGivesItsHammerheadBackAtTheLeftOnTheLowerPass() {
        let size = ArtEngineTests.band
        let loop = ArtHomeLoop(size: size, metrics: ArtMetrics.mono(cell: LoomTheme.Art.bandCell))
        let back = loop.shark(at: ArtHomeLoop.backTime)
        #expect(abs(back.x) < 2, "its head at the left edge: \(back.x)")
        #expect(back.y > size.height * ArtHomeLoop.centre.y, "on the lower pass: \(back.y)")
        #expect(cos(back.heading) > 0.5, "heading right: \(back.heading)")
    }

    // MARK: Remora's face

    @Test func theFaceShowsInTheBriefsPlaceOrTheFoldAndFadesInOnlyForANewBrief() {
        let rows: [(HomeRemoraState, HomeRemoraArtPose)] = [
            (.off, .none), (.beforeAnySession, .none), (.reading, .rests), (.brief, .rests), (.whenIAsk, .rests),
            (.stoppedBrief, .rests), (.cannotAnswer(.login), .rests), (.cannotAnswer(.wait), .rests), (.folded, .fold),
        ]
        for (state, pose) in rows {
            #expect(HomeRemoraArtPose.of(state) == pose, "\(state)")
            #expect(HomeRemoraArtPose.arrives(state) == (state == .reading), "\(state)")
        }
    }

    /// Front, the menu bar's mark, scaled from its own path data (never a copy of it) to about 64 and about 36, in the art's colour
    /// at about 0.8.
    @Test func theFaceIsTheMenuBarMarkAtTheTwoSizesInTheArtColour() {
        let mark = MenuBarMark.bounds
        for width in [LoomTheme.Remora.faceWidth, LoomTheme.Remora.foldFaceWidth] {
            let parts = HomeRemoraFace.parts(width: width)
            #expect(parts.count == MenuBarMark.paths.count, "every part of the mark")
            let box = parts.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }
            #expect(abs(box.width - width) < 0.01 && abs(box.minX) < 0.01 && abs(box.minY) < 0.01, "\(box)")
            #expect(abs(box.height - HomeRemoraFace.height(width: width)) < 0.01)
            let scale = width / mark.width
            for (part, source) in zip(parts, MenuBarMark.paths) {
                let a = part.boundingBoxOfPath, b = source.boundingBoxOfPath
                #expect(abs(a.width - b.width * scale) < 0.01 && abs(a.minX - (b.minX - mark.minX) * scale) < 0.01, "the same path, scaled")
            }
        }
        #expect(abs(LoomTheme.Remora.faceWidth - 64) <= 4 && abs(LoomTheme.Remora.foldFaceWidth - 36) <= 4)
        #expect(HomeRemoraFace.color == LoomTheme.Surface.art && abs(HomeRemoraFace.opacity - 0.8) <= 0.05)
    }

    /// A new brief takes the face from 0 to 1 with an animation; nothing keeps ticking.
    @Test func aNewBriefFadesTheFaceIn() async {
        let art = HomeRemoraArt()
        #expect(art.fade == 1)
        art.arrival(reduceMotion: true)
        #expect(art.fade == 0, "it starts unseen")
        for _ in 0..<20 where art.fade != 1 { await Task.yield() }
        #expect(art.fade == 1)
    }
}
