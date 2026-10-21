import Foundation

/// The fork underneath the side chat (V22, spikes S6 and S6b). A side chat is a real session of its own: a fork of the parent
/// (`--resume <parent> --fork-session --session-id <new>`) with a card Loom makes before the spawn, so the fork's id is known
/// from the start and its `SessionStart` (source `fork`) has nothing to adopt. The card links to its parent (`SideChatLink`)
/// and no list shows it. The request policy, the Chat driver of a side chat and the host's API are in `LoomChat`.
extension SessionRuntime {
    /// The tools a side chat's launch makes ask even where the user's own allow rules would let them through, so Loom's policy
    /// answers every one of them. Step 0 (20 Oct 2026, Haiku, Claude Code 2.1.300): with these `permissions.ask` entries in
    /// `--settings`, the fork read 100% of the parent's context from cache, and a `Write` that the work folder's own
    /// `permissions.allow` allowed still arrived as `can_use_tool`.
    static let sideChatAskRules = ["Edit", "Write", "MultiEdit", "NotebookEdit", "Bash"]

    /// Forks `parentSessionID` into a new side chat in the Chat face and returns its run. The card is made first (the parent's
    /// project and folder, the parent's model and effort as the catalog holds them, `--permission-mode default`, the fork's id
    /// chosen here), and goes at once, with anything it wrote, when the spawn fails. Nothing here touches the parent's run, card or
    /// driver, and a live parent never blocks it (S6 Q5: a fork of a parent mid-turn is safe).
    public func startSideChat(
        parentSessionID: UUID, sessionID: UUID = UUID(), outputSink: any PipeOutputSink
    ) async throws -> RuntimePipeLaunch {
        guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
        guard startingSessions.insert(sessionID).inserted else { throw SessionRuntimeError.alreadyStarting(sessionID) }
        defer { startingSessions.remove(sessionID) }
        guard !(try await catalog.isDeletionPending(parentSessionID)) else {
            throw SessionRuntimeError.deletionPending(parentSessionID)
        }
        guard let parent = try await catalog.session(id: parentSessionID) else {
            throw SessionRuntimeError.sessionNotFound(parentSessionID)
        }
        guard HarnessCapabilities.of(parent.session.provider, startable: []).sideChats else {
            throw SessionRuntimeError.unsupportedProvider(parent.session.provider)
        }
        guard !parent.isSideChat else { throw LoomError.message("A side chat cannot be forked") }
        guard let parentConversation = parent.session.providerConversationID, !parentConversation.isEmpty else {
            throw SessionRuntimeError.noProviderIdentity(.claude)
        }
        try requireDirectory(parent.session.workingDirectory)
        let toolchain = try await toolchain(for: .claude)
        guard toolchain.capabilities.supportsSessionID, toolchain.capabilities.supportsForkSession else {
            throw LoomError.message("This Claude version cannot fork a session")
        }
        let hooks = try ensureHooks()
        // The fork's identity, lower case as the CLI writes ids, chosen before the spawn.
        let forkID = UUID().uuidString.lowercased()
        var choices = try await catalog.launchChoices(sessionID: parentSessionID)
        choices.permissionMode = ClaudePermissionMode.askBeforeEdits.rawValue
        // Validated before the card exists: a CLI that cannot take the route leaves nothing behind.
        let profile = try claudeProfile(
            route: .fork(parent: parentConversation, newID: forkID), toolchain: toolchain, sessionID: sessionID, hooks: hooks,
            choices: choices, face: .chat, askRules: Self.sideChatAskRules
        )
        let forkedAt = Date()
        try await supervisor.createSession(
            ManagedSession(id: sessionID, provider: .claude, providerConversationID: forkID,
                           workingDirectory: parent.session.workingDirectory),
            projectID: parent.projectID, sideChat: SideChatLink(parentSessionID: parentSessionID, forkedAt: forkedAt)
        )
        do {
            try await catalog.recordSideChatChoices(choices, sessionID: sessionID)
            return try await launchChatClaude(sessionID: sessionID, toolchain: toolchain, profile: profile,
                                              outputSink: outputSink, isResume: false, isFork: true)
        } catch {
            startingSessions.remove(sessionID)
            await removeSideChatCard(sessionID)
            throw error
        }
    }

