import AppKit
import LoomCatalogUI
import LoomCore

/// The two hardening entry points the person sees: collecting diagnostics, and the question asked
/// when the catalog file is damaged. Both are thin; what they say and decide lives in `LoomCatalogUI`
/// (`DiagnosticsCollection`, `CatalogRecoveryPrompt`) and `LoomCore`.
extension AppDelegate {
    // MARK: Diagnostics

    /// One export writes `<data root>/diagnostics/exports/loom-diagnostics-<stamp>` and shows it in Finder.
    func makeDiagnosticsCollection() -> DiagnosticsCollection {
        DiagnosticsCollection(
            export: { [weak self] in
                guard let self, let runtime = self.runtime else { throw LoomError.message("Loom is not ready yet") }
                let facts = await self.usage?.diagnosticsSnapshot()
                return try await runtime.collectDiagnostics(
                    to: DiagnosticsExport.defaultFolder(dataRoot: runtime.catalog.dataRoot),
                    usage: facts?.usage, planLimitsFailure: facts?.planLimitsFailure)
            },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            failed: { title, detail in
                // Modal, not a sheet: the request may come from the Settings window, which has no sheet host here.
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = title
                alert.informativeText = detail
                alert.runModal()
            })
    }

    @objc func collectDiagnosticsFromMenu(_ sender: Any?) { diagnostics?.collect() }

    // MARK: Damaged catalog

    enum CatalogRecoveryOutcome {
        /// The catalog opened after a restore or a fresh start.
        case opened(SessionCatalog)
        /// No recovery was offered or it did not work: the usual catalog-error screen shows this text.
        case failed(String)
        case quit
    }

    /// Called when opening the catalog failed. A damaged file gets the alert (restore the newest backup
    /// when one exists, start fresh, or quit) before the window or any runtime exists; any other
    /// failure is returned unchanged with no restore offered.
    func offerCatalogRecovery(after error: any Error, catalogURL: URL) -> CatalogRecoveryOutcome {
        guard let catalogError = error as? SessionCatalogError, catalogError.isDamaged else {
            return .failed(String(describing: error))
        }
        LoomLog.error(.catalog, "The catalog is damaged; offering a restore (\(LoomLog.category(of: error)))")
        let prompt = CatalogRecoveryPrompt.make(backups: CatalogRecovery.backups(forCatalogAt: catalogURL))
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.title
        alert.informativeText = prompt.text
        for button in prompt.buttons { alert.addButton(withTitle: button.title) }
        NSApp.activate()
        let answer = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard prompt.buttons.indices.contains(answer) else { return .quit }
        do {
            switch prompt.buttons[answer].choice {
            case .quit: return .quit
            case let .restore(backup): try CatalogRecovery.restore(backup, intoCatalogAt: catalogURL)
            case .startFresh: try CatalogRecovery.startFresh(catalogAt: catalogURL)
            }
            return .opened(try SessionCatalog(url: catalogURL))
        } catch {
            LoomLog.error(.catalog, "Catalog recovery failed (\(LoomLog.category(of: error)))")
            return .failed(String(describing: error))
        }
    }
}
