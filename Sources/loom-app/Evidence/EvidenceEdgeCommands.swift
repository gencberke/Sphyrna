#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI

/// The edges' glue (I4c: the ended line, the record, the banners, the menu bar): no command yet.
/// The snapshot gains `edges{}`: ids and numbers only, never a title or a line.
@MainActor
extension DevelopmentEvidence {
    /// Returns false when `name` is not one of these commands.
    func handleEdgeCommand(_ name: String, _ argument: String) async -> Bool {
        false
    }
}

extension AppDelegate {
    /// The edges in numbers and ids for the snapshot.
    var edgeEvidence: [String: Any] { [:] }
}
#endif
