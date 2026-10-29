import Foundation

/// Holds the thread that calls `hold()` until `release()`: a test freezes an actor in the middle of a step (a slow SQLite
/// transition of the catalog) to see what the rest of the product does meanwhile. Freezing the actor is the point, so this
/// is the one blocking wait a test may make on the cooperative pool (DEVELOPMENT §3.1): a suite that uses it is
/// `.serialized`, so it holds one pool thread at a time, and its release runs on another.
public final class ActorFreezeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var waiting = false
    private var released = false

    public init() {}

    /// The frozen step reached the gate.
    public var entered: Bool { condition.withLock { waiting } }

    public func hold() {
        condition.lock()
        waiting = true
        // actor freeze: the frozen step's own thread waits here until the test releases it
        while !released { condition.wait() }
        condition.unlock()
    }

    public func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
