import Foundation

/// The writes a user makes to a session's own record: its title and its pin. They are catalog writes with nothing to start
/// or stop, so they are a value over the catalog; `SessionService` holds one (`records`) and is the UI's door to it. A model
/// built with no service (a test, a window with no runtime) reads the same writes over its own catalog.
public struct SessionRecordWrites: Sendable {
    private let catalog: SessionCatalog

    public init(catalog: SessionCatalog) { self.catalog = catalog }

    /// Saves the title the user typed (an empty one returns the session to automatic titles). Throws when it was not saved.
    public func rename(sessionID: UUID, to title: String) async throws {
        try await catalog.renameSession(sessionID: sessionID, to: title)
    }

    /// Pins the session (a retention exception: a pinned session is never listed for cleanup) or unpins it.
    public func setPinned(sessionID: UUID, _ pinned: Bool) async throws {
        try await catalog.setPinned(pinned, for: sessionID)
    }
}
