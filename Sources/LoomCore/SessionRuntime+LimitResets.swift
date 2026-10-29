import Foundation

extension SessionRuntime {
    func limitResetObserver() -> ClaudeLimitResetObserver? {
        guard let callbacks = configuration.onClaudeLimitReset else { return nil }
        if let claudeLimitObserver { return claudeLimitObserver }
        let observer = ClaudeLimitResetObserver(enabled: callbacks.enabled, current: { [weak self] context in
            await self?.isCurrentLimitContext(context) == true
        }, emit: callbacks.receive)
        claudeLimitObserver = observer
        return observer
    }

    func noteLimitHook(_ event: ClaudeHookEvent, envelope: ClaudeHookEnvelope, revision: UInt64?) async {
        guard let observer = claudeLimitObserver, let revision,
              supervisor.providerWorkStateIsReliable(runID: envelope.managedRunID),
              let context = await supervisor.runContext(runID: envelope.managedRunID),
              case .claude = context.session.provider,
              context.launchSessionID == envelope.sessionID,
              await supervisor.identityState(sessionID: context.activeSessionID) == .known,
              let run = context.session.currentRun, run.id == envelope.managedRunID,
              run.state == .running, context.session.providerConversationID == event.providerSessionID,
              !deletionsInFlight.contains(context.activeSessionID), !shuttingDown else { return }
        await observer.applied(event, run: .init(sessionID: context.activeSessionID,
            nativeSessionID: event.providerSessionID, runID: run.id, startedAt: run.startedAt,
            configDirectory: claudeConfigDirectory(), workingDirectory: context.session.workingDirectory),
            revision: revision, failedAt: min(Date(), envelope.sentAt))
    }

    private func isCurrentLimitContext(_ value: ClaudeLimitResetContext) async -> Bool {
        guard !shuttingDown, !deletionsInFlight.contains(value.sessionID),
              supervisor.providerWorkStateIsReliable(runID: value.runID),
              claudeConfigDirectory() == value.configDirectory,
              let context = await supervisor.runContext(runID: value.runID),
              case .claude = context.session.provider,
              context.activeSessionID == value.sessionID,
              await supervisor.identityState(sessionID: context.activeSessionID) == .known,
              context.session.providerConversationID == value.nativeSessionID,
              context.session.workingDirectory == value.workingDirectory,
              context.session.currentRun?.id == value.runID,
              context.session.currentRun?.state == .running,
              (try? await catalog.isDeletionPending(value.sessionID)) == false,
              (try? await catalog.session(id: value.sessionID)) != nil else { return false }
        return true
    }
}
