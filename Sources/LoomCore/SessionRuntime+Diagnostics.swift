import Darwin
import Foundation

/// The runtime's part of hardening: what it records about itself (launch, Claude CLI, quit), what
/// it cleans up at start (a crash's sockets and open runs), the daily catalog backup and the
/// diagnostics export. Everything here is best effort: a failure is logged and journaled, and
/// never stops a start.
extension SessionRuntime {
    var journal: DiagnosticJournal { .forDataRoot(catalog.dataRoot) }

    // MARK: Journal

    func recordLaunch() {
        let info = Bundle.main.infoDictionary
        var fields: [String: JournalValue] = [
            "macOS": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "client": .string(configuration.clientVersion),
        ]
        if let version = info?["CFBundleShortVersionString"] as? String { fields["loomVersion"] = .string(version) }
        if let build = info?["CFBundleVersion"] as? String { fields["loomBuild"] = .string(build) }
        if let revision = info?["LoomRevision"] as? String { fields["loomRevision"] = .string(revision) }
        journal.record("launch", fields)
        let client = configuration.clientVersion
        LoomLog.notice(.lifecycle, "Runtime started (\(client))")
    }

    func recordQuit(_ report: ShutdownReport) {
        journal.record("quit", [
            "succeeded": .bool(report.succeeded),
            "elapsedSeconds": .double((report.elapsedSeconds * 100).rounded() / 100),
            "signals": .int(report.signals.count),
            "remaining": .int(report.remaining.count),
            "remainingCountVerified": .bool(report.remainingCountVerified ?? true),
            "errors": .int(report.errors.count),
            "outsideOwnership": .int(report.outsideOwnership.count),
        ])
        if report.succeeded {
            LoomLog.notice(.quit, "Quit verified in \(Int(report.elapsedSeconds * 1000)) ms (\(report.signals.count) signal(s))")
        } else {
            LoomLog.error(.quit, "Quit could not be verified: \(report.remaining.count) remaining, \(report.errors.count) error(s), \(report.outsideOwnership.count) outside ownership")
        }
    }

    /// The CLI this run launches with: its harness logs and journals it when it keeps such a record.
    func noteToolchain(_ toolchain: ProviderToolchain, previous: ProviderToolchain?) {
        harnesses[toolchain.provider]?.noteToolchain(toolchain, previous: previous, in: self)
    }

    /// A required option the CLI's help does not list: logged and journaled once per version and
    /// set of options; the start goes ahead (Claude's own error is what the user then sees).
    func reportCompatibility(
        toolchain: ProviderToolchain, route: ProviderLaunchProfile.ClaudeRoute,
        opening: ProviderLaunchProfile.ClaudeOpening?
    ) {
        let missing = ProviderLaunchProfile.missingRequiredClaudeOptions(
            capabilities: toolchain.capabilities, route: route, opening: opening)
        guard !missing.isEmpty else { return }
        let key = "\(toolchain.capabilities.version)|\(missing.joined(separator: ","))"
        guard reportedCompatibility.insert(key).inserted else { return }
        LoomLog.error(.toolchain, "Claude CLI \(toolchain.capabilities.version) does not list \(missing.joined(separator: ", ")) in its help; starting anyway")
        journal.record("cli_compat_warning", [
            "kind": "missing_required_option", "version": .string(toolchain.capabilities.version),
            "missing": .strings(missing),
        ])
    }

    // MARK: Crash residue

    /// Sockets a crashed Loom left in the socket directory; only those nothing listens on.
    func sweepStaleSockets() {
        let result = StaleSocketSweep.sweep(
            directory: configuration.socketDirectory, ownRunPrefix: String(supervisor.ownershipRunID.uuidString.prefix(8)))
        guard result.removed > 0 else { return }
        LoomLog.notice(.recovery, "Removed \(result.removed) stale socket(s) of an earlier run")
        journal.record("recovery_sockets", ["removed": .int(result.removed), "kept": .int(result.kept)])
    }

    /// Runs the catalog shows as open although their leader is gone (the app crashed or was
    /// force-quit before `finishRun`). Runs before any run of this process exists and before
    /// deletion recovery; a leader that still lives keeps its run open until a later launch.
    func closeAbandonedRuns() async {
        do {
            let closed = try await catalog.closeAbandonedRuns()
            if closed > 0 { journal.record("recovery_runs_closed", ["count": .int(closed)]) }
        } catch {
            LoomLog.error(.recovery, key: "close-runs", "Open runs of an earlier Loom could not be closed (\(LoomLog.category(of: error)))")
        }
        await configuration.runsRecovered?()
    }

    // MARK: Backup

    /// The daily backup, after a short delay so it never competes with the launch; `force` is the
    /// fresh one after a deletion finished. Off the main thread and off the catalog actor. None starts
    /// once shutdown has begun; the next launch's daily backup covers a deletion that ends during Quit.
    func scheduleCatalogBackup(force: Bool = false) {
        guard let delay = configuration.catalogBackupDelay, !shuttingDown else { return }
        let store = catalog.backupStore
        backupTask?.cancel()
        backupTask = Task.detached(priority: .utility) {
            if !force, delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            if force { await store.backUp() } else { await store.backUpIfDue() }
        }
    }

    // MARK: Export

    /// The facts the export carries, without writing anything. `usage` and `planLimitsFailure` come
    /// from the objects that hold them (`ClaudeUsageIndex.diagnostics()`, `ClaudePlanLimitsFetcher.lastFailure`).
    public func diagnosticsSummary(
        usage: UsageDiagnostics? = nil, planLimitsFailure: PlanLimitsFailure? = nil
    ) async -> DiagnosticsSummary {
        let info = Bundle.main.infoDictionary
        var claude: DiagnosticsSummary.ClaudeCLI?
        if let toolchain = cachedToolchain(for: .claude) {
            claude = .init(
                path: DiagnosticPaths.abbreviate(toolchain.executable), version: toolchain.capabilities.version,
                detectedOptions: toolchain.capabilities.detectedClaudeOptions,
                missingRequiredOptions: ProviderLaunchProfile.missingRequiredClaudeOptions(
                    capabilities: toolchain.capabilities, route: .new(UUID()), opening: nil))
        }
        return DiagnosticsSummary(
            generatedAt: Date(),
            application: .init(
                version: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                build: info?["CFBundleVersion"] as? String,
                revision: info?["LoomRevision"] as? String,
                macOS: ProcessInfo.processInfo.operatingSystemVersionString),
            claudeCLI: claude, catalog: try? await catalog.diagnosticsCounts(), usage: usage,
            planLimitsFailure: planLimitsFailure, hooks: HookDiagnostics.snapshot(), log: nil)
    }

    /// Writes the diagnostics folder at `folder` (`DiagnosticsExport.defaultFolder` names one under
    /// the data root) and returns it. No session content: ids, counts, versions, error categories.
    @discardableResult
    public func collectDiagnostics(
        to folder: URL, usage: UsageDiagnostics? = nil, planLimitsFailure: PlanLimitsFailure? = nil,
        log: DiagnosticsExport.LogRunner = DiagnosticsExport.systemLog
    ) async throws -> URL {
        let summary = await diagnosticsSummary(usage: usage, planLimitsFailure: planLimitsFailure)
        return try await DiagnosticsExport.collect(to: folder, dataRoot: catalog.dataRoot, summary: summary, log: log)
    }
}
