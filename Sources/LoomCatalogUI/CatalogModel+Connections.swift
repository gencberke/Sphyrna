import Foundation
import LoomCore

/// The model's door to the harness health (D-98): Settings → Connections and Home's "Connect your agents" read it. The app
/// builds one `HarnessHealthModel` next to the probe and the connect switch and installs it here.
extension CatalogModel {
    /// Hands the model its health object, once, at install.
    public func installHarnessHealth(_ health: HarnessHealthModel?) { harnessHealth = health }

    /// "Check Again" on Home: every connected harness, asked now whatever the floor says, and the CLIs looked for again (C2B).
    func recheckHarnesses() {
        harnessHealth?.checkAll(force: true)
        refreshHarnessAvailability(force: true)
    }

    /// Opens Settings on the Connections page.
    func showConnections() { onShowSettings?(.connections) }
}
