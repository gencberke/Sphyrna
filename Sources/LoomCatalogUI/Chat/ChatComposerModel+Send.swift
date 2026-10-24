import AppKit
import Foundation
import LoomChat
import LoomCore

/// Sending, the Send button, interrupting, the queue and the delivery actions (CHAT-SPEC → Keys, Send button, Queue).
extension ChatComposerModel {
    // MARK: The Send button

    /// What the button is now. `commandHeld` turns Send now into After this turn.
    func sendKind(commandHeld: Bool) -> ComposerSendKind {
        if editing != nil { return hasContent ? .update : .sendDisabled }
        if state.phase == .stopping { return .sendDisabled }
        // Moving to the terminal: nothing starts a turn here. A running turn can still be interrupted.
        if handoverPending != nil { return state.turnRunning && !hasContent ? .interrupt : .sendDisabled }
        // A card is shown: the text is the card's. Send waits (the card's own buttons answer); Interrupt stays.
        if cardShown { return state.turnRunning && !hasContent ? .interrupt : .sendDisabled }
        if state.turnRunning {
            if !hasContent { return .interrupt }
            return commandHeld ? .afterTurn : .sendNow
        }
        if hasContent { return preparing > 0 ? .sendDisabled : .send }
        if state.queue.paused != nil, !state.queue.isEmpty { return .resume }
        return .sendDisabled
    }

    /// The button's click: what its kind means. ⌘ held while it reads Send now queues the message instead.
    func performSendButton(commandHeld: Bool) {
        switch sendKind(commandHeld: commandHeld) {
        case .sendDisabled: break
        case .send, .sendNow: submit(secondary: false)
        case .afterTurn: submit(secondary: true)
        case .update: updateQueuedMessage()
        case .interrupt: interrupt()
        case .resume: resumeQueue()
        }
    }

    // MARK: Sending

    /// ↵ (`secondary` false) or ⌘↵ (true) with a message in the field. Idle, both send. While Claude works, ↵ sends it now
    /// (`next`, or `now` when the only work is a Bash call) and ⌘↵ puts it in Loom's queue. The field is emptied at once
    /// and the message is kept in the draft until the driver has it; a send that fails puts it back.
    func submit(secondary: Bool) {
        // With a card shown the text belongs to the card: nothing is sent (↵ never answers a card either).
        guard !cardShown, hasContent, preparing == 0 else { return }
        if editing != nil { updateQueuedMessage(); return }
        guard state.phase != .stopping else { return }
        // Moving to the terminal: the text stays in the field, and the notice says why nothing was sent.
        if let moving = handoverPending {
            show("\(moving) Send it when the session is back in Chat, or cancel the move.")
            return
        }
        let typed = currentText()
        let outgoing = attachments
        let pills = mentions
        let working = state.turnRunning
        if secondary, working, !outgoing.isEmpty {
            show("A queued message carries text only. Remove the attachments, or press \u{21B5} to send now.")
            return
        }
        // The pills become their mention texts in front of the typed words (D-96); a queued message carries them too.
        let (message, skipped) = mentionedText(typed, mentions: pills)
        guard !outgoing.isEmpty || message.contains(where: { !$0.isWhitespace }) else {
            show(ComposerMentionText.skippedNotice(skipped) + " Nothing was sent.")
            return
        }
        let timing: ChatSendTiming = working && secondary ? .afterTurn : .next
        let flight = ComposerInFlight(text: typed, attachments: outgoing, mentions: pills)
        inFlight.append(flight)
        clearComposer()
        flushDraft()
        history.append(typed)
        if skipped > 0 { show(ComposerMentionText.skippedNotice(skipped)) }
        // A message sent while the stack was held ends the typing guard: the cards show, and the text was not their note.
        cards?.composerSent()
        chain { [self] in
            do {
                _ = try await driver.send(message, attachments: outgoing.map(\.outgoing), timing: timing)
                finish(flight)
            } catch {
                // Back in the composer first (it writes the attachments' files again), then the in-flight copy goes: the
                // draft never lists the message twice, and never loses its attachments or its pills.
                putBack(typed, outgoing, pills)
                finish(flight)
                show(Self.sendFailure(error, backInComposer: true))
            }
        }
    }

    /// The message as it goes out: each pill's mention text (`ComposerEnvironment.sessionMention`), in pill order, before the
    /// typed words. A pill whose session is gone or has no transcript is left out, and counted.
    func mentionedText(_ typed: String, mentions pills: [ComposerMention]) -> (text: String, skipped: Int) {
        let texts = pills.compactMap { environment.sessionMention($0.id) }
        return (ComposerMentionText.message(mentions: texts, text: typed), pills.count - texts.count)
    }

    private func finish(_ flight: ComposerInFlight) {
        inFlight.removeAll { $0.id == flight.id }
        flushDraft()
    }

