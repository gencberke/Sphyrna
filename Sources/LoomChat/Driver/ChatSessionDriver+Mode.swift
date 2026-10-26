import Foundation
import LoomCore

extension ChatSessionDriver {
    // MARK: Mode, model, effort

    func acquireMode() async {
        if modeBusy {
            await withCheckedContinuation { modeWaiters.append($0) }
        } else {
            modeBusy = true
        }
    }

    func releaseMode() {
        if modeWaiters.isEmpty { modeBusy = false } else { modeWaiters.removeFirst().resume() }
    }

    /// Runs one mode transition in the chain: after every one asked before it, and before every one asked after it.
    func serialMode<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquireMode()
        defer { releaseMode() }
        return try await body()
    }

    /// Changes the mode now (and on every later spawn). `mode` is Loom's word (`ClaudePermissionMode`); the CLI is told its
    /// own (`cliValue`), and the session keeps Loom's word for the next spawn. Ask is not a mode of the CLI alone: entering
    /// it sets the mode, the deny rules and the style together, and any other choice while it is on clears all three.
    /// Transitions run one at a time, in the order asked (`serialMode`); a pick made while the process starts waits for
    /// the start, and for the Ask layer a resumed Ask session gets.
    public func setPermissionMode(_ mode: String) async throws {
        try refuseInSideChat()
        try await serialMode {
            if holdsPicks {
                if heldPicks.childMode == nil {
                    heldPicks.childMode = (choices.permissionMode, permissionMode, modeBeforeAsk)
                }
                heldPicks.mode = mode
            }
            if mode == ClaudePermissionMode.ask.rawValue {
                try await enterAsk()
            } else if isAsk {
                try await leaveAskNow(to: mode)
            } else {
                try await changeMode(to: mode)
            }
        }
    }

    /// The mode a stopped session shows is the one chosen: the last CLI mode of a run that ended is not.
    private func noteModeWithoutProcess() { permissionMode = nil }

    private func changeMode(to mode: String) async throws {
        let wire = ClaudePermissionMode(rawValue: mode)?.cliValue ?? mode
        if let current = pickableRun {
            _ = try await current.channel.request(.setPermissionMode(PermissionMode(rawValue: wire)))
            permissionMode = wire
            note(model.markMode(wire, at: clock()))
        } else {
            noteModeWithoutProcess()
        }
        await recordChoices(ClaudeLaunchChoices(permissionMode: mode))
    }

    /// Turns Ask on: remembers the mode it replaces (Full access included: `bypassPermissions` leaves Bash open), then
    /// sets `dontAsk`, the deny rules and the style. No relaunch, no turn needed (spike S9). Refused while a tool approval
    /// waits (the driver never answers a request itself) and when the CLI has no `sphyrna:Ask` style (the plugin is missing).
    private func enterAsk() async throws {
        let before = permissionMode ?? choices.permissionMode
        guard let current = pickableRun else {
            if !isAsk { modeBeforeAsk = Self.remembered(before) }
            noteModeWithoutProcess()
            await recordChoices(ClaudeLaunchChoices(permissionMode: ClaudePermissionMode.ask.rawValue))
            return
        }
        if isAsk {
            // Ask is the choice, but the CLI's mode left `dontAsk` (plan mode inside Ask): the rules and the style stay, the mode returns.
            if permissionMode != ChatAskMode.mode.rawValue {
                _ = try await current.channel.request(.setPermissionMode(ChatAskMode.mode))
                permissionMode = ChatAskMode.mode.rawValue
                note(model.markMode(ChatAskMode.mode.rawValue, at: clock()))
            }
            return
        }
        guard !requests.contains(where: { $0.kind == .approval }) else { throw ChatDriverError.requestWaiting }
        if let styles = model.ready?.availableOutputStyles, !styles.contains(ClaudeLoomPlugin.askStyleName) {
            throw ChatDriverError.askUnavailable
        }
        try await applyAskLayer(on: current.channel, restoring: before)
        permissionMode = ChatAskMode.mode.rawValue
        modeBeforeAsk = Self.remembered(before)
        let text = background.count > 0 ? "Mode changed to Ask. Background work started earlier keeps running." : nil
        note(model.markMode(ChatAskMode.mode.rawValue, text: text, at: clock()))
        await recordChoices(ClaudeLaunchChoices(permissionMode: ClaudePermissionMode.ask.rawValue))
    }

    private static func remembered(_ mode: String?) -> String? {
        mode.flatMap { ClaudePermissionMode(rawValue: $0) }.flatMap { $0 == .ask ? nil : $0.rawValue }
    }

    /// Turns Ask off for `mode` (nil: the mode it replaced, else Ask before edits).
    public func leaveAsk(to mode: String? = nil) async throws {
        try refuseInSideChat()
        try await serialMode { try await leaveAskNow(to: mode) }
    }

    /// The rules and the style go first, then the CLI's mode, so there is never a moment with the mode lifted and the rules
    /// still on that leaves Bash open. When the second step fails the first is taken back (fresh mirror, best effort): the
    /// session stays in Ask, as `choices` say.
    private func leaveAskNow(to mode: String?) async throws {
        guard isAsk else { return }
        let target = mode ?? modeBeforeAsk ?? ClaudePermissionMode.askBeforeEdits.rawValue
        let wire = ClaudePermissionMode(rawValue: target)?.cliValue ?? target
        if let current = pickableRun {
            do {
                _ = try await current.channel.request(.applyFlagSettings(ChatAskMode.leaveSettings))
                _ = try await current.channel.request(.setPermissionMode(PermissionMode(rawValue: wire)))
            } catch {
                await restoreAskRules(on: current.channel)
                throw ChatDriverError.modeNotChanged(staysInAsk: true)
            }
            permissionMode = wire
            note(model.markMode(wire, at: clock()))
        } else {
            noteModeWithoutProcess()
        }
        modeBeforeAsk = nil
        await recordChoices(ClaudeLaunchChoices(permissionMode: target))
    }

    /// Ask's rules and style again, read fresh (best effort: a failure leaves the CLI as it is).
    private func restoreAskRules(on channel: ControlChannel) async {
        let rules = await loggedTry("Ask's rules could not be read again") {
            try await channel.request(.other(subtype: "list_permission_rules", fields: [:]))
        }?.permissionRules ?? []
        _ = await loggedTry("Ask's rules and style could not be put back") {
            try await channel.request(.applyFlagSettings(ChatAskMode.enterSettings(mirroring: rules)))
        }
    }

    /// The requests of Ask: the CLI's `dontAsk`, then the live rules and style. If the second fails, the rules are taken off
    /// again and the mode goes back to what it was (`restoring`, the CLI's word), so a half-turned Ask is not left behind.
    func applyAskLayer(on channel: ControlChannel, restoring previous: String? = nil) async throws {
        _ = try await channel.request(.setPermissionMode(ChatAskMode.mode))
        do {
            // The rules the user's own settings hold are read each time Ask is entered; a rule added while Ask is on is not
            // mirrored until Ask is entered again.
            let rules = try await channel.request(.other(subtype: "list_permission_rules", fields: [:])).permissionRules
            _ = try await channel.request(.applyFlagSettings(ChatAskMode.enterSettings(mirroring: rules)))
        } catch {
            LoomLog.error(.chat, "Chat \(self.logRef): Ask's rules and style could not be turned on (\(LoomLog.category(of: error)))")
            _ = await loggedTry("Ask's rules and style could not be taken off again") {
                try await channel.request(.applyFlagSettings(ChatAskMode.leaveSettings))
            }
            if let previous {
                _ = await loggedTry("the mode before Ask could not be put back") {
                    try await channel.request(.setPermissionMode(
                        PermissionMode(rawValue: ClaudePermissionMode(rawValue: previous)?.cliValue ?? previous)))
                }
            }
            throw error
        }
    }

    /// Changes the model. An effort the new model does not offer is not kept: it is clamped to the nearest level below (or
    /// the lowest), and cleared for a model without effort, live and in the catalog, so no later spawn passes a `--effort`
    /// the model lacks.
    public func setModel(_ name: String) async throws {
        try refuseInSideChat()
        if let current = pickableRun {
            _ = try await current.channel.request(.setModel(name))
            // The chip and the ring show the chosen model until a newer `system/init` names the one that runs.
            liveModel = name
        } else if holdsPicks {
            if heldPicks.childModel == nil { heldPicks.childModel = (choices.model, liveModel) }
            heldPicks.model = name
            liveModel = name
        }
        await recordChoices(ClaudeLaunchChoices(model: name))
        guard let option = model.ready?.models.first(where: { $0.value == name }),
              model.ready?.models.contains(where: { !$0.supportedEffortLevels.isEmpty }) == true else { return }
        let effort = effortCleared ? nil : (choices.effort ?? model.latestInit?.effort)
        guard let effort else { return }
        if let kept = ChatEffort.clamped(effort, to: option.supportedEffortLevels) {
            if kept != effort { try await setEffort(kept) }
        } else {
            try await clearEffort()
        }
    }

    public func setEffort(_ level: String) async throws {
        try refuseInSideChat()
        if let current = pickableRun {
            _ = try await current.channel.request(.applyFlagSettings(.effortLevel(level)))
        } else if holdsPicks {
            if heldPicks.childEffort == nil { heldPicks.childEffort = (choices.effort, effortCleared) }
            heldPicks.effort = level
            heldPicks.effortCleared = false
        }
        effortCleared = false
        await recordChoices(ClaudeLaunchChoices(effort: level))
    }

    /// Back to the CLI's own effort (the slider's Default): the live setting and the catalog's record are cleared.
    public func clearEffort() async throws {
        try refuseInSideChat()
        if let current = pickableRun {
            _ = try await current.channel.request(.applyFlagSettings(.effortLevel(nil)))
        } else if holdsPicks {
            if heldPicks.childEffort == nil { heldPicks.childEffort = (choices.effort, effortCleared) }
            heldPicks.effort = nil
            heldPicks.effortCleared = true
        }
        effortCleared = true
        await loadStoredChoices()
        choices.effort = nil
        await runtime.clearLaunchEffort(sessionID: sessionID)
        await followRun()
        changed()
        onChoicesChanged(choices)
    }

    func recordChoices(_ newer: ClaudeLaunchChoices) async {
        await loadStoredChoices()
        choices = choices.merging(newer)
        await followRun()
        // A side chat's choices are the fork's own and fixed (mode `default`, the parent's model and effort): recording them would
        // make the project remember them for its next session.
        if sideChatParent == nil { await runtime.recordLaunchChoices(newer, sessionID: sessionID) }
        changed()
        onChoicesChanged(choices)
    }

    // MARK: What the other clusters ask of the mode

    /// Ask is the session's mode (its choice, as Loom keeps it).
    var isAsk: Bool { choices.permissionMode == ClaudePermissionMode.ask.rawValue }

    /// The run a mode, model or effort pick may tell: none while a handover holds the session (the child is going away).
    private var pickableRun: Run? { handover.isHolding || !phase.isLive ? nil : run }

    /// A live run is held by a handover: a pick is kept for the target face and not sent.
    private var holdsPicks: Bool { handover.isHolding && run != nil && phase.isLive }

    /// Ask's rules, style and mode again (after a reset). Best effort: the layer is already there if the CLI kept it.
    /// `askLayerPending` was set when the reset was read, so a message sent between that and the moment this takes the
    /// mode chain still waits (`write`); it clears when the layer is on, or could not be.
    func reapplyAskLayer() async {
        defer { finishAskLayerPending() }
        await serialMode {
            guard isAsk, let current = run, phase.isLive else { return }
            _ = await loggedTry("Ask's layer could not be put back after a reset") {
                try await applyAskLayer(on: current.channel)
            }
        }
    }

    /// Waits until no mode transition runs and Ask's layer is not being put back (a send right after a mode pick, or a
    /// queued message released right after a reset). Joins the transitions' chain, so it comes after every one asked before.
    func settleModeTransitions() async {
        while askLayerPending { await withCheckedContinuation { askLayerWaiters.append($0) } }
        if modeBusy { await serialMode {} }
    }

    func finishAskLayerPending() {
        askLayerPending = false
        let waiters = askLayerWaiters
        askLayerWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
