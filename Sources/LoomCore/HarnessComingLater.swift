import Foundation

/// The "Coming later" state of a harness (D-120): the label every list shows, and the reason every refused start gives.
extension HarnessDescriptor {
    /// The badge text beside a harness that is coming later.
    public static let comingLaterLabel = "Coming later"

    /// Why a start of this harness is refused, nil when it is not coming later.
    public var comingLaterReason: String? {
        comingLater ? "\(displayName) is coming later: this version of Sphyrna cannot start its sessions" : nil
    }
}

extension HarnessCatalogue {
    /// Why `id` cannot start or resume in this version, nil when nothing holds it back for later.
    public static func comingLaterReason(for id: HarnessID) -> String? {
        descriptor(for: id)?.comingLaterReason
    }

    /// Whether `id` is coming later.
    public static func isComingLater(_ id: HarnessID) -> Bool {
        descriptor(for: id)?.comingLater ?? false
    }
}
