import Darwin
import Foundation

/// A deletion's own Codex app-server could not be shown stopped, with its run scope empty.
enum CodexDeletionServerError: Error { case stopUnverified }

/// Codex's part of a deletion (SPEC §5.1, D-121). Codex's own `thread/delete` removes the data, run against an app-server the
/// deletion starts for itself (`withCodexDeletionServer`) on the session's recorded Codex home; Sphyrna removes no Codex file
/// itself. The provider-data step ends only when the native id no longer resolves, no rollout carries it and the session index
/// has no record of it; the catalog row goes after that. The shared prompt history and the capability marker are kept.
extension SessionRuntime {
    struct CodexDeletionCandidate {
        let providerIDs: [String]
        let nativeIDs: [String]
        /// The session's Codex home, its real path.
        let home: URL
        let workingDirectory: String
        let inventory: CodexDataInventory
    }

    /// The refusals and what is there. `preflight` asks a deletion server whether a native id has spawned native sessions
    /// that are not part of this deletion: Codex's delete would take them along, so such a session is refused before
    /// anything is recorded or removed.
    func codexDeletionCandidate(_ id: UUID, preflight: Bool) async throws -> CodexDeletionCandidate {
        let (session, providerIDs) = try await deletableSession(id)
        let home = try await codexDeletionHome()
        let nativeIDs = CodexDataInventory.nativeIDs(of: providerIDs, sessionID: id)
        let inventory = try await codexInventory(nativeIDs, home: home, readsIndex: true)
        if preflight, !nativeIDs.isEmpty {
            let foreign: Bool
            do {
                foreign = try await withCodexDeletionServer(card: id, home: home) { client in
                    try await Self.hasForeignDescendants(nativeIDs, client: client)
                }
            } catch {
                throw SessionRuntimeError.deletionRefused("Codex could not say which sessions belong to this one")
            }
            if foreign {
                throw SessionRuntimeError.deletionRefused(
                    "This Codex session started subagent sessions of its own; Codex would delete them with it")
            }
        }
        return CodexDeletionCandidate(providerIDs: providerIDs, nativeIDs: nativeIDs, home: home,
                                      workingDirectory: session.workingDirectory, inventory: inventory)
    }

    /// The Codex home a deletion uses: the toolchain's, its real path, present and reachable.
    private func codexDeletionHome() async throws -> URL {
        let toolchain: ProviderToolchain
        do { toolchain = try await self.toolchain(for: .codex) } catch {
            throw SessionRuntimeError.deletionRefused("Codex was not found, so Sphyrna cannot tell where it keeps this session")
        }
        guard let profile = toolchain.profileDirectory else {
            throw SessionRuntimeError.deletionRefused("Sphyrna cannot tell which Codex folder keeps this session")
        }
        // The real path (`resolvingSymlinksInPath` keeps `/var`, and the probe's home is a link to a short path).
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let home = realpath(profile.path, &buffer) != nil
            ? URL(fileURLWithPath: String(cString: buffer), isDirectory: true) : profile
        switch Self.configFolderState(home.path) {
        case .present: return home
        case .absent: throw SessionRuntimeError.deletionRefused("The Codex data folder was not found")
        case .unavailable:
            throw SessionRuntimeError.deletionRefused("The Codex data folder is not available (is its volume mounted?)")
        }
    }

    private func codexInventory(_ nativeIDs: [String], home: URL, readsIndex: Bool) async throws -> CodexDataInventory {
        do {
            return try await Task.detached {
                try CodexDataInventory.scan(nativeIDs: nativeIDs, home: home, readsIndex: readsIndex)
            }.value
        } catch {
            throw SessionRuntimeError.deletionRefused(Self.codexReason(for: error))
        }
    }

    /// A preview reads the rollouts and what is kept, never the session index, which only the deletion needs.
    func codexDeletionPreview(_ id: UUID) async throws -> ConversationDeletionPreview {
        let (_, providerIDs) = try await deletableSession(id)
        let home = try await codexDeletionHome()
        let nativeIDs = CodexDataInventory.nativeIDs(of: providerIDs, sessionID: id)
        return await codexPreview(id, home: home,
                                  inventory: try await codexInventory(nativeIDs, home: home, readsIndex: false))
    }

    /// The previews of many Codex sessions from ONE walk of their Codex home (the cleanup review, Storage), each equal to
    /// what `codexDeletionPreview` gives for it. A session it would refuse has no entry; a refused home or walk, none.
    func codexDeletionPreviews(_ ids: [UUID]) async -> [UUID: ConversationDeletionPreview] {
        var sessions: [(id: UUID, nativeIDs: [String])] = []
        for id in ids {
            guard let deletable = try? await deletableSession(id) else { continue }
            sessions.append((id, CodexDataInventory.nativeIDs(of: deletable.providerIDs, sessionID: id)))
        }
        guard !sessions.isEmpty, let home = try? await codexDeletionHome(),
              let inventory = try? await codexInventory(sessions.flatMap(\.nativeIDs), home: home, readsIndex: false)
        else { return [:] }
        var previews: [UUID: ConversationDeletionPreview] = [:]
        for session in sessions {
            previews[session.id] = await codexPreview(session.id, home: home,
                                                      inventory: inventory.restricted(to: session.nativeIDs))
        }
        return previews
    }

