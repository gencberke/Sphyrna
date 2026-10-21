#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI

/// Remora's glue (L3b: the brief, the field, the memory sheet): no command yet. Every call of the model's Remora API
/// written here counts in `RemoraReachTests`.
/// The snapshot gains `remora{}`: ids and numbers only, never a title, a question or an answer.
@MainActor
extension DevelopmentEvidence {
    /// Returns false when `name` is not one of these commands.
    func handleRemoraCommand(_ name: String, _ argument: String) async -> Bool {
        false
    }
}

extension AppDelegate {
    /// Remora in numbers and ids for the snapshot.
    var remoraEvidence: [String: Any] { [:] }
}
#endif