    /// Sends run one after the other, in the order they were made.
    func chain(_ work: @escaping @MainActor () async -> Void) {
        let previous = sendTail
        sendTail = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Empties the field, the attachments and the pills (not the draft file: the in-flight copy keeps it until the send is
    /// accepted).
    func clearComposer() {
        setAttachments([])
        setMentions([])
        setText("")
        history.noteEdit()
    }

    /// A message that was not accepted comes back in front of what was typed since.
    func putBack(_ message: String, _ outgoing: [ComposerAttachment], _ pills: [ComposerMention] = []) {
        for attachment in outgoing { keepAttachmentFile(attachment) }
        setAttachments(outgoing + attachments)
        setMentions(pills + mentions)
        setText(Self.join(message, text))
        flushDraft()
    }

    /// What a failed send says. `backInComposer` only where it is true: a failed Retry or Compact has nothing to put back.
    static func sendFailure(_ error: any Error, backInComposer: Bool = false) -> String {
        let back = backInComposer ? " The message is back in the composer." : ""
        switch error as? ChatDriverError {
        case .queueFull?: return "The queue is full (100 messages or 1 MB)." + back
        case .queueTextOnly?: return "A queued message carries text only."
        case .stopping?: return "The session is stopping." + back
        case .handingOver?: return "The session is moving to the terminal." + back
        case .busy?: return "The session is busy." + back
        case .inputFull?: return "Claude is not reading its input." + back
        case .couldNotStart?: return "The session could not start." + back
        default: return "The message was not sent." + back
        }
    }

    // MARK: Interrupt

    /// Esc or the square button: stops the turn, keeps the process, pauses the queue. Typed text stays where it is;
    /// messages Claude had not read come back into the composer (`refresh` takes them).
    func interrupt(byEscape: Bool = false) {
        guard state.turnRunning || state.requestCount > 0 else { return }
        Task { [driver, weak self] in
            // Esc asks the driver's own Esc entry, which does nothing while a request waits; the button asks outright.
            if byEscape { await driver.interruptFromEscape() } else { await driver.interrupt() }
            await self?.refresh()
        }
    }

    // MARK: The queue

    func resumeQueue() {
        Task { [driver, weak self] in
            do { try await driver.resumeQueue() } catch { self?.show("The queue could not be resumed.") }
            await self?.refresh()
        }
    }

    func clearQueue() {
        if editing != nil { cancelEdit() }
        Task { [driver, weak self] in
            _ = await driver.clearQueue()
            await self?.refresh()
        }
    }

    func removeQueued(_ id: String) {
        if editing?.itemID == id { cancelEdit() }
        Task { [driver, weak self] in
            _ = try? await driver.removeQueued(id: id)
            await self?.refresh()
        }
    }

    func sendQueuedNow(_ id: String) {
        if editing?.itemID == id { cancelEdit() }
        Task { [driver, weak self] in
            do { _ = try await driver.sendQueuedNow(id: id) } catch ChatDriverError.requestWaiting {
                self?.show("Answer the request above first. The message stays in the queue.")
            } catch { self?.show("That message could not be sent now.") }
            await self?.refresh()
        }
    }

    func moveQueued(_ id: String, to position: Int) {
        Task { [driver, weak self] in
            try? await driver.moveQueued(id: id, to: position)
            await self?.refresh()
        }
    }

    /// Moves a queued message one place up or down (⌥↑, ⌥↓ with the row focused).
    func moveQueued(_ id: String, by delta: Int) {
        guard let index = state.queue.items.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, index + delta), state.queue.items.count - 1)
        if target != index { moveQueued(id, to: target) }
    }

    /// Edit: the message moves into the composer, its row stays (highlighted) and the button reads Update. What was in the
    /// composer waits and comes back when the edit ends.
    func beginEdit(_ id: String) {
        guard let item = state.queue.items.first(where: { $0.id == id }) else { return }
        let saved: (String, [ComposerAttachment], [ComposerMention])
        if let current = editing {
            saved = (current.savedText, current.savedAttachments, current.savedMentions)
        } else {
            saved = (currentText(), attachments, mentions)
        }
        setEditing(ComposerQueueEdit(itemID: id, savedText: saved.0, savedAttachments: saved.1, savedMentions: saved.2,
                                     originalText: item.text))
        setAttachments([])
        setMentions([])
        setText(item.text)
        flushDraft()
        editor?.focus()
        // The strip drew from the state the composer last read: the driver's queue now says whether the item is still there.
        Task { [weak self] in await self?.refresh() }
    }

    /// Update (↵ or the button while editing): the item takes the composer's text and the composer gets its own draft back.
    func updateQueuedMessage() {
        guard let edit = editing else { return }
        // Pills added while editing go into the item as on a send.
        let newText = mentionedText(currentText(), mentions: mentions).text
        guard newText.contains(where: { !$0.isWhitespace }) else { return }
        // A queued message carries text only: nothing is dropped, and the attachments stay in the composer.
        guard attachments.isEmpty else {
            show("A queued message carries text only. Remove the attachments, or press \u{21B5} to send now.")
            return
        }
        Task { [driver, weak self] in
            do {
                try await driver.editQueued(id: edit.itemID, text: newText)
                self?.endEdit(keepingComposer: false)
            } catch ChatDriverError.noSuchQueueItem {
                // The message was sent meanwhile: the changed text stays in the composer.
                self?.endEdit(keepingComposer: true)
                self?.show("That message was sent before the change. Your text is in the composer.")
            } catch {
                self?.show("The change was not saved. " + Self.sendFailure(error))
            }
            await self?.refresh()
        }
    }

