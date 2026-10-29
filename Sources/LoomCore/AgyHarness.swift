import Foundation

/// AGY uses its own native terminal and passive hooks. It has no verified
/// task-input transport or transcript reader.
struct AgyHarness: Harness {
    var provider: ManagedSession.Provider { .agy }
    var takesOpeningOrDraft: Bool { true }
    var deletionRefusal: String? { "AGY's native session data cannot be deleted by Sphyrna yet" }

    func startTerminal(in runtime: isolated SessionRuntime, _ start: HarnessTerminalStart) async throws -> RuntimeLaunch {
        try await runtime.startAgy(start)
    }

    func resumeTerminal(in runtime: isolated SessionRuntime, _ resume: HarnessTerminalResume) async throws -> RuntimeLaunch {
        try await runtime.resumeAgy(resume)
    }

    func runEnded(runID: UUID, in runtime: isolated SessionRuntime) async { _ = await runtime.finishAgyRun(runID) }
    func noteToolchain(_ toolchain: ProviderToolchain, previous: ProviderToolchain?, in runtime: isolated SessionRuntime) {}
}
