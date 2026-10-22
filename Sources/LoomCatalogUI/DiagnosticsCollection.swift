import Foundation
import LoomCore
import Observation

/// "Collect Diagnostics…" (the Help menu and Settings → About): one export at a time. The app supplies
/// what an export does and how its result is shown; this keeps the single-flight rule and the failure
/// text, so the menu item and the button agree on when they are usable.
@MainActor @Observable
public final class DiagnosticsCollection {
    /// An export is being written.
    public private(set) var isRunning = false
    /// Set by the app once the runtime exists; before that there is nothing to export from.
    public var isAvailable = false

    @ObservationIgnored private let export: @MainActor () async throws -> URL
    @ObservationIgnored private let reveal: @MainActor (URL) -> Void
    @ObservationIgnored private let failed: @MainActor (_ title: String, _ detail: String) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - export: writes the folder and returns it.
    ///   - reveal: shows the finished folder (Finder, selected).
    ///   - failed: shows the failure alert.
    public init(
        export: @escaping @MainActor () async throws -> URL,
        reveal: @escaping @MainActor (URL) -> Void,
        failed: @escaping @MainActor (_ title: String, _ detail: String) -> Void
    ) {
        self.export = export
        self.reveal = reveal
        self.failed = failed
    }

    public var canCollect: Bool { isAvailable && !isRunning }

    /// Starts an export unless one is running (or none is possible yet).
    public func collect() {
        guard canCollect else { return }
        isRunning = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                reveal(try await export())
            } catch {
                let text = Self.failureText(category: LoomLog.category(of: error))
                failed(text.title, text.detail)
            }
            isRunning = false
            task = nil
        }
    }

    /// Waits for a running export (tests).
    public func settle() async { await task?.value }

    /// The alert for a failed export: the error's category only, never a path or session content.
    nonisolated static func failureText(category: String) -> (title: String, detail: String) {
        ("Sphyrna could not collect diagnostics", "The export failed (\(category)).")
    }
}
