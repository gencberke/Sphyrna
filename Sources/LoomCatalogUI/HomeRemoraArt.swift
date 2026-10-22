import Observation
import SwiftUI

// The art of Home's Remora section (DESIGN §9 Remora's place, The arrival, Reading and writing, Later; §17; §20): the band's
// hammerhead on its loop, the lane where the arrival plays and the remora rests beside its sentence, and the remora at the
// start of the folded line.

/// What the remora does for a state of the section, as a plain value.
enum HomeRemoraArtPose: Equatable {
    /// No remora: Remora is off, or there is no session yet (the band stands in the section's place).
    case none
    /// At its place beside the sentence, still.
    case rests
    /// At its place, swimming: Remora reads and its sentence has not come in.
    case swims
    /// At the start of the folded brief's line, still.
    case fold

    /// It holds still while the sentence can be read; it swims only while Remora reads with nothing written yet.
    static func of(_ state: HomeRemoraState, sentenceStarted: Bool) -> HomeRemoraArtPose {
        switch state {
        case .off, .beforeAnySession: .none
        case .reading: sentenceStarted ? .rests : .swims
        case .cannotAnswer, .stoppedBrief, .brief, .whenIAsk: .rests
        case .folded: .fold
        }
    }

    /// The arrival plays when a new brief starts being written (the first Home of the day, Catch Me Up); never for a state
    /// without a call (When I ask), a failure or the fold.
    static func arrives(_ state: HomeRemoraState) -> Bool { state == .reading }
}

/// Where the remora rests in the section: its head `remoraRestInset` inside the place's trailing edge, level with the middle of the
/// sentence's room, lifted by half its rise (the reference's `homeLayout().rest`). `row` is the place and its sentence, in the
/// section's space.
enum HomeRemoraArtLayout {
    static let space = "home-remora-section"

    static func rest(row: CGRect) -> CGPoint {
        typealias A = LoomTheme.Art
        return CGPoint(x: row.minX + LoomTheme.Remora.placeWidth - A.remoraRestInset,
                       y: row.minY + row.height / 2 + A.remoraLength * sin(A.remoraRise) / 2)
    }
}

/// What the section's art keeps while Home shows: where the place is, whether an arrival is asked for, the band's hammerhead and
/// the fade that stands for the arrival with Animated art off.
@MainActor @Observable
final class HomeRemoraArt {
    /// The place and its sentence, in the section's space; nil until laid out.
    var row: CGRect?
    var arrive = false
    var band = ArtBandCue()
    var fade = 1.0
    var rest: CGPoint? { row.map(HomeRemoraArtLayout.rest(row:)) }

    /// A new brief is being written. With Animated art on, the band's hammerhead swims in carrying the remora; off, the remora
    /// fades in at its place (instantly under Reduce Motion, which makes every transition instant).
    func arrival(animated: Bool, reduceMotion: Bool) {
        guard animated else {
            fade = 0
            Task { @MainActor [weak self] in
                withAnimation(reduceMotion ? nil : .easeOut(duration: LoomTheme.Art.remoraFadeIn)) { self?.fade = 1 }
            }
            return
        }
        arrive = true
        band.away = true
    }

    func lane(_ event: ArtLaneEvent) {
        // The lane reports from inside a view update: the change waits for the next turn of the run loop.
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch event {
            case .started:
                arrive = false
            case .bandBack:
                guard band.away else { return }
                band.away = false
                band.backs += 1
            }
        }
    }

    /// Animated art turned off: nothing is carried any more, and the band's hammerhead is back on its loop at once.
    func stopMoving() {
        arrive = false
        if band.away {
            band.away = false
            band.backs += 1
        }
    }
}

extension EnvironmentValues {
    /// The section's art, for the brief's place to report where it is.
    @Entry var homeRemoraArt: HomeRemoraArt? = nil
}

/// The section's art behind it: the faint grid and the band's hammerhead, and the lane of the arrival and the resting remora.
struct HomeRemoraArtBackdrop: View {
    let art: HomeRemoraArt
    let pose: HomeRemoraArtPose

    var body: some View {
        ZStack(alignment: .top) {
            ArtBackdrop(place: .homeBand, grid: .band, band: art.band).frame(height: LoomTheme.Canvas.bandHeight)
            if pose == .rests || pose == .swims {
                ArtSurface(place: .remoraLane, remora: ArtRemoraCue(rest: art.rest, arrive: art.arrive, swimming: pose == .swims),
                           onLaneEvent: { [art] in art.lane($0) })
                    .frame(height: LoomTheme.Remora.arrivalHeight)
                    .opacity(art.fade)
                    .accessibilityIdentifier("home-remora-arrival")
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
