import AppKit
import SwiftUI
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

extension InspectorRig {
    /// The rig with the real `DetailView` hosted in its window and the window ordered in. Only the window tests show a
    /// window (DEVELOPMENT §3.1); the rig itself stays offscreen.
    @MainActor
    static func make(sessions: Int = 2, hosted: Bool) async throws -> InspectorRig {
        let rig = try await make(sessions: sessions)
        if hosted {
            let host = NSHostingView(rootView: DetailView(model: rig.model))
            host.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
            rig.window.contentView = host
            rig.window.orderFrontRegardless()
        }
        return rig
    }
}
