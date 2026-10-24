import AppKit
import SwiftUI

// Where the sharks swim (DESIGN §17's table and Quiet; §8, §9, §10, §13, §16, §20): every place the app draws art, with its
// cast, its alpha, its grid and its rate kind, as plain values a test reads. Nothing else in the app draws art: never behind the
// terminal, a list, a card's text, the chat or anything being read, and never in the sidebar, the header or the tab row.

enum ArtPlace: String, CaseIterable, Sendable {
    /// Home's band: one hammerhead on its fixed loop, no plankton or wake, at about 0.4 (§9, D-79).
    case homeBand
    /// The new-session page: two hammerheads and the whale shark deep below, at about 0.5 (§8).
    case draftPage
    /// The first launch (the empty catalog's Home): the hammerhead comes in from the right and roams with the whale shark and a
    /// few remoras, at about 0.45, fainter in the message's middle (§9 Empty states, D-79).
    case firstLaunch
    /// About: a hammerhead crosses once behind the icon each time About opens, then rests (§2 item 5).
    case about
    /// A session starting: a small hammerhead swimming in place where a spinner would sit.
    case sessionStarting
    /// The Changes tab reading the branch: the same small hammerhead (§13).
    case readingBranch
    /// The empty Agents tab: a hammerhead.
    case emptyAgents
    /// The empty Changes tab: the thresher.
    case emptyChanges
    /// The empty Side tab: the whale shark (§16).
    case emptySide
    /// An empty project's page: a small hammerhead (§10, D-76).
    case emptyProject

    private typealias A = LoomTheme.Art

    /// The sharks it shows.
    var cast: [ArtKind] {
        switch self {
        case .homeBand, .about, .sessionStarting, .readingBranch, .emptyAgents, .emptyProject: [.hammerhead]
        case .draftPage: [.hammerhead, .hammerhead, .whale]
        case .firstLaunch: [.hammerhead, .whale] + A.firstRemoras.map { _ in ArtKind.remora }
        case .emptyChanges: [.thresher]
        case .emptySide: [.whale]
        }
    }

    /// The art's alpha (DESIGN §17 Quiet).
    var alpha: Double {
        switch self {
        case .homeBand: A.bandAlpha
        case .draftPage: A.draftAlpha
        case .firstLaunch: A.firstAlpha
        case .about: A.aboutAlpha
        case .sessionStarting, .readingBranch, .emptyAgents, .emptyChanges, .emptySide, .emptyProject: A.inPlaceAlpha
        }
    }

    /// Its frame-rate cap: ambient art 24, a shark in place and Home's loop 12. About's crossing is ambient and it rests on one
    /// frame. Remora's face on Home is no art place: it is a still drawing of the menu bar's mark (`HomeRemoraFace`).
    var kind: ArtSurfaceKind {
        switch self {
        case .homeBand: .homeLoop
        case .draftPage, .firstLaunch, .about: .ambient
        case .sessionStarting, .readingBranch, .emptyAgents, .emptyChanges, .emptySide, .emptyProject: .inPlace
        }
    }

    var cell: CGFloat {
        switch self {
        case .homeBand: A.bandCell
        case .draftPage: A.ambientCell
        case .firstLaunch: A.firstCell
        case .about: A.aboutCell
        case .sessionStarting, .readingBranch, .emptyAgents, .emptyChanges, .emptySide, .emptyProject: A.inPlaceCell
        }
    }

    /// Every place draws in regular glyphs.
    var weight: NSFont.Weight { .regular }

    var mask: ArtMask {
        switch self {
        case .homeBand: .band
        case .draftPage: .calm
        case .firstLaunch: .firstLaunch
        default: .none
        }
    }

    /// Plankton and wake: the open seas have them; Home's loop, the panes and the remora do not.
    var plankton: Int {
        switch self {
        case .draftPage: A.draftPlankton
        case .firstLaunch: A.firstPlankton
        case .about: A.aboutPlankton
        default: 0
        }
    }

    var wake: Bool {
        switch self {
        case .draftPage, .firstLaunch, .about: true
        default: false
        }
    }

    /// The length of the one shark a pane shows in place.
    var inPlaceLength: Double? {
        switch self {
        case .sessionStarting, .readingBranch: A.waitingLength
        case .emptyAgents: A.emptyAgentsLength
        case .emptyChanges: A.emptyChangesLength
        case .emptySide: A.emptySideLength
        case .emptyProject: A.emptyProjectLength
        default: nil
        }
    }

    /// The sharks of a sea, as the reference lays them.
    var specs: [ArtSharkSpec] {
        switch self {
        case .draftPage:
            return ArtScenes.draft
        case .firstLaunch:
            let big = [ArtSharkSpec(kind: .hammerhead, length: 300, depth: 1, speed: 15, angle: Double.pi, entry: A.firstEntry),
                       ArtSharkSpec(kind: .whale, length: 640, depth: 0.34, speed: 7)]
            return big + A.firstRemoras.map {
                ArtSharkSpec(kind: .remora, length: $0.length, depth: $0.depth, speed: A.firstRemoraSpeed, host: $0.host, spot: $0.spot)
            }
        case .about:
            return [ArtSharkSpec(kind: .hammerhead, length: A.aboutLength, depth: 1, speed: A.aboutSpeed, place: A.aboutStart, angle: 0,
                                 restsAt: A.aboutRest)]
        default:
            guard let length = inPlaceLength, let kind = cast.first else { return [] }
            return ArtScenes.inPlace(kind, length: length)
        }
    }

    /// What the view draws.
    var scene: ArtScene {
        switch self {
        case .homeBand: .homeLoop(precomputed: false, seed: 1)
        default: .sea(specs: specs, options: ArtSea.Options(alpha: alpha, plankton: plankton, wake: wake), seed: seed)
        }
    }

    private var seed: UInt64 {
        switch self {
        case .draftPage: 3
        case .firstLaunch: 9
        case .about: 11
        default: 5
        }
    }

    /// A drawing that crosses once comes back to its start each time its window shows again (About).
    var replaysWhenShown: Bool { self == .about }
}
