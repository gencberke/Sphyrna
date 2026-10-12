import CLoomPOSIX
import Darwin
import Foundation

/// Startup recovery for run directories left by a Loom that is no longer
/// running (crash, Force Quit). Normally each run host already stopped its own
/// scope when the connection dropped; this verifies that and stops any forked
/// work a host could not (for example, a host that died too). Launchd-spawned
/// members are never signaled. Nothing is started.
public enum PreviousRunRecovery {
    public struct Report: Sendable, Equatable {
        public var verifiedScopes = 0
        public var stoppedProcesses = 0
        public var removedDirectories = 0
        /// Run directories whose ledger could not be read, moved to `runs/quarantine/` after being
        /// reported here once (each also has a `leftovers` entry).
        public var quarantinedDirectories = 0
        /// One entry per scope that could not be shown empty; its directory is kept.
        public var leftovers: [String] = []
    }

    public static func recover(runsDirectory: URL, current: URL?,
                               scopeTimeout: TimeInterval = 10) async -> Report {
        let report = await Task.detached { recoverBlocking(runsDirectory: runsDirectory, current: current,
                                                           scopeTimeout: scopeTimeout) }.value
        record(report, dataRoot: runsDirectory.deletingLastPathComponent())
        return report
    }

    /// Where an unreadable run directory goes, under the runs directory.
    static let quarantineName = "quarantine"
    static let quarantineKeepCount = 10

    /// The ordinary relaunch (the previous run's directory removed, its scopes already empty) is
    /// not news. Anything that stopped work, left work or set a directory aside is.
    private static func record(_ report: Report, dataRoot: URL) {
        let eventful = report.stoppedProcesses > 0 || !report.leftovers.isEmpty || report.quarantinedDirectories > 0
        if eventful {
            LoomLog.error(.recovery, "Previous run recovery: \(report.stoppedProcesses) process(es) stopped, \(report.leftovers.count) leftover(s), \(report.quarantinedDirectories) directory(ies) set aside")
        } else {
            LoomLog.notice(.recovery, "Previous run recovery: \(report.verifiedScopes) scope(s) verified empty, \(report.removedDirectories) directory(ies) removed")
        }
        guard eventful else { return }
        DiagnosticJournal.forDataRoot(dataRoot).record("recovery", [
            "verifiedScopes": .int(report.verifiedScopes), "stoppedProcesses": .int(report.stoppedProcesses),
            "removedDirectories": .int(report.removedDirectories),
            "quarantinedDirectories": .int(report.quarantinedDirectories),
            "leftovers": .int(report.leftovers.count),
        ])
    }

    static func recoverBlocking(runsDirectory: URL, current: URL?, scopeTimeout: TimeInterval) -> Report {
        var report = Report()
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: runsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return report }
        let boot = ProcessTable.bootSessionID()
        let live = Set((try? ProcessTable.snapshot())?.map(\.identity) ?? [])
        for directory in entries where directory.standardizedFileURL != current?.standardizedFileURL
            && directory.lastPathComponent != quarantineName {
            let ownerURL = directory.appendingPathComponent("owner.json")
            let ledgerURL = directory.appendingPathComponent("ledger.json")
            if let data = try? Data(contentsOf: ownerURL),
               let owner = try? JSONDecoder().decode(ProcessIdentity.self, from: data),
               live.contains(owner) {
                continue // another live Loom owns it
            }
            guard fileManager.fileExists(atPath: ownerURL.path) || fileManager.fileExists(atPath: ledgerURL.path) else {
                continue // not a run directory
            }
            var clean = true
            var unreadableLedger = false
            if let ledger = try? OwnershipLedger.load(from: ledgerURL) {
                for scope in ledger.scopes ?? [] where scope.bootSessionID == boot {
                    switch drain(scope.coalitionID, timeout: scopeTimeout) {
                    case let .empty(stopped):
                        report.verifiedScopes += 1
                        report.stoppedProcesses += stopped
                    case let .notEmpty(detail):
                        clean = false
                        report.leftovers.append("Previous run scope \(scope.coalitionID): \(detail)")
                    }
                }
            } else if fileManager.fileExists(atPath: ledgerURL.path) {
                clean = false
                unreadableLedger = true
                report.leftovers.append("Previous run ledger \(directory.lastPathComponent) is unreadable")
            }
            if unreadableLedger {
                // Reported in this pass; kept for inspection, but out of the way so the next launch
                // does not report and rewrite it again.
                if quarantine(directory, under: runsDirectory) { report.quarantinedDirectories += 1 }
            } else if clean {
                if (try? fileManager.removeItem(at: directory)) != nil { report.removedDirectories += 1 }
            } else {
                try? Data(report.leftovers.joined(separator: "\n").utf8)
                    .write(to: directory.appendingPathComponent("recovery-error.txt"), options: .atomic)
            }
        }
        return report
    }

    /// Moves `directory` to `<runs>/quarantine/<name>` and keeps the newest few there.
    private static func quarantine(_ directory: URL, under runsDirectory: URL) -> Bool {
        let fileManager = FileManager.default
        let folder = runsDirectory.appendingPathComponent(quarantineName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            var target = folder.appendingPathComponent(directory.lastPathComponent)
            if fileManager.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(directory.lastPathComponent)-\(UUID().uuidString.prefix(6))")
            }
            try fileManager.moveItem(at: directory, to: target)
        } catch {
            LoomLog.error(.recovery, "A run directory with an unreadable ledger could not be set aside (\(LoomLog.category(of: error)))")
            return false
        }
        let kept = ((try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        for stale in kept.dropFirst(quarantineKeepCount) { try? fileManager.removeItem(at: stale) }
        return true
    }

    private enum Drain { case empty(stopped: Int), notEmpty(String) }

    private static func drain(_ coalition: UInt64, timeout: TimeInterval) -> Drain {
        let before: [RunScopeMember]
        do { before = try RunScopeTable.members(coalitionID: coalition).filter { !$0.zombie } }
        catch { return .notEmpty(String(describing: error)) }
        let forked = before.filter { !$0.launchdSpawned }.count
        if forked > 0, loom_kill_scope_forked_members(coalition, 0, timeout) != 0 {
            return .notEmpty("forked work could not be stopped")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            guard let members = try? RunScopeTable.members(coalitionID: coalition).filter({ !$0.zombie }) else {
                return .notEmpty("membership is unreadable")
            }
            if members.isEmpty { return .empty(stopped: forked) }
            usleep(50_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return .notEmpty("launchd-started members did not exit")
    }
}