    private func codexPreview(_ id: UUID, home: URL, inventory: CodexDataInventory) async -> ConversationDeletionPreview {
        ConversationDeletionPreview(
            sessionID: id, fileCount: inventory.rollouts.count, byteCount: inventory.rollouts.reduce(0) { $0 + $1.bytes },
            configDirectory: home.path, isRunning: await supervisor.session(id: id)?.currentRun != nil,
            notRemoved: inventory.kept, unreachable: [], provider: .codex
        )
    }

    /// The provider-data step: Codex's delete for each native id, then the proof that each is gone. A retry after a delete
    /// that succeeded meets "not found", which counts only once the absence is shown; no other Codex error is a success.
    func removeCodexData(_ record: CatalogDeletion) async throws {
        guard let directory = record.plan.configDirectory else { throw DeletionStepFailure("unsupported_provider") }
        switch Self.configFolderState(directory) {
        case .absent: return   // a home that is gone has nothing left to claim
        case .unavailable: throw DeletionStepFailure("config_unavailable")
        case .present: break
        }
        let nativeIDs = CodexDataInventory.nativeIDs(of: record.plan.providerIDs, sessionID: record.sessionID)
        guard !nativeIDs.isEmpty else { return }
        let home = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try await withCodexDeletionServer(card: record.sessionID, home: home) { client in
                // Checked again on the server that deletes: a subagent session may have appeared since the request.
                let foreign: Bool
                do { foreign = try await Self.hasForeignDescendants(nativeIDs, client: client) }
                catch { throw DeletionStepFailure("descendants_unverified") }
                if foreign { throw DeletionStepFailure("native_descendants") }
                for nativeID in nativeIDs {
                    do { try await client.deleteThread(nativeID) }
                    catch let error where CodexAppServerClient.isAbsentThreadAnswer(error, threadID: nativeID) {
                        // Deleted before (an interrupted attempt), or by another id's subtree: verified below.
                    } catch { throw DeletionStepFailure("native_delete_failed") }
                }
                for nativeID in nativeIDs {
                    let exists: Bool
                    do { exists = try await client.threadExists(nativeID) }
                    catch { throw DeletionStepFailure("verify_failed") }
                    if exists { throw DeletionStepFailure("native_thread_remains") }
                }
            }
        } catch let failure as DeletionStepFailure { throw failure }
        catch CodexDeletionServerError.stopUnverified { throw DeletionStepFailure("server_stop_unverified") }
        catch { throw DeletionStepFailure("server_unavailable") }
        if let first = try await remainingCodexData(of: record).first {
            throw DeletionStepFailure("leftover_files", file: first)
        }
    }

    /// What is still in the home for the record's native ids: a rollout (the inventory's walk, and the transcript reader's own
    /// locator), or a session-index record. Kept entries are not leftovers. A home that is gone has none.
    func remainingCodexData(of record: CatalogDeletion) async throws -> [String] {
        guard let directory = record.plan.configDirectory else { throw DeletionStepFailure("unsupported_provider") }
        switch Self.configFolderState(directory) {
        case .absent: return []
        case .unavailable: throw DeletionStepFailure("config_unavailable")
        case .present: break
        }
        let nativeIDs = CodexDataInventory.nativeIDs(of: record.plan.providerIDs, sessionID: record.sessionID)
        guard !nativeIDs.isEmpty else { return [] }
        let home = URL(fileURLWithPath: directory, isDirectory: true)
        let result = await Task.detached { () -> Result<[String], any Error> in
            Result {
                let inventory = try CodexDataInventory.scan(nativeIDs: nativeIDs, home: home)
                var leftovers = inventory.leftovers
                var info = stat()
                if lstat(home.appendingPathComponent("sessions").path, &info) == 0 {
                    let lookup = CodexRolloutLocator.locate(sessionIDs: nativeIDs, home: home, maximumEntries: 200_000,
                                                            maximumSeconds: 10)
                    guard lookup.complete else { throw CodexDataError.incomplete }
                    leftovers += lookup.files.values.map(\.path).sorted()
                } else if errno != ENOENT { throw CodexDataError.unsafeHome }
                return leftovers
            }
        }.value
        do { return try result.get() } catch { throw DeletionStepFailure("verify_failed") }
    }

    /// Whether any native id has spawned a native session (at any depth) that is not one of `nativeIDs`. A thread already
    /// gone has nothing to take along.
    static func hasForeignDescendants(_ nativeIDs: [String], client: CodexAppServerClient) async throws -> Bool {
        let own = Set(nativeIDs.map { $0.lowercased() })
        for nativeID in nativeIDs {
            guard try await client.threadExists(nativeID) else { continue }
            if !(try await client.spawnedDescendants(of: nativeID)).subtracting(own).isEmpty { return true }
        }
        return false
    }

    private static func codexReason(for error: Error) -> String {
        switch error as? CodexDataError {
        case .unsafeHome: "The Codex data folder is not safe to read (owner or permissions)"
        case .incomplete: "The Codex data folder could not be read in full"
        case .indexUnreadable: "Codex's session index cannot be read"
        case nil: "The Codex data folder could not be inspected"
        }
    }
}
