import CLoomPOSIX
import Darwin
import Foundation
import Synchronization

extension ProcessSupervisor {
    /// Scopes without a live run at Quit: ones whose launch failed after the
    /// scope opened, and scopes recorded by a previous Loom in this boot. Their
    /// forked work was already stopped by the app-wide termination above.
    func releaseIdleScopes() async -> [String] {
        var errors: [String] = []
        for scope in liveScopes.values where (scopeRuns[scope.coalitionID] ?? []).isEmpty {
            errors += await releaseScope(scope)
        }
        let live = Set(liveScopes.keys)
        let boot = ProcessTable.bootSessionID()
        for record in ledger.scopes ?? [] where !live.contains(record.coalitionID) {
            if record.bootSessionID == boot {
                let deadline = ProcessInfo.processInfo.systemUptime + 10
                var members: [RunScopeMember] = []
                repeat {
                    do { members = try RunScopeTable.members(coalitionID: record.coalitionID).filter { !$0.zombie } }
                    catch { errors.append(String(describing: error)); break }
                    if members.isEmpty { break }
                    try? await Task.sleep(for: .milliseconds(20))
                } while ProcessInfo.processInfo.systemUptime < deadline
                guard members.isEmpty else {
                    errors.append("Recovered run scope \(record.coalitionID) is not empty: \(members.count) process(es)")
                    continue
                }
            }
            ledger.remove(scope: record)
        }
        do { try persistLedger() } catch { errors.append(String(describing: error)) }
        return errors
    }

    /// True when runs start in LaunchServices run scopes (the app); false in
    /// narrowed test supervisors, where `openScope` is unavailable.
    public nonisolated var runScopesEnabled: Bool { scopeLauncherConfigured }

    /// Opens a run scope and records it durably before anything is spawned in
    /// it. Codex uses one scope for its per-session server and TUI.
    public func openScope() async throws -> RunScope {
        guard !stopping else { throw SessionManagementError.shutdownStarted }
        guard let scopeLauncher else {
            throw RunScopeError.hostUnavailable("run scopes are not configured")
        }
        let scope = try await scopeLauncher.launch()
        liveScopes[scope.coalitionID] = scope
        ledger.register(scope: scope.record)
        do { try persistLedger() }
        catch {
            _ = await releaseScope(scope)
            throw error
        }
        return scope
    }

    /// Ends a scope with no remaining runs; see RunScope.release.
    public func releaseScope(_ scope: RunScope) async -> [String] {
        await releaseScope(scope, finishingRun: nil)
    }

    func releaseScope(_ scope: RunScope, finishingRun: UUID?) async -> [String] {
        let others = (scopeRuns[scope.coalitionID] ?? []).subtracting(finishingRun.map { [$0] } ?? [])
        guard others.isEmpty else {
            return ["Run scope \(scope.coalitionID) still has \(others.count) run(s)"]
        }
        releasingScopes.insert(scope.coalitionID)
        defer { releasingScopes.remove(scope.coalitionID) }
        let errors = await scope.release()
        guard errors.isEmpty else { return errors }
        liveScopes[scope.coalitionID] = nil
        scopeRuns[scope.coalitionID] = nil
        ledger.remove(scope: scope.record)
        do { try persistLedger() } catch { return [String(describing: error)] }
        return []
    }

    func spawnInScope(
        _ scope: RunScope, executable: String, arguments: [String],
        environment: [String: String], directory: String, rows: UInt16, columns: UInt16
    ) async throws -> PTYProcess {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard loom_open_pty(rows, columns, &master, &slave) == 0 else {
            throw LoomError.system("PTY open", errno)
        }
        defer { Darwin.close(slave) }
        do {
            let pid = try await scope.spawn(
                executable: executable, arguments: arguments, environment: environment,
                directory: directory, stdio: .terminal(slave: slave)
            )
            return PTYProcess(adoptingPID: pid, masterFD: master)
        } catch {
            Darwin.close(master)
            throw error
        }
    }

    /// A spawned leader that never became a run. Its scope is checked: a scope
    /// created for it is drained; a shared one loses only that process.
    func abandonUnregistered(_ process: PTYProcess, scope: RunScope?, ownsNewScope: Bool) async {
        guard let scope else {
            process.terminateUnregisteredChild()
            return
        }
        process.closeTerminal()
        if ownsNewScope {
            _ = loom_kill_scope_forked_members(scope.coalitionID, 0, 2)
            _ = await releaseScope(scope)
        } else if let member = RunScopeTable.lineage(pid: process.pid),
                  member.identity.pid == process.pid, !member.launchdSpawned {
            try? RunScopeTable.signal(member, coalitionID: scope.coalitionID, SIGKILL)
        }
    }
}
