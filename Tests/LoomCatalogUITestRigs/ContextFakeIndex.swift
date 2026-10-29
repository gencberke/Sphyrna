import AppKit
import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport

/// An index that answers context lookups from a table and counts them; its scans do nothing.
final class ContextFakeIndex: UsageIndexing, @unchecked Sendable {
    struct State {
        var samples: [String: SessionContextSample] = [:]
        var lookups: [[String]] = []
        var refreshes = 0
    }
    let state = Mutex(State())
    var lookups: [[String]] { state.withLock { $0.lookups } }
    var refreshes: Int { state.withLock { $0.refreshes } }
    func set(_ samples: [String: SessionContextSample]) { state.withLock { $0.samples = samples } }

    func refreshAll() async throws -> UsageScanReport {
        state.withLock { $0.refreshes += 1 }
        return UsageScanReport()
    }

    func snapshot(range: UsageRange, now: Date, timeZone: TimeZone) async throws -> UsageSnapshot {
        UsageSnapshotFactory.snapshot(range: range, now: now)
    }

    func latestMainMessages(sessions: [String]) async throws -> [String: SessionContextSample] {
        state.withLock { state in
            state.lookups.append(sessions)
            return state.samples.filter { sessions.contains($0.key) }
        }
    }
}
