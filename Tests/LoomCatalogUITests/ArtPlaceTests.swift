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

    // MARK: The first launch and About

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

    /// Front, the menu bar's mark, scaled from its own path data (never a copy of it) to about 36 in the heading and the fold, in
    /// the art's colour at about 0.8.
    @Test func theFaceIsTheMenuBarMarkAtTheHeadingAndFoldSizesInTheArtColour() {
        let mark = MenuBarMark.bounds
        for width in [LoomTheme.Remora.headingFaceWidth, LoomTheme.Remora.foldFaceWidth] {
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
        #expect(abs(LoomTheme.Remora.headingFaceWidth - 36) <= 4 && abs(LoomTheme.Remora.foldFaceWidth - 36) <= 4)
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
