#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI

/// The edges' glue (I4c: the ended line, the record, the banners, the menu bar), driven through the model's own slots.
///
/// - `edge-banner:<failure|attention|note|progress>`: raises one top banner of that kind, through the slot the app uses for it
///   (`raiseBannerForEvidence`). Raise several to see the stack's "+N".
/// - `edge-banner-clear`: takes every slot back (`clearBannersForEvidence`).
/// - `edge-banner-peek:<open|close>`: what a click on "+N" does.
/// The snapshot gains `edges{bannerStack, bannerPeekOpen}`: ids, tones and numbers only, never a line.
@MainActor
extension DevelopmentEvidence {
    /// Returns false when `name` is not one of these commands.
    func handleEdgeCommand(_ name: String, _ argument: String) async -> Bool {
        guard let model = app?.model else { return false }
        switch name {
        case "edge-banner": return model.raiseBannerForEvidence(argument)
        case "edge-banner-clear": model.clearBannersForEvidence()
        case "edge-banner-peek": model.setBannerPeekOpenForEvidence(argument == "open")
        default: return false
        }
        return true
    }
}

extension AppDelegate {
    /// The edges in numbers and ids for the snapshot.
    var edgeEvidence: [String: Any] {
        guard let model else { return [:] }
        return ["bannerStack": model.bannerStackForEvidence, "bannerPeekOpen": model.bannerPeekOpenForEvidence]
    }
}
#endif
