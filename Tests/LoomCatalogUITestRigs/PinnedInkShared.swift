import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

/// What both halves of `PinnedInkTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum PinnedInkShared {
    typealias Pinned = LoomTheme.Pinned

    typealias Appearance = LoomTheme.Appearance
}

/// `PinnedInkTests`'s fixtures, for both halves of the suite.
protocol PinnedInkFixtures {}

extension PinnedInkFixtures {
    typealias Pinned = PinnedInkShared.Pinned

    typealias Appearance = PinnedInkShared.Appearance
}
