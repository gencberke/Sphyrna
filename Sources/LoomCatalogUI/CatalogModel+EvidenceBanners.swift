import Foundation

/// An inert seam for the evidence run (DEVELOPMENT §5, `edge-banner:<kind>`): it raises each kind of top banner through the same
/// slots the app uses, so a shot can show the stack without a real failure. Nothing in the app calls it; the development flavor's
/// command does. The words are the app's own for each tone, with the name the code still uses.
extension CatalogModel {
    /// The kinds the seam can raise: `failure` (a start that did not work), `attention` (the missing helper), `note` (a project that
    /// is already in the app) and `progress` (quitting).
    public static let evidenceBannerKinds = ["failure", "attention", "note", "progress"]

    /// Raises one banner of that kind; false for a kind it does not know.
    @discardableResult
    public func raiseBannerForEvidence(_ kind: String) -> Bool {
        switch kind {
        case "failure":
            reportFailure("Claude could not be started. claude was not found on the PATH of your terminal environment (14 folders searched).")
        case "attention":
            ownershipNotice = "New sessions are turned off because Sphyrna's process helper is missing. Without it Sphyrna cannot make sure "
                + "Stop and Quit end all of a session's background work. Reinstall Sphyrna to fix this."
        case "note":
            showInfo("“loom” is already in Sphyrna.")
        case "progress":
            statusMessage = "Stopping sessions before quitting…"
        default:
            return false
        }
        return true
    }

    /// Takes every slot back: the stack is empty again.
    public func clearBannersForEvidence() {
        dismissError()
        dismissInfo()
        ownershipNotice = nil
        statusMessage = nil
    }

    /// What a click on "+N" does: opens the other boxes under the first, or closes them again. The window's stack registers itself
    /// while it is on screen.
    public func setBannerPeekOpenForEvidence(_ open: Bool) { BannerStackState.current?.open = open }

    public var bannerPeekOpenForEvidence: Bool { BannerStackState.current?.open ?? false }

    /// The boxes the top stack shows now, first to last, as `kind:tone` ids (numbers and ids only, never the text).
    public var bannerStackForEvidence: [String] {
        Banners.items(for: self).map { item in
            let tone = switch item.tone { case .failure: "failure"; case .attention: "attention"; case .note: "note" }
            return "\(item.identifier):\(tone)\(item.isDismissible ? ":x" : "")"
        }
    }
}
