import Observation
import SwiftUI

// The art of Home's Remora section (DESIGN §9 Remora's place, The arrival, Later; §17; §20): the band's hammerhead on its loop
// behind the section, and Remora's face, Front (the menu bar's mark), still in the brief's place and at the start of the folded line.

/// Where Remora's face shows for a state of the section, as a plain value.
enum HomeRemoraArtPose: Equatable {
    /// No face: Remora is off, or there is no session yet (the band stands in the section's place).
    case none
    /// In the brief's place, beside the sentence.
    case rests
    /// At the start of the folded brief's line.
    case fold

    static func of(_ state: HomeRemoraState) -> HomeRemoraArtPose {
        switch state {
        case .off, .beforeAnySession: .none
        case .reading, .cannotAnswer, .stoppedBrief, .brief, .whenIAsk: .rests
        case .folded: .fold
        }
    }

    /// The face fades in when a new brief starts being written (the first Home of the day, Catch Me Up); never for a state without
    /// a call (When I ask), a failure or the fold.
    static func arrives(_ state: HomeRemoraState) -> Bool { state == .reading }
}

/// What the section's art keeps while Home shows: the face's opacity, which a new brief takes from 0 to 1.
@MainActor @Observable
final class HomeRemoraArt {
    var fade = 1.0

    /// A new brief is being written: the face fades in at its place over 0.6 s, at once under Reduce Motion (D-79). An animation, not
    /// a clock: nothing ticks once it has run.
    func arrival(reduceMotion: Bool) {
        fade = 0
        Task { @MainActor [weak self] in
            withAnimation(reduceMotion ? nil : .easeOut(duration: LoomTheme.Art.remoraFadeIn)) { self?.fade = 1 }
        }
    }
}

extension EnvironmentValues {
    /// The section's art, for the brief's place to read the face's fade.
    @Entry var homeRemoraArt: HomeRemoraArt? = nil
}

/// The section's art behind it: the faint grid and the band's hammerhead on its own loop.
struct HomeRemoraArtBackdrop: View {
    var body: some View {
        ArtBackdrop(place: .homeBand, grid: .band).frame(height: LoomTheme.Canvas.bandHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Remora's face: Front, the menu bar's mark (`MenuBarMark`, D-77), drawn from the same path data scaled to a width, in the art's
/// colour at about 0.8. Still: one drawing, no clock. Each part is filled on its own with the even-odd rule, as the menu bar does.
struct HomeRemoraFace: View {
    let width: CGFloat

    /// The mark's parts scaled so the mark is `width` wide, its box at the origin.
    static func parts(width: CGFloat) -> [CGPath] {
        let bounds = MenuBarMark.bounds
        let scale = width / bounds.width
        var transform = CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: -bounds.minX, y: -bounds.minY)
        return MenuBarMark.paths.compactMap { $0.copy(using: &transform) }
    }

    static func height(width: CGFloat) -> CGFloat { width * MenuBarMark.bounds.height / MenuBarMark.bounds.width }

    static let color = LoomTheme.Surface.art
    static let opacity = LoomTheme.Remora.faceOpacity

    var body: some View {
        let parts = Self.parts(width: width)
        Canvas { context, _ in
            for part in parts {
                context.fill(Path(part), with: .color(Self.color), style: FillStyle(eoFill: true))
            }
        }
        .frame(width: width, height: Self.height(width: width))
        .opacity(Self.opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
