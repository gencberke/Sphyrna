import Darwin
import Foundation

public struct OwnershipLedger: Codable, Equatable, Sendable {
    public let runID: UUID
    public private(set) var observationIssue: String?
    public private(set) var outsideOwnership: [ProcessRecord]? = []
    public private(set) var sessionLeaders: Set<ProcessIdentity> = []
    public private(set) var descendants: Set<ProcessIdentity> = []
    /// Run scopes recorded before any process was spawned into them, so a
    /// later launch can verify and clean them within the same boot.
    public private(set) var scopes: [RunScopeRecord]? = []
    /// Managed-task scope identities, recorded before their provider spawn.
    /// The matching durable stop receipt must exist before a scope is removed.
    private(set) var managedTaskScopes: [ManagedTaskScopeBinding]? = []

    private struct Metadata: Sendable {
        let matchesRunID: Bool
    }
    // Runtime-only: recovery must classify the current process table afresh.
    private var metadataCache: [ProcessIdentity: Metadata] = [:]

    private enum CodingKeys: String, CodingKey {
        case runID, observationIssue, outsideOwnership, sessionLeaders, descendants, scopes, managedTaskScopes
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.runID == rhs.runID
            && lhs.observationIssue == rhs.observationIssue && lhs.outsideOwnership == rhs.outsideOwnership
            && lhs.sessionLeaders == rhs.sessionLeaders && lhs.descendants == rhs.descendants
            && lhs.scopes == rhs.scopes && (lhs.managedTaskScopes ?? []) == (rhs.managedTaskScopes ?? [])
    }

    /// The app's own coalition is never an ownership seed (Apple service
    /// instances join it later); older ledgers' coalition field is ignored.
    public init(runID: UUID = UUID()) {
        self.runID = runID
    }

    public mutating func register(_ leader: ProcessIdentity) { sessionLeaders.insert(leader); descendants.insert(leader) }

    mutating func register(scope: RunScopeRecord) {
        var current = scopes ?? []
        if !current.contains(scope) { current.append(scope) }
        scopes = current
    }

    mutating func register(managedTask binding: ManagedTaskScopeBinding) throws {
        guard binding.ownerRunID == runID, !binding.scope.bootSessionID.isEmpty,
              (scopes ?? []).contains(binding.scope) else { throw SessionTaskError.unverified }
        var current = managedTaskScopes ?? []
        guard !current.contains(where: { ($0.scope == binding.scope || $0.runID == binding.runID) && $0 != binding }) else {
            throw SessionTaskError.conflictingOperation
        }
        if !current.contains(binding) { current.append(binding) }
        managedTaskScopes = current
    }

    mutating func remove(scope: RunScopeRecord) {
        scopes = (scopes ?? []).filter { $0 != scope }
        managedTaskScopes = (managedTaskScopes ?? []).filter { $0.scope != scope }
    }

    /// Scopes recorded in this boot; coalition IDs from another boot mean nothing.
    func currentBootScopes() -> [RunScopeRecord] {
        guard let boot = ProcessTable.bootSessionID() else { return [] }
        return (scopes ?? []).filter { $0.bootSessionID == boot }
    }

    mutating func recordDescendants(_ identities: [ProcessIdentity]) { descendants.formUnion(identities) }

    /// Session membership remains useful after the leader exits. Reject a reused session-leader PID.
    public mutating func observe(_ records: [ProcessRecord]) -> [ProcessRecord] {
        observe(records, readRunID: ProcessTable.runID, confirmSnapshot: { try? ProcessTable.snapshot() })
    }

    // Deterministic seams for races that cannot safely be forced with real PID reuse.
    mutating func observe(_ records: [ProcessRecord], readRunID: (Int32) -> String?,
                          confirmSnapshot: () -> [ProcessRecord]?) -> [ProcessRecord] {
        let candidates = records.filter { $0.identity.pid != getpid() }
        let candidateIdentities = Set(candidates.map(\.identity))
        metadataCache = metadataCache.filter { candidateIdentities.contains($0.key) }
        let byPID = Dictionary(uniqueKeysWithValues: records.map { ($0.identity.pid, $0) })
        let validSessions = Set(sessionLeaders.filter {
            byPID[$0.pid] == nil || byPID[$0.pid]?.identity == $0
        }.map(\.pid))
        observationIssue = nil
        var metadataSeeds: Set<ProcessIdentity> = []
        for record in candidates {
            let metadata: Metadata
            if let cached = metadataCache[record.identity] {
                metadata = cached
            } else {
                metadata = Metadata(matchesRunID: readRunID(record.identity.pid) == runID.uuidString)
                metadataCache[record.identity] = metadata
            }
            if metadata.matchesRunID {
                metadataSeeds.insert(record.identity)
            }
        }
        // Metadata queries use bare PIDs: confirm identity before using them as ancestry seeds.
        // Otherwise PID reuse could incorrectly claim an old process's still-live children.
        if !metadataSeeds.isEmpty {
            if let confirmation = confirmSnapshot() {
                let live = Set(confirmation.map(\.identity))
                metadataCache = metadataCache.filter { live.contains($0.key) }
                metadataSeeds.formIntersection(live)
            } else {
                metadataSeeds.removeAll()
                observationIssue = "Narrowed ownership: could not confirm process identities after metadata lookup; cleanup is unverified."
            }
        }
        var selected = Set(candidates.filter {
            descendants.contains($0.identity) || validSessions.contains($0.sessionID)
                || metadataSeeds.contains($0.identity)
        }.map(\.identity))
        // Resolve arbitrarily deep descendant chains from a single snapshot.
        var changed = true
        while changed {
            changed = false
            for record in candidates where !selected.contains(record.identity) {
                if let parent = byPID[record.parentPID], selected.contains(parent.identity) {
                    selected.insert(record.identity); changed = true
                }
            }
        }
        // Persist only currently live owned identities. A dead session leader is
        // retained only while a selected member of that Unix session survives;
        // once the session is empty it cannot later create another descendant.
        descendants = selected
        sessionLeaders = sessionLeaders.filter { leader in
            selected.contains(leader) || candidates.contains {
                $0.sessionID == leader.pid && selected.contains($0.identity)
            }
        }
        outsideOwnership = candidates.filter { selected.contains($0.identity) && $0.userID != getuid() }
        return candidates.filter { selected.contains($0.identity) && $0.userID == getuid() }
    }

    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
