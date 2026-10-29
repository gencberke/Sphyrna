import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// The two events the catalog model forwards to usage: the first load finishing and a finished turn.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct UsageHooksTests {
    @Test func firstCatalogLoadStartsOneScanAndAFinishedTurnQueuesAnother() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-usage-hooks-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = SessionEventHub()
        let model = CatalogModel(
            catalog: try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3")), events: hub,
            preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        let index = FakeUsageIndex()
        let usage = UsageModel(index: index, debounce: .milliseconds(30))
        model.usage = usage
        #expect(index.refreshCalls == 0) // nothing is read before the catalog's first load finishes
        await model.start()
        await usage.settle()
        #expect(index.refreshCalls == 1)
        await model.stopAndWait() // the test feeds frames itself

        let stream = await hub.subscribe()
        var iterator = stream.makeAsyncIterator()
        model.apply(try #require(await iterator.next())) // the initial snapshot is not a turn
        await usage.settle()
        #expect(index.refreshCalls == 1)
        await hub.publish(sessionID: UUID(), change: .status(ProviderWorkState(activity: .turnComplete)))
        model.apply(try #require(await iterator.next()))
        await usage.settle()
        #expect(index.refreshCalls == 2)
    }

    @Test func aTurnThatFinishedInASkippedFrameStillRefreshes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-usage-hooks-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = SessionEventHub()
        let model = CatalogModel(
            catalog: try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3")), events: hub,
            preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        let index = FakeUsageIndex()
        let usage = UsageModel(index: index, debounce: .milliseconds(30))
        model.usage = usage
        await model.start()
        await usage.settle()
        await model.stopAndWait() // the test feeds frames itself
        let stream = await hub.subscribe()
        var iterator = stream.makeAsyncIterator()
        model.apply(try #require(await iterator.next()))
        let calls = index.refreshCalls
        // The turn finishes, then other changes follow before the consumer takes a frame: the
        // consumer only ever sees the newest one, and its turn count has still moved.
        let session = UUID()
        await hub.publish(sessionID: session, change: .status(ProviderWorkState(activity: .turnComplete)))
        await hub.publish(sessionID: UUID(), change: .status(ProviderWorkState(activity: .working)))
        let newest = try #require(await iterator.next())
        #expect(newest.change != .status(ProviderWorkState(activity: .turnComplete)))
        model.apply(newest)
        await usage.settle()
        #expect(index.refreshCalls == calls + 1)
    }
}
