import Foundation
import LoomCore
import ObjectiveC

/// The model's door to the harness health (D-98): Settings → Connections and Home's "Connect your agents" read it. The app
/// builds one `HarnessHealthModel` next to the probe and the connect switch and installs it here.
///
/// The model object is kept as an associated object because this file may not add a stored property to `CatalogModel`; it lives
/// and dies with the catalog model, and is nil in a build with no app around it (no health, no cards, no Connections page).
extension CatalogModel {
    private enum HealthKey { nonisolated(unsafe) static var key = 0 }

    public var harnessHealth: HarnessHealthModel? {
        objc_getAssociatedObject(self, &HealthKey.key) as? HarnessHealthModel
    }

    /// Hands the model its health object, once, at install.
    public func installHarnessHealth(_ health: HarnessHealthModel?) {
        objc_setAssociatedObject(self, &HealthKey.key, health, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// "Check Again" on Home: every connected harness, asked now whatever the floor says.
    func recheckHarnesses() { harnessHealth?.checkAll(force: true) }

    /// Opens Settings on the Connections page.
    func showConnections() { onShowSettings?(.connections) }
}
