import Foundation
import Testing
@testable import LoomCatalogUI

// The trait that keeps two tests from watching `SidebarRenderProbe` at once (RenderProbeExclusive.swift).

@MainActor
private final class Log {
    var entries: [String] = []
}

@Suite struct RenderProbeExclusiveTests {
    /// Two holders of the lock never run their bodies side by side, whoever asks first.
    @Test @MainActor func twoHoldersNeverOverlap() async throws {
        let log = Log()
        async let first: Void = RenderProbeLock.shared.exclusive {
            await log.add("a in"); try? await Task.sleep(for: .milliseconds(150)); await log.add("a out")
        }
        async let second: Void = RenderProbeLock.shared.exclusive {
            await log.add("b in"); try? await Task.sleep(for: .milliseconds(150)); await log.add("b out")
        }
        _ = try await (first, second)
        #expect(log.entries == ["a in", "a out", "b in", "b out"] || log.entries == ["b in", "b out", "a in", "a out"],
                "\(log.entries)")
    }

    @Test(.renderProbe) func aTestWithTheTraitHoldsTheLock() {
        #expect(RenderProbeExclusive.isHeld)
    }

    @Test func aTestWithoutItDoesNot() {
        #expect(!RenderProbeExclusive.isHeld)
    }
}

private extension Log {
    func add(_ entry: String) { entries.append(entry) }
}

/// Two suites that each watch the probe for a while: they run side by side unless the trait keeps them apart, and then
/// the second one's `watch` would replace what the first one counts.
@MainActor
private func watchesAloneFor(_ id: UUID) async throws {
    SidebarRenderProbe.watch([id])
    SidebarRenderProbe.card(id)
    try await Task.sleep(for: .milliseconds(400))
    #expect(SidebarRenderProbe.watched == [id], "another test replaced what this one watches")
    #expect(SidebarRenderProbe.cardBodies[id] == 1)
    SidebarRenderProbe.watch([])
}

@MainActor @Suite struct RenderProbeFirstWatcherTests {
    @Test(.renderProbe) func watchesAlone() async throws { try await watchesAloneFor(UUID()) }
}

@MainActor @Suite struct RenderProbeSecondWatcherTests {
    @Test(.renderProbe) func watchesAlone() async throws { try await watchesAloneFor(UUID()) }
}