    /// A side chat that never got going: its card, and whatever the fork wrote, go through the verified deletion path; where that
    /// is refused (no Claude data folder to look in) the card alone is removed, as nothing else exists.
    func removeSideChatCard(_ id: UUID) async {
        if let outcome = try? await deleteConversation(id: id), outcome == .deleted { return }
        do { try await removeFromLoomOnly(id: id) } catch {
            LoomLog.error(.lifecycle, "A side chat that did not start could not be removed (\(LoomLog.category(of: error)))")
        }
    }

    /// The side chat's first message was sent: its uuid is kept (written once) and the first line of its text becomes the card's
    /// title, never custom. A side chat never asks Claude to name it.
    public func recordSideChatFirstMessage(sessionID: UUID, uuid: String, text: String) async {
        do {
            try await catalog.setSideFirstUUID(uuid, sessionID: sessionID)
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            try await catalog.setSideChatTitle(firstLine, sessionID: sessionID)
        } catch {
            LoomLog.error(.catalog, "A side chat's first message could not be recorded (\(LoomLog.category(of: error)))")
        }
    }

    /// Discards a side chat: its Claude process is stopped in the supervisor's stop order (the Chat driver's `leave` hook
    /// interrupts a running turn, then stdin closes and the exit is awaited), and `deleteConversation` removes the fork's files
    /// and rows. Only a side chat can be discarded here; the parent's transcript is never part of the plan (the fork has an id of
    /// its own). Returns the deletion's outcome.
    @discardableResult
    public func discardSideChat(id: UUID) async throws -> ConversationDeletionOutcome {
        guard let record = try await catalog.session(id: id), record.isSideChat else {
            throw SessionRuntimeError.sessionNotFound(id)
        }
        if await supervisor.session(id: id)?.currentRun != nil {
            do {
                let report = try await stopConversation(sessionID: id)
                guard report.succeeded else { throw SessionRuntimeError.unverifiedStop(id) }
            } catch SessionRuntimeError.notRunning {}
        }
        return try await deleteConversation(id: id)
    }

    /// A parent's deletion (or a project's removal) deletes its side chats first, each through `discardSideChat`. One that cannot
    /// be deleted keeps the parent: its rows would otherwise outlive the session they belong to.
    func deleteSideChats(of parentSessionID: UUID) async throws {
        for record in try await catalog.sideChats(of: parentSessionID, includingDeleting: true) {
            try await discardForCascade(record.session.id)
        }
    }

    private func discardForCascade(_ id: UUID) async throws {
        guard try await discardSideChat(id: id) == .deleted else {
            throw SessionRuntimeError.deletionRefused("A side chat of this session could not be deleted")
        }
    }

    /// Deletes the side chats left in an empty project, each through `discardSideChat`. A project's removal does it first: side
    /// chats are hidden from the project's count, so nothing else would take them. With a session still in the project nothing is
    /// deleted (`projectNotEmpty`): a side chat belongs to its parent, and goes with the parent's own deletion.
    public func deleteSideChats(inProject projectID: UUID) async throws {
        guard try await catalog.sessionCounts()[projectID, default: 0] == 0 else {
            throw SessionCatalogError.projectNotEmpty(projectID)
        }
        for record in try await catalog.sideChats(inProject: projectID) { try await discardForCascade(record.session.id) }
    }

    /// Removes a project: its side chats go first, then the project, which must be empty of sessions.
    public func removeProject(id: UUID) async throws {
        try await deleteSideChats(inProject: id)
        try await catalog.removeProject(id: id)
    }
}