    /// Esc while editing: the edit is dropped and the composer's own draft comes back.
    func cancelEdit() {
        endEdit(keepingComposer: false)
    }

    /// Ends the edit. With `keepingComposer` (the item left the queue) the edited text stays and the saved draft follows it.
    func endEdit(keepingComposer: Bool) {
        guard let edit = editing else { return }
        setEditing(nil)
        if keepingComposer {
            setAttachments(edit.savedAttachments + attachments)
            setMentions(mentions + edit.savedMentions)
            setText(Self.join(text, edit.savedText))
        } else {
            setAttachments(edit.savedAttachments)
            setMentions(edit.savedMentions)
            setText(edit.savedText)
        }
        flushDraft()
    }

    /// A queued message that left the queue while it was edited (the queue sent it) ends the edit: its text stays.
    func endEditIfItemLeft() {
        guard let edit = editing, !state.queue.items.contains(where: { $0.id == edit.itemID }) else { return }
        // Clear and Remove from this composer end the edit themselves, so an item that left on its own was sent. The text
        // stays in the composer only if the user changed it; otherwise their own draft comes back.
        if currentText() == edit.originalText {
            endEdit(keepingComposer: false)
            show("That message was sent while you edited it.")
        } else {
            endEdit(keepingComposer: true)
            show("That message was sent while you edited it. Your changes are in the composer.")
        }
    }

    // MARK: Delivery (rows)

    /// "Read now" on a sent message the CLI holds unread: it is taken back and sent again, to be read at once.
    func readNow(rowID: String) {
        Task { [driver, weak self] in
            do {
                if try await driver.readNow(messageID: rowID) == false { self?.show("Claude had already taken that message.") }
            } catch { self?.show("That message could not be read now.") }
        }
    }

    /// "Retry" on a message that was not delivered: sent again, as a new message.
    func retry(rowID: String) {
        chain { [self] in
            do { _ = try await driver.retry(messageID: rowID) } catch {
                show("Retry did not work. " + Self.sendFailure(error))
            }
        }
    }

    // MARK: Compact

    /// Compact now: Claude's own `/compact`, sent like a message. Only when Claude is idle and no card waits.
    func compactNow() {
        guard state.phase == .ready, !state.turnRunning, state.requestCount == 0 else { return }
        chain { [self] in
            do { _ = try await driver.send("/compact", timing: .next) } catch { show("Compact did not start. " + Self.sendFailure(error)) }
        }
    }

    // MARK: Mode, model, effort

    @discardableResult func setMode(_ raw: String) -> Task<Void, Never> {
        Task { [driver, weak self] in
            do { try await driver.setPermissionMode(raw) } catch { self?.show(Self.modeFailure(error)) }
            await self?.refresh()
        }
    }

    /// The notice for a mode change that did not happen: what is true now, in one line.
    nonisolated static func modeFailure(_ error: Error) -> String {
        switch error as? ChatDriverError {
        case .requestWaiting: "Answer the waiting request first."
        case .modeNotChanged(staysInAsk: true): "The mode was not changed; the session stays in Ask."
        case .askUnavailable: "Ask is not available: Sphyrna's Ask style did not load. The mode was not changed."
        default: "The mode was not changed."
        }
    }

    @discardableResult func setModel(_ value: String) -> Task<Void, Never> {
        Task { [driver, weak self] in
            do { try await driver.setModel(value) } catch { self?.show("The model was not changed.") }
            await self?.refresh()
        }
    }

    @discardableResult func setEffort(_ level: String) -> Task<Void, Never> {
        effortChanged = true
        return Task { [driver, weak self] in
            do { try await driver.setEffort(level) } catch { self?.show("The effort was not changed.") }
            await self?.refresh()
        }
    }

    /// The slider's reset: back to the effort this session had when it was opened (`effortBaseline`), or to Default (the
    /// CLI's own) when it had none.
    @discardableResult func resetEffort() -> Task<Void, Never> {
        effortChanged = true
        guard let target = ComposerBarText.resetTarget(state, effortBaseline: effortBaseline, observed: environment.contextFallback()?.model) else {
            return Task { [driver, weak self] in
                do { try await driver.clearEffort() } catch { self?.show("The effort was not changed.") }
                await self?.refresh()
            }
        }
        return setEffort(target)
    }

    /// What the one model chip and its popover show now.
    var modelPicker: ComposerModelPicker {
        ComposerBarText.modelPicker(state, effortBaseline: effortBaseline, observedModel: environment.contextFallback()?.model)
    }

    /// Resolves once the sends made so far have reached the driver (tests).
    func settled() async {
        await sendTail?.value
    }
}
