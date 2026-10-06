import Foundation
import SQLite3
import Testing
@testable import LoomCore

private final class ScaleBundleAnchor: NSObject {}

/// CP5 B5: state updates must not rescan the catalog, and the query, restore
/// and event-map costs at 1,000 and 10,000 history rows are reported. These
/// are short in-process measurements, not the deferred terminal/GPU acceptance.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct CatalogScaleTests {
    private func seed(_ catalog: SessionCatalog, count: Int) async throws {
        for index in 0..<count {
            try await catalog.insertSession(
                ManagedSession(provider: index % 2 == 0 ? .claude : .codex, workingDirectory: "/tmp"),
                title: "History \(index)", createdAt: Date(timeIntervalSince1970: Double(index)),
                // Recent, so no idle/stale deadline is due while the test runs.
                lastUsedAt: Date().addingTimeInterval(-3_600 - Double(index)), lifecycle: .idle
            )
        }
    }

    private func median(_ durations: [Duration]) -> Duration {
        durations.sorted()[durations.count / 2]
    }

    private func microseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12
    }

    @Test(arguments: [1_000, 10_000])
    func queryRestoreAndEventCostsAtScale(count: Int) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-scale-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        try await seed(catalog, count: count)
        let clock = ContinuousClock()

        var pageTimes: [Duration] = [], searchTimes: [Duration] = []
        for _ in 0..<15 {
            pageTimes.append(try await clock.measure { _ = try await catalog.sessionPage(CatalogQuery()) })
            searchTimes.append(try await clock.measure {
                _ = try await catalog.sessionPage(CatalogQuery(search: "codex history 9"))
            })
        }
        print("B5 count=\(count) firstPage median=\(microseconds(median(pageTimes))) us "
              + "search median=\(microseconds(median(searchTimes))) us")
        #expect(median(pageTimes) < .milliseconds(300))

        var supervisor: ProcessSupervisor?
        let restoreTime = try await clock.measure {
            supervisor = try await ProcessSupervisor.restoring(
                ledger: OwnershipLedger(), catalog: catalog
            )
        }
        let restored = try #require(supervisor)
        print("B5 count=\(count) supervisor restore (one full read) = \(microseconds(restoreTime) / 1000) ms")

        // History is not copied into the event map: it stays proportional to live activity.
        #expect(await restored.events.snapshot().sessions.isEmpty)

        // Event path with a consumer that holds the newest frame (worst case
        // for the copy-on-write event map): cost per published change.
        let stream = await restored.events.subscribe()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let target = try #require(try await catalog.sessionPage(CatalogQuery()).sessions.first?.session.id)
        let events = 500
        let publishTime = try await clock.measure {
            for index in 0..<events {
                await restored.events.publish(
                    sessionID: target,
                    change: .status(ProviderWorkState(activity: index % 2 == 0 ? .working : .turnComplete))
                )
                if index % 50 == 0 { _ = await iterator.next() }
            }
        }
        print("B5 count=\(count) event publish = \(microseconds(publishTime) / Double(events)) us per change "
              + "(\(await restored.events.snapshot().sessions.count) live states in the map)")

        // A status change reads no catalog rows: only running conversations
        // (none here) and the oldest idle timestamp are consulted.
        let controller = SessionLifecycleController(supervisor: restored, catalog: catalog)
        try await controller.startAutomaticEvaluation()
        let before = await catalog.decodedSessionRows
        for index in 0..<100 {
            await restored.events.publish(
                sessionID: target,
                change: .status(ProviderWorkState(activity: index % 2 == 0 ? .working : .turnComplete))
            )
        }
        try await Task.sleep(for: .milliseconds(500))
        let after = await catalog.decodedSessionRows
        print("B5 count=\(count) catalog rows decoded by 100 status events = \(after - before)")
        #expect(after - before <= 100)
        await controller.stopAutomaticEvaluation()
        #expect((await restored.shutdown()).succeeded)
    }

    @Test func statusEventsWithOneRunningConversationDecodeOnlyThatRow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-scale-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        try await seed(catalog, count: 2_000)
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger(), catalog: catalog
        )
        let sessionID = UUID()
        try await supervisor.createSession(ManagedSession(
            id: sessionID, provider: .synthetic,
            workingDirectory: FileManager.default.temporaryDirectory.path
        ))
        let child = Bundle(for: ScaleBundleAnchor.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("loom-test-child").path
        _ = try await supervisor.launch(
            sessionID: sessionID, executable: child, arguments: ["interactive"],
            environment: LaunchEnvironment.make(
                path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: sessionID
            )
        )
        let controller = SessionLifecycleController(supervisor: supervisor, catalog: catalog)
        try await controller.startAutomaticEvaluation()
        let before = await catalog.decodedSessionRows
        let events = 40
        for index in 0..<events {
            await supervisor.events.publish(
                sessionID: sessionID,
                change: .status(ProviderWorkState(activity: index % 2 == 0 ? .working : .turnComplete))
            )
        }
        try await Task.sleep(for: .milliseconds(500))
        let decoded = await catalog.decodedSessionRows - before
        print("B5 2,000 rows + 1 running: rows decoded by \(events) events = \(decoded)")
        // The old path decoded every row (2,001) per event.
        #expect(decoded <= events)
        await controller.stopAutomaticEvaluation()
        #expect((await supervisor.shutdown()).succeeded)
    }

    /// F5 probe: what opening an existing catalog costs on the launch path
    /// (`SessionCatalog(url:)`, which runs `PRAGMA quick_check` before anything
    /// else) and what `quick_check` alone costs, at 1,000 and 10,000 rows.
    @Test(arguments: [1_000, 10_000])
    func catalogOpenAndQuickCheckCostAtScale(count: Int) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-open-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        do {
            let seeded = try SessionCatalog(url: url)
            try await seed(seeded, count: count)
        }
        let clock = ContinuousClock()
        var opens: [Duration] = [], checks: [Duration] = []
        for _ in 0..<7 {
            opens.append(try clock.measure { _ = try SessionCatalog(url: url) })
            checks.append(try clock.measure {
                var handle: OpaquePointer?
                guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                    throw SessionCatalogError.sqlite(operation: "probe open", code: SQLITE_CANTOPEN, message: "")
                }
                defer { sqlite3_close(handle) }
                var statement: OpaquePointer?
                sqlite3_prepare_v2(handle, "PRAGMA quick_check", -1, &statement, nil)
                defer { sqlite3_finalize(statement) }
                while sqlite3_step(statement) == SQLITE_ROW {}
            })
        }
        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("F5 count=\(count) db=\(fileBytes / 1024) KiB SessionCatalog(url:) median=\(microseconds(median(opens)) / 1000) ms "
              + "(min \(microseconds(opens.sorted().first!) / 1000), max \(microseconds(opens.sorted().last!) / 1000)) "
              + "| quick_check alone median=\(microseconds(median(checks)) / 1000) ms "
              + "(min \(microseconds(checks.sorted().first!) / 1000), max \(microseconds(checks.sorted().last!) / 1000))")
        #expect(median(opens) < .seconds(5))
    }

    // MARK: CP5 C precondition (history §28.1): aging must not fill the event map

    private func seedAged(_ catalog: SessionCatalog, count: Int) async throws {
        for index in 0..<count {
            try await catalog.insertSession(
                ManagedSession(provider: index % 2 == 0 ? .claude : .codex, workingDirectory: "/tmp"),
                title: "Aged \(index)", createdAt: Date(timeIntervalSince1970: Double(index)),
                lastUsedAt: Date().addingTimeInterval(-20 * 86_400 - Double(index)), lifecycle: .idle
            )
        }
    }

    /// The real `classifyStale` path with a consumer holding the newest frame,
    /// then 1,000 status events. 1 warm-up + 5 measured repeats, fresh catalog each.
    @Test(arguments: [1_000, 10_000])
    func agingHistoryDoesNotGrowTheEventMap(count: Int) async throws {
        var bulk: [Duration] = [], next: [Duration] = []
        var mapAfterBulk = 0, mapAfterEvents = 0
        for repeatIndex in 0..<6 {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("loom-aging-\(UUID())", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
            try await seedAged(catalog, count: count)
            let supervisor = try await ProcessSupervisor.restoring(
                ledger: OwnershipLedger(), catalog: catalog
            )
            let controller = SessionLifecycleController(supervisor: supervisor, catalog: catalog)
            let stream = await supervisor.events.subscribe()
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            let clock = ContinuousClock()

            var changed: [UUID] = []
            let bulkTime = try await clock.measure { changed = try await controller.classifyStale() }
            #expect(changed.count == count)
            mapAfterBulk = await supervisor.events.snapshot().sessions.count
            // A consumer that was busy still recovers from the latest frame.
            let latest = try #require(await iterator.next())
            #expect(latest.catalogRevision == 1)

            let target = try #require(changed.first)
            let events = 1_000
            let eventTime = try await clock.measure {
                for index in 0..<events {
                    await supervisor.events.publish(
                        sessionID: target,
                        change: .status(ProviderWorkState(activity: index % 2 == 0 ? .working : .turnComplete))
                    )
                    if index % 50 == 0 { _ = await iterator.next() }
                }
            }
            mapAfterEvents = await supervisor.events.snapshot().sessions.count
            if repeatIndex > 0 { bulk.append(bulkTime); next.append(eventTime / events) }

            // The catalog, not the event map, carries the stale history.
            let page = try await catalog.sessionPage(CatalogQuery())
            #expect(page.sessions.allSatisfy { $0.lifecycle == .stale })
            #expect((await supervisor.shutdown()).succeeded)
        }
        // Control: the same event loop against a hub with one live conversation
        // and no history at all (the cost the aged case should return to).
        var control: [Duration] = []
        for _ in 0..<5 {
            let hub = SessionEventHub()
            let stream = await hub.subscribe()
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            let target = UUID()
            let time = await ContinuousClock().measure {
                for index in 0..<1_000 {
                    await hub.publish(
                        sessionID: target,
                        change: .status(ProviderWorkState(activity: index % 2 == 0 ? .working : .turnComplete))
                    )
                    if index % 50 == 0 { _ = await iterator.next() }
                }
            }
            control.append(time / 1_000)
        }
        let sortedBulk = bulk.sorted(), sortedNext = next.sorted()
        print("C0 count=\(count) bulk classifyStale median=\(microseconds(median(bulk)) / 1000) ms "
              + "(min \(microseconds(sortedBulk.first!) / 1000), max \(microseconds(sortedBulk.last!) / 1000)) "
              + "| next event median=\(microseconds(median(next))) us "
              + "(min \(microseconds(sortedNext.first!)), max \(microseconds(sortedNext.last!))) "
              + "| map after bulk=\(mapAfterBulk), after 1,000 events=\(mapAfterEvents) "
              + "| control (1 live, no history) event median=\(microseconds(median(control))) us")
        #expect(mapAfterBulk == 0)
        #expect(mapAfterEvents == 1)
    }

    /// A conversation that already has live facts keeps them through the batch;
    /// only its lifecycle follows the catalog.
    @Test func bulkStaleKeepsExistingLiveFactsAndSkipsHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-aging-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        try await seedAged(catalog, count: 50)
        let supervisor = try await ProcessSupervisor.restoring(
            ledger: OwnershipLedger(), catalog: catalog
        )
        let controller = SessionLifecycleController(supervisor: supervisor, catalog: catalog)
        let watched = try #require(try await catalog.sessionPage(CatalogQuery()).sessions.first?.session.id)
        let hub = supervisor.events
        await hub.publish(sessionID: watched, change: .stopFailure("stop not verified"))
        await hub.publish(sessionID: watched, change: .status(ProviderWorkState(activity: .turnComplete)))
        let before = await hub.snapshot().sessions[watched]
        #expect(before?.unviewedCompletion == true)

        _ = try await controller.classifyStale()
        let after = await hub.snapshot()
        #expect(after.sessions.count == 1)
        #expect(after.sessions[watched]?.lifecycle == .stale)
        #expect(after.sessions[watched]?.stopFailure == "stop not verified")
        #expect(after.sessions[watched]?.unviewedCompletion == true)
        #expect(after.sessions[watched]?.status?.activity == .turnComplete)
        #expect((await supervisor.shutdown()).succeeded)
    }
}
