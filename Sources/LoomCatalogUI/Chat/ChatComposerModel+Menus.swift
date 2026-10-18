import AppKit
import Foundation
import LoomChat

/// The `/` and `@` menus (CHAT-SPEC → Menus): when they open, what they list, how they are driven and what a choice puts
/// into the text. Plain text goes into the message (`@path`, `/name`); the menus only help to write it.
extension ChatComposerModel {
    /// The most rows a menu shows.
    nonisolated static let menuLimit = 80
    /// Sessions in the `@` list.
    nonisolated static let sessionLimit = 8

    // MARK: Following the text

    /// The text changed under the user's hands: opens, updates or closes a menu from the few characters before the caret.
    func updateMenu() {
        guard let editor else { return }
        guard !editor.hasMarkedText() else { return }
        let caret = editor.caretLocation
        let from = max(0, caret - (ComposerTrigger.window + 1))
        let before = editor.substring(NSRange(location: from, length: caret - from))
        guard let trigger = ComposerTrigger.detect(before: before, caret: caret) else {
            dismissedTrigger = nil
            closeMenuState()
            return
        }
        let kind: ComposerMenuState.Kind
        switch trigger {
        case .slash: kind = .commands
        case .mention: kind = .mention
        }
        // Esc closed this trigger: it stays closed until a different one begins.
        if let dismissed = dismissedTrigger {
            if dismissed.kind == kind, dismissed.location == trigger.range.location {
                closeMenuState()
                return
            }
            dismissedTrigger = nil
        }
        switch kind {
        case .commands: showCommands(trigger)
        case .mention: showMention(trigger)
        }
    }

    /// The model set the text itself: no menu follows from that.
    func closeMenuState() {
        mentionTask?.cancel()
        mentionTask = nil
        mentionCancel?.cancel()
        mentionCancel = nil
        // A walk still under way stops, and what it found so far is not kept.
        fileScanCancel?.cancel()
        releaseMentionData()
        if menu != nil { setMenu(nil) }
    }

    /// What the `@` menu kept for its opening: the file index (up to `ComposerFileIndex.maximumEntries` entries) and the session
    /// rows. A closed menu holds neither, so a composer nobody is mentioning from costs no index; the next opening scans again.
    private func releaseMentionData() {
        fileScan = nil
        fileEntries = []
        fileEntriesRoot = nil
        fileEntriesAt = nil
        mentionSessions = nil
    }

    // MARK: Commands

    private var actionItems: [ComposerMenuItem] {
        guard environment.continueInTerminal != nil else { return [] }
        let refusal = environment.continueInTerminalRefusal()
        return [ComposerMenuItem(id: "action:terminal", kind: .action, title: "Continue in Terminal",
                                 detail: refusal ?? "Run this session in the terminal", trailing: nil, insertion: "",
                                 unavailableReason: refusal)]
    }

    private func showCommands(_ trigger: ComposerTrigger) {
        mentionTask?.cancel()
        let all = ComposerCommandItems.items(from: state, actions: actionItems)
        let ranked = ComposerRanking.rank(all, query: trigger.query, limit: Self.menuLimit)
        var next = ComposerMenuState(kind: .commands, trigger: trigger, items: ranked)
        if let current = menu, current.kind == .commands, current.trigger.query == trigger.query {
            next.selection = min(current.selection, max(0, ranked.count - 1))
        }
        // Nothing matches: no panel, so Return still sends what was typed.
        if ranked.isEmpty { return setMenu(nil) }
        setMenu(next)
    }

    // MARK: Mentions

    private func showMention(_ trigger: ComposerTrigger) {
        let opening = menu?.kind != .mention
        let sessions = rankedSessions(trigger.query, at: trigger.range.location)
        let keptFiles = menu?.kind == .mention ? menu!.items.filter { $0.kind == .file || $0.kind == .folder } : []
        let ready = fileEntriesRoot == environment.workingDirectory() && fileEntriesAt != nil
        var next = ComposerMenuState(kind: .mention, trigger: trigger, items: keptFiles + sessions, loading: !ready)
        if let current = menu, current.kind == .mention { next.selection = min(current.selection, max(0, next.items.count - 1)) }
        setMenu(next)
        refreshFiles(for: trigger.query, immediately: opening)
    }

    /// The session rows for `query`. The candidates (the catalog's rows, their titles and projects, their order) are built once
    /// per opening of the menu, at the `@` it opened on, and kept until the menu closes: a keystroke only ranks them.
    private func rankedSessions(_ query: String, at location: Int) -> [ComposerMenuItem] {
        if mentionSessions?.location != location {
            let items = environment.sessionCandidates()
                .sorted { $0.lastActivity > $1.lastActivity }
                .map { candidate in
                    ComposerMenuItem(id: "session:" + candidate.id.uuidString, kind: .session, title: candidate.title,
                                     detail: candidate.project, trailing: "Session", insertion: "")
                }
            mentionSessions = (location, items)
        }
        return ComposerRanking.rank(mentionSessions?.items ?? [], query: query, limit: Self.sessionLimit) { [$0.detail ?? ""] }
    }

