import Foundation

/// App-owned identity written before a managed provider can be spawned.
/// A verified stop refers to this exact scope and never to a later run.
struct ManagedTaskScopeBinding: Codable, Equatable, Sendable {
    let taskID: UUID
    let sessionID: UUID
    let runID: UUID
    let generation: UUID
    let ownerRunID: UUID
    let scope: RunScopeRecord
}
