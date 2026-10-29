import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport

/// What both halves of `RenderProbeExclusiveTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum RenderProbeExclusiveShared {
    @MainActor
    final class Log {
        var entries: [String] = []
    }
}
