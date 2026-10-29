import CLoomPOSIX
import Darwin
import Foundation
import Synchronization

extension ProcessSupervisor {
    /// Every live process in every scope this supervisor holds, run hosts and
    /// launchd-started service instances included, for resource accounting.
    public func liveScopeMembers() throws -> [RunScopeMember] {
        try RunScopeTable.members(coalitionIDs: Array(liveScopes.keys)).values.joined()
            .filter { !$0.zombie }
    }

    /// Every live forked process in the run scope of the session's current
    /// run, across all runs sharing that scope (a Codex TUI and its server).
    /// Nil when runs are not scoped. Automatic idle must treat any of them as
    /// possible background work.
    public func scopeWork(sessionID: UUID) throws -> [ProcessRecord]? {
        guard let runID = sessions[sessionID]?.currentRun?.id else {
            throw SessionManagementError.sessionNotRunning(sessionID)
        }
        guard let scope = runtimes[runID]?.scope else { return nil }
        let forked = Set(try scope.forkedMembers().map(\.identity))
        return try ProcessTable.snapshot().filter { forked.contains($0.identity) && !$0.zombie }
    }

    @discardableResult
    public func sample(sessionID: UUID) throws -> [ProcessRecord] {
        guard let session = sessions[sessionID] else {
            throw SessionManagementError.sessionNotFound(sessionID)
        }
        guard let runID = session.currentRun?.id else {
            throw SessionManagementError.sessionNotRunning(sessionID)
        }
        return try sample(runID: runID)
    }

    func sample(runID: UUID) throws -> [ProcessRecord] {
        try sample(runID: runID, snapshot: ProcessTable.snapshot())
    }

    func sample(
        runID: UUID, snapshot: [ProcessRecord],
        markerReader: @Sendable (pid_t) -> String? = { ProcessTable.managedRunID(pid: $0) }
    ) throws -> [ProcessRecord] {
        try ownershipSamplingFailpoint?()
        guard var runtime = runtimes[runID] else {
            throw SessionManagementError.runNotFound(runID)
        }
        let byPID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.identity.pid, $0) })
        let live = Set(snapshot.map(\.identity))
        runtime.run.descendants.formIntersection(live)
        markerInspected.formIntersection(live)
        managedRunMarkers = managedRunMarkers.filter { live.contains($0.key) }

        var selected = runtime.run.descendants
        let leaderIsLive = live.contains(runtime.run.leader)
        let liveSessionMember = snapshot.contains {
            $0.sessionID == runtime.run.leader.pid && selected.contains($0.identity)
        }
        if leaderIsLive || liveSessionMember {
            selected.formUnion(snapshot.filter { $0.sessionID == runtime.run.leader.pid }.map(\.identity))
        }

        // A scope already supplies kernel-backed ownership. Do not inspect
        // unrelated processes' environments merely to find our marker.
        let markerScope = try runtime.scope.map { Set(try $0.forkedMembers().map(\.identity)) }
        var newMarkers: [ProcessIdentity: UUID] = [:]
        for record in snapshot where record.identity.pid != getpid()
            && !markerInspected.contains(record.identity)
            && (markerScope?.contains(record.identity) ?? true) {
            markerInspected.insert(record.identity)
            if let value = markerReader(record.identity.pid),
               let marker = UUID(uuidString: value) {
                newMarkers[record.identity] = marker
            }
        }
        // Environment lookup accepts a bare PID. Confirm the identity after the
        // lookup before allowing it to seed an ancestry walk.
        if !newMarkers.isEmpty {
            let confirmation = Set(try ProcessTable.snapshot().map(\.identity))
            newMarkers = newMarkers.filter { confirmation.contains($0.key) }
            managedRunMarkers.merge(newMarkers) { _, newest in newest }
        }
        selected.formUnion(managedRunMarkers.compactMap { $0.value == runID ? $0.key : nil })

        var changed = true
        while changed {
            changed = false
            for record in snapshot where !selected.contains(record.identity) {
                if let parent = byPID[record.parentPID], selected.contains(parent.identity) {
                    selected.insert(record.identity)
                    changed = true
                }
            }
        }
        if let scope = runtime.scope {
            // Session, markers and parent links only tell runs of one scope
            // apart. They never extend ownership: a debugger's tracee or a
            // marked process elsewhere is not in this coalition.
            let forked = Set(try scope.forkedMembers().map(\.identity))
            selected.formIntersection(forked)
            // The scope's last run owns everything forked inside it,
            // including detached work the other views cannot see.
            if scopeRuns[scope.coalitionID] == [runID] { selected.formUnion(forked.intersection(live)) }
        }

        runtime.run.descendants = selected
        runtime.outsideOwnership = snapshot.filter {
            selected.contains($0.identity) && $0.userID != getuid()
        }
        runtimes[runID] = runtime
        if var session = sessions[runtime.activeSessionID] {
            session.currentRun = runtime.run
            sessions[runtime.activeSessionID] = session
        }
        return snapshot.filter { selected.contains($0.identity) && $0.userID == getuid() }
    }

    @discardableResult
    func sampleOwnership() throws -> [ProcessRecord] {
        try ownershipSamplingFailpoint?()
        let snapshot = try ProcessTable.snapshot()
        let scoped = Set(try RunScopeTable.members(coalitionIDs: ledger.currentBootScopes().map(\.coalitionID))
            .values.joined().filter { !$0.launchdSpawned && !$0.zombie }.map(\.identity))
        if scopeLauncher != nil {
            // Loom signals only forked members of its own scopes.
            outsideScopes = snapshot.filter { scoped.contains($0.identity) && $0.userID != getuid() }
            return snapshot.filter { scoped.contains($0.identity) && $0.userID == getuid() }
        }
        // Narrowed mode (tests, probe): the legacy ledger, plus any scopes a
        // recovered app ledger recorded.
        let before = ledger
        var records = ledger.observe(snapshot)
        if ledger != before { try persistLedger() }
        let known = Set(records.map(\.identity))
        records += snapshot.filter {
            scoped.contains($0.identity) && !known.contains($0.identity) && $0.userID == getuid()
        }
        return records
    }

    var outsideOwnership: [ProcessRecord] {
        scopeLauncher != nil ? outsideScopes : (ledger.outsideOwnership ?? [])
    }

    var ownershipGuarantee: String {
        if scopeLauncher != nil {
            return "Run-scoped ownership: each run's resource coalition is stopped and verified empty; work handed to launchd or LaunchServices is outside it."
        }
        // Tests and the probe only: no run scopes, so detached unmarked work
        // that was never observed may survive.
        return ledger.observationIssue
            ?? "Narrowed ownership: session, observed ancestry and readable run markers only; unobserved unmarked escapes may remain."
    }
}
