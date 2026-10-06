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
        /// One entry per scope that could not be shown empty; its directory is kept.
        public var leftovers: [String] = []
    }

    public static func recover(runsDirectory: URL, current: URL?,
                               scopeTimeout: TimeInterval = 10) async -> Report {
        await Task.detached { recoverBlocking(runsDirectory: runsDirectory, current: current,
                                              scopeTimeout: scopeTimeout) }.value
    }

    static func recoverBlocking(runsDirectory: URL, current: URL?, scopeTimeout: TimeInterval) -> Report {
        var report = Report()
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: runsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return report }
        let boot = ProcessTable.bootSessionID()
        let live = Set((try? ProcessTable.snapshot())?.map(\.identity) ?? [])
        for directory in entries where directory.standardizedFileURL != current?.standardizedFileURL {
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
                report.leftovers.append("Previous run ledger \(directory.lastPathComponent) is unreadable")
            }
            if clean {
                if (try? fileManager.removeItem(at: directory)) != nil { report.removedDirectories += 1 }
            } else {
                try? Data(report.leftovers.joined(separator: "\n").utf8)
                    .write(to: directory.appendingPathComponent("recovery-error.txt"), options: .atomic)
            }
        }
        return report
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