    /// Ranks the files again after typing pauses (120 ms), off the main thread, and stops when the query moves on.
    private func refreshFiles(for query: String, immediately: Bool) {
        mentionTask?.cancel()
        mentionCancel?.cancel()
        let cancel = ComposerCancel()
        mentionCancel = cancel
        let delay = environment.mentionDebounce
        mentionTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            let entries = await ensureFileEntries()
            guard !Task.isCancelled else { return }
            let ranked = await Task.detached(priority: .userInitiated) {
                ComposerFileIndex.rank(entries, query: query, limit: ChatComposerModel.menuLimit,
                                       isCancelled: { cancel.isCancelled })
            }.value
            guard !Task.isCancelled, !cancel.isCancelled, var current = menu, current.kind == .mention,
                  current.trigger.query == query else { return }
            current.items = ranked + current.items.filter { $0.kind == .session }
            current.loading = false
            current.selection = min(current.selection, max(0, current.items.count - 1))
            setMenu(current.items.isEmpty ? nil : current)
        }
    }

    /// The files of the session's folder: scanned when the menu first opens and kept while it is open, for 15 s at most (a
    /// closed menu drops them, `releaseMentionData`).
    private func ensureFileEntries() async -> [ComposerFileEntry] {
        guard let folder = environment.workingDirectory() else { return [] }
        if fileEntriesRoot == folder, let at = fileEntriesAt, Date().timeIntervalSince(at) < 15 { return fileEntries }
        if fileEntriesRoot == folder, let scan = fileScan { return await scan.value }
        let scanner = environment.scanFiles
        let cancel = ComposerCancel()
        fileScanCancel = cancel
        fileEntriesRoot = folder
        fileEntriesAt = nil
        let scan = Task.detached(priority: .userInitiated) { scanner(URL(fileURLWithPath: folder), cancel) }
        fileScan = scan
        let entries = await scan.value
        if fileScan == scan { fileScan = nil }
        guard !cancel.isCancelled else { return entries }
        fileEntries = entries
        fileEntriesAt = Date()
        return entries
    }

    // MARK: Driving a menu

    func menuMove(_ delta: Int) {
        guard var current = menu, !current.items.isEmpty else { return }
        let count = current.items.count
        current.selection = ((current.selection + delta) % count + count) % count
        setMenu(current)
    }

    func selectMenuItem(at index: Int) {
        guard var current = menu, current.items.indices.contains(index) else { return }
        current.selection = index
        setMenu(current)
    }

    /// ↵ or Tab: inserts the selected row.
    func chooseSelected() {
        guard let current = menu, current.items.indices.contains(current.selection) else { return }
        choose(current.items[current.selection])
    }

    func choose(_ item: ComposerMenuItem) {
        guard let current = menu, let editor else { return }
        let range = current.trigger.range
        switch item.kind {
        case .terminalOnly:
            // It runs only in the terminal: the menu says so, and the terminal opens when it can.
            closeMenuState()
            dismissedTrigger = (current.kind, range.location)
            if let open = environment.continueInTerminal { open() } else {
                show("\(item.title) only runs in the terminal.")
            }
        case .action:
            // Not allowed now: the row said why; choosing it keeps the text and says it again.
            if let reason = item.unavailableReason {
                closeMenuState()
                dismissedTrigger = (current.kind, range.location)
                show(reason)
                return
            }
            editor.replace(range, with: "")
            environment.continueInTerminal?()
        case .session:
            guard let id = UUID(uuidString: String(item.id.dropFirst("session:".count))) else { return }
            editor.replace(range, with: (environment.sessionMention(id) ?? "[session \(item.title)]") + " ")
        default:
            editor.replace(range, with: item.insertion)
        }
    }

    /// Esc: closes the menu and ignores this trigger until a different one.
    func closeMenu() {
        guard let current = menu else { return }
        dismissedTrigger = (current.kind, current.trigger.range.location)
        closeMenuState()
    }

    /// A shortcut or the + menu opens a menu by writing its trigger.
    func openMenu(_ request: ComposerKeys.MenuRequest) {
        guard let editor else { return }
        switch request {
        case .attach:
            break // the view presents the file panel (`pickFiles`)
        case .mention:
            if menu?.kind == .mention { return }
            let caret = editor.caretLocation
            let previous = caret > 0 ? editor.substring(NSRange(location: caret - 1, length: 1)) : ""
            dismissedTrigger = nil
            editor.insertAtCaret(previous.isEmpty || previous.first?.isWhitespace == true ? "@" : " @")
        case .commands:
            if menu?.kind == .commands { return }
            if currentText().isEmpty {
                dismissedTrigger = nil
                editor.insertAtCaret("/")
            } else {
                show("Commands start a message. Clear the composer first, or type / at its start.")
            }
        }
        editor.focus()
    }
}
