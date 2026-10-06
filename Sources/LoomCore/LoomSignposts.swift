import Foundation
import os

/// Points-of-interest signposts for launch and sidebar latency. Cost when nothing
/// listens is a few atomic operations per call. They carry no user data (names
/// only). Read them without Instruments:
///
///     /usr/bin/log show --last 2m --signpost --predicate 'subsystem == "local.loom.desktop"' --style compact
///
/// or record the same intervals with `xctrace record --instrument os_signpost`.
/// `begin(_:)` and `end(_:)` pair by name; an `end` without a `begin` (for example
/// in tests) does nothing, and a second `begin` before the `end` ends the first one.
public enum LoomSignposts {
    public static let subsystem = "local.loom.desktop"
    public static let category = "PointsOfInterest"
    public static let signposter = OSSignposter(subsystem: subsystem, category: category)

    /// The named intervals, in launch order.
    public enum Interval: String, CaseIterable, Sendable {
        /// App delegate created until the first page of the sidebar is loaded.
        case launchToFirstPage = "LaunchToFirstPage"
        /// Opening the catalog database (includes `PRAGMA quick_check`).
        case catalogOpen = "CatalogOpen"
        /// App delegate created until the window is on screen.
        case windowShown = "WindowShown"
        /// Runtime construction: supervisor restore, run files, runtime and lifecycle start.
        case runtimeStart = "RuntimeStart"
        /// `CatalogModel.start()`: projects, counts, first pages, selection.
        case firstPage = "FirstPage"
        /// A conversation was selected until its terminal view is available to the detail pane.
        case selectToTerminal = "SelectToTerminal"
    }

    private static let open = OSAllocatedUnfairLock(initialState: [Interval: OSSignpostIntervalState]())

    public static func begin(_ interval: Interval) {
        // `beginInterval` needs a static name, hence the switch.
        let state: OSSignpostIntervalState
        switch interval {
        case .launchToFirstPage: state = signposter.beginInterval("LaunchToFirstPage")
        case .catalogOpen: state = signposter.beginInterval("CatalogOpen")
        case .windowShown: state = signposter.beginInterval("WindowShown")
        case .runtimeStart: state = signposter.beginInterval("RuntimeStart")
        case .firstPage: state = signposter.beginInterval("FirstPage")
        case .selectToTerminal: state = signposter.beginInterval("SelectToTerminal")
        }
        // A repeated begin replaces the earlier interval, which ends as abandoned.
        if let abandoned = open.withLock({ $0.updateValue(state, forKey: interval) }) { endNow(interval, abandoned) }
    }

    public static func end(_ interval: Interval) {
        guard let state = open.withLock({ $0.removeValue(forKey: interval) }) else { return }
        endNow(interval, state)
    }

    private static func endNow(_ interval: Interval, _ state: OSSignpostIntervalState) {
        switch interval {
        case .launchToFirstPage: signposter.endInterval("LaunchToFirstPage", state)
        case .catalogOpen: signposter.endInterval("CatalogOpen", state)
        case .windowShown: signposter.endInterval("WindowShown", state)
        case .runtimeStart: signposter.endInterval("RuntimeStart", state)
        case .firstPage: signposter.endInterval("FirstPage", state)
        case .selectToTerminal: signposter.endInterval("SelectToTerminal", state)
        }
    }

    /// Runs `body` inside the named interval.
    public static func measure<T>(_ interval: Interval, _ body: () throws -> T) rethrows -> T {
        begin(interval)
        defer { end(interval) }
        return try body()
    }
}
