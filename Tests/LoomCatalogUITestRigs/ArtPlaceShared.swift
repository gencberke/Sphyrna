import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import LoomCatalogUI
import LoomTestSupport

/// What both halves of `ArtPlaceTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum ArtPlaceShared {
    /// §17's numbers, written here rather than read from the theme: "about 0.5", "about 0.45", "about 0.4", "about 0.7", "about 0.8".
    @MainActor
    static let table: [(ArtPlace, [ArtKind], Double, ArtSurfaceKind)] = [
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
}
