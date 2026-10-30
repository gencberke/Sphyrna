import Foundation
import Testing

// The one bounded wait of the tests (DEVELOPMENT §3.1): a test waits for a condition, never for time, and a wait that runs
// out names what it waited for and the last value it saw. The waits record their own issue, so a call site needs no
// `#expect` around them; they return whether the condition held, for a test that cannot go on without it. They run on the
// caller's actor (`#isolation`), so a condition may read what a main-actor test holds.

/// The longest a wait in a test lasts unless it says otherwise. A condition that needs longer names its reason at the call.
public let defaultWait: Duration = .seconds(10)

/// How often a wait looks again. Short enough that a test is not slowed by it, long enough that it never spins.
public let waitPoll: Duration = .milliseconds(10)

/// Waits until `condition` holds, for `within` at most. On a timeout it records "waited <s> s for <what>".
@discardableResult
public func waitFor(_ what: @autoclosure () -> String, within: Duration = defaultWait,
                    sourceLocation: SourceLocation = #_sourceLocation, isolation: isolated (any Actor)? = #isolation,
                    _ condition: () async throws -> Bool) async rethrows -> Bool {
    let clock = ContinuousClock()
    let start = clock.now
    while true {
        if try await condition() { return true }
        if clock.now - start >= within { break }
        try? await Task.sleep(for: waitPoll) // sleep: the poll between looks of a bounded wait
    }
    Issue.record("waited \(seconds(within)) s for \(what())", sourceLocation: sourceLocation)
    return false
}

/// Waits until `observe()`'s value satisfies `until`, for `within` at most, and returns the last value seen. On a timeout it
/// records "waited <s> s for <what>; last saw <value>".
@discardableResult
public func waitFor<Value>(_ what: @autoclosure () -> String, within: Duration = defaultWait,
                           sourceLocation: SourceLocation = #_sourceLocation, isolation: isolated (any Actor)? = #isolation,
                           observe: () async throws -> Value, until: (Value) -> Bool) async rethrows -> Value {
    let clock = ContinuousClock()
    let start = clock.now
    var value = try await observe()
    while !until(value) {
        if clock.now - start >= within {
            Issue.record("waited \(seconds(within)) s for \(what()); last saw \(value)", sourceLocation: sourceLocation)
            return value
        }
        try? await Task.sleep(for: waitPoll) // sleep: the poll between looks of a bounded wait
        value = try await observe()
    }
    return value
}

/// The negative window: `condition` must hold for all of `window`, looked at every `waitPoll`. The window is the test's
/// statement of how long "nothing happens" is watched; it records "<what> broke after <s> s" when it does not hold.
@discardableResult
public func holds(_ what: @autoclosure () -> String, for window: Duration,
                  sourceLocation: SourceLocation = #_sourceLocation, isolation: isolated (any Actor)? = #isolation,
                  _ condition: () async throws -> Bool) async rethrows -> Bool {
    let clock = ContinuousClock()
    let start = clock.now
    repeat {
        if try await !condition() {
            Issue.record("\(what()) broke after \(seconds(clock.now - start)) s of a \(seconds(window)) s window",
                         sourceLocation: sourceLocation)
            return false
        }
        try? await Task.sleep(for: waitPoll) // sleep: the poll between looks of a bounded wait
    } while clock.now - start < window
    return true
}

func seconds(_ duration: Duration) -> String {
    let (whole, attoseconds) = duration.components
    return String(format: "%.2f", Double(whole) + Double(attoseconds) / 1e18)
}
