import AppKit
import Foundation
@testable import LoomCore
import Testing

/// Lives in the AppKit-linked test target: `.modalPanel` is a common run-loop
/// mode only once AppKit has registered it, which LoomCoreTests cannot rely on.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct AppShutdownNestedLoopTests {
    /// Regression for the A-slice hang: AppKit waits for the quit reply in a
    /// nested run loop, possibly inside a main-queue block. The reply must
    /// still arrive there.
    @Test func quitReplyArrivesInsideMainQueueNestedRunLoop() async throws {
        // AppKit registers its modal-panel mode as a common mode on application setup.
        _ = NSApplication.shared
        let supervisor = try ProcessSupervisor()
        let coordinator = AppShutdownCoordinator(shutdown: { await supervisor.shutdown() })
        let delivered: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var replied = false
                    coordinator.requestQuit { _ in replied = true }
                    let deadline = Date().addingTimeInterval(5)
                    while !replied, Date() < deadline {
                        _ = RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05))
                    }
                    continuation.resume(returning: replied)
                }
            }
        }
        #expect(delivered)
        #expect(coordinator.state == .finished)
    }
}
