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

    /// One row for every catalogue harness, combining the PATH result and the shared switch with provider health.
    var connectionRows: [ConnectionsContent.HarnessRow] {
        guard let health = harnessHealth else { return [] }
        return HarnessCatalogue.all.map { descriptor in
            let provider = descriptor.provider
            let buildSupportsSessions = provider.map { HarnessCapabilities.of($0, startable: startableProviders).startable } ?? false
            return ConnectionsContent.harnessRow(
                descriptor: descriptor, availability: harnessAvailability.map { $0[descriptor.id] ?? HarnessAvailability(id: descriptor.id, state: .notFound) },
                switchedOn: health.connections.isOn(descriptor.id), health: provider.map { health.health(of: $0) },
                buildSupportsSessions: buildSupportsSessions, canStart: provider.map { capabilities(of: $0).startable } ?? false)
        }
    }

    /// The missing switch never changes a stored choice. Found switches persist through the app's shared connections.
    func setHarnessConnected(_ id: HarnessID, _ on: Bool) {
        guard let row = connectionRows.first(where: { $0.id == id }), row.canSwitch, let health = harnessHealth else { return }
        if let provider = row.descriptor.provider {
            health.setConnected(provider, on)
        } else {
            health.connections.setOn(id, on)
        }
    }

    /// Rechecks provider health where supported and always repeats the PATH lookup.
    func recheckHarness(_ id: HarnessID) {
        if let provider = HarnessCatalogue.descriptor(for: id)?.provider { harnessHealth?.checkAgain(provider) }
        refreshHarnessAvailability(force: true)
    }
}
