import LoomCore

extension UIPreferencesStore {
    /// The app's connect switches, restored and saved in Sphyrna's own preferences. The callback refreshes PATH readers
    /// after the choice is saved; it never writes a harness's profile or starts a CLI.
    public func makeHarnessConnections(onChange: (@MainActor @Sendable () -> Void)? = nil) -> HarnessConnections {
        HarnessConnections(choices: current.harnessChoices) { [weak self] id, connected in
            Task { @MainActor in
                try? self?.update { $0.setHarnessConnected(id, connected) }
                onChange?()
            }
        }
    }
}
