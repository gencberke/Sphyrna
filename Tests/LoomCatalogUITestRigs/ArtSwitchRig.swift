import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport

/// Shared by `ArtSwitchTests` and the tests of other tiers that reuse its fixtures (DEVELOPMENT §3.1).
enum ArtSwitchRig {
    static func arts(in view: NSView) -> [ArtLayerView] {
        (view as? ArtLayerView).map { [$0] } ?? view.subviews.flatMap(arts(in:))
    }
}
