import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// "Collect Diagnostics…" (H1 item 1): one export at a time, revealed on success, an alert with the
/// error category on failure.
@MainActor
struct DiagnosticsCollectionTests {
    private struct ExportFailure: Error {}

    /// An export the test finishes by hand.
    private final class Gate: @unchecked Sendable {
        var continuation: CheckedContinuation<URL, Error>?
        var starts = 0
    }

    @Test func itIsUnavailableUntilTheAppSaysTheRuntimeExists() {
        let collection = DiagnosticsCollection(export: { URL(fileURLWithPath: "/x") }, reveal: { _ in }, failed: { _, _ in })
        #expect(!collection.canCollect)
        collection.collect()
        #expect(!collection.isRunning)
        collection.isAvailable = true
        #expect(collection.canCollect)
    }

    @Test func onlyOneExportRunsAtATimeAndTheFinishedFolderIsRevealed() async {
        let gate = Gate()
        var revealed: [URL] = []
        let collection = DiagnosticsCollection(
            export: {
                gate.starts += 1
                return try await withCheckedThrowingContinuation { gate.continuation = $0 }
            },
            reveal: { revealed.append($0) }, failed: { _, _ in })
        collection.isAvailable = true
        collection.collect()
        while gate.continuation == nil { await Task.yield() }
        #expect(collection.isRunning && !collection.canCollect)
        collection.collect() // a second request while one runs does nothing
        #expect(gate.starts == 1)

        let folder = URL(fileURLWithPath: "/data/diagnostics/exports/loom-diagnostics-1")
        gate.continuation?.resume(returning: folder)
        await collection.settle()
        #expect(!collection.isRunning && collection.canCollect)
        #expect(revealed == [folder])
    }

    @Test func aFailureShowsOnlyTheErrorCategoryAndFreesTheNextExport() async {
        var alerts: [(String, String)] = []
        var revealed = 0
        let collection = DiagnosticsCollection(
            export: { throw LoomError.message("/Users/someone/secret path") },
            reveal: { _ in revealed += 1 }, failed: { alerts.append(($0, $1)) })
        collection.isAvailable = true
        collection.collect()
        await collection.settle()
        #expect(revealed == 0)
        #expect(!collection.isRunning && collection.canCollect)
        #expect(alerts.count == 1)
        #expect(alerts[0].0 == "Sphyrna could not collect diagnostics")
        #expect(alerts[0].1 == "The export failed (LoomError.message).")
        #expect(!alerts[0].1.contains("secret"))
    }
}
