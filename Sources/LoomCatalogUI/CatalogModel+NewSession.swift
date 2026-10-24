import Foundation
import LoomCore
import Observation

/// What the new-session draft needs from the conversation runtime beyond `ConversationIntents`: the first send
/// of a draft starts a Claude session with that message. `ConversationController` adopts it; an intents object
/// that does not (a test stub) cannot send a draft, and the draft keeps its text.
@MainActor
public protocol NewSessionIntents: ConversationIntents {
    /// Starts a Claude session in the project with the draft's first message through the normal start path.
    /// `outcome` is called once on the main actor: `.started` when the session's card exists, `.failed` when
    /// nothing was started (the failure is on the banner).
    func startSession(projectID: UUID?, launch: NewSessionLaunch, focus: NewSessionFocus,
                      outcome: @escaping @MainActor (NewSessionOutcome) -> Void)
}

/// What the window shows once the session started: the session itself (↵), or a fresh draft while the
/// session starts in the background (⌘↵).
public enum NewSessionFocus: Equatable, Sendable {
    case session
    case freshDraft
}

public enum NewSessionOutcome: Equatable, Sendable {
    case started(UUID)
    case failed
}

/// The state of the new-session drafts (V07): any number of drafts per project, each with its own id, the one each project shows,
/// the presets and what was last used in each project (read from the catalog, which records it for a start and for a live change).
/// The drafts live in memory; a draft with text is written to `<data root>/new-session.json` 300 ms after the last change, an
/// empty one never is, so a draft costs nothing until it is typed in or sent. Logic that needs the catalog or the runtime is in
/// `CatalogModel+NewSession`.
@MainActor @Observable
public final class NewSessionState {
    /// Every draft the window has opened, by id, the empty ones included (an empty draft is reused, never listed).
    public private(set) var drafts: [UUID: SessionDraft] = [:]
    /// The draft each project shows, by `SessionDraft.projectKey`: leaving the page and coming back finds the same one.
    private(set) var current: [String: UUID] = [:]
    public private(set) var presets: [NewSessionPreset] = []
    /// The drafts whose first send is under way, by draft id.
    private(set) var sending: Set<UUID> = []
    /// The drafts whose Full access was picked in this window run, by draft id: a pick that came from the file (a draft saved
    /// before a relaunch) or from a preset was not made on this screen.
    private(set) var fullAccessConfirmed: Set<UUID> = []
    /// The Git branch of each project's folder, read when its draft opens.
    private(set) var branches: [String: GitBranch] = [:]
    private(set) var settings = NewSessionSettings()
    /// The mode, model and effort each project's next draft starts with, by `SessionDraft.projectKey` (the catalog's record,
    /// `SessionCatalog.lastUsedLaunchChoices`): a live change in a session counts as well as a start.
    public private(set) var lastUsedChoices: [String: ClaudeLaunchChoices] = [:]
    /// What the user should know about the saved drafts, in plain words: a save that failed (what is typed is
    /// still here, but may not survive a restart), or an unreadable file that was moved aside. Nil when all is well.
    public private(set) var storeNotice: String?
    @ObservationIgnored var store: NewSessionStore?
    @ObservationIgnored var clock: () -> Date = { Date() }
    /// Remora's brief in each draft (DESIGN §8, D-80; `DraftRemoraModel.swift`), by draft id: where the draft's text came
    /// from, or that the brief was copied. Memory only; it goes with the draft's text (emptied, discarded, sent).
    var remoraOrigins: [UUID: DraftRemoraOrigin] = [:]
    /// When Draft Brief was clicked in each draft, by draft id, for the time the row shows.
    @ObservationIgnored var remoraStartedAt: [UUID: Date] = [:]
    /// The drafted brief already put in (its `draftedAt`): a brief lands once.
    @ObservationIgnored var remoraLanded: Date?

    public init() {}

    // MARK: Storage

    /// Opens the file next to the catalog and takes what it holds: every draft with text, the presets and the defaults. Each
    /// project shows its newest draft until another is picked. Idempotent; a missing or unreadable file reads as empty.
    func attach(store: NewSessionStore) {
        guard self.store == nil else { return }
        self.store = store
        store.draftsSnapshot = { [weak self] in self?.visibleDrafts.map(StoredDraft.init) ?? [] }
        store.onFailureChange = { [weak self] error in self?.setSaveFailure(error) }
        storeNotice = store.loadNotice
        for draft in store.file.drafts.map(\.draft).sorted(by: { $0.updatedAt > $1.updatedAt })
        where draft.isVisible && drafts[draft.id] == nil {
            drafts[draft.id] = draft
            if current[draft.projectKey] == nil { current[draft.projectKey] = draft.id }
        }
        presets = store.file.presets
        settings = store.file.settings
    }

    /// Writes what is pending now (a send, a blur, Quit).
    public func flush() { store?.flush() }

    private func setSaveFailure(_ error: (any Error)?) {
        guard let error else {
            storeNotice = store?.loadNotice
            return
        }
        storeNotice = "This draft could not be saved (\(error.localizedDescription)). "
            + "What you typed is still here, but it may be gone after a restart."
    }

    func setSettings(_ value: NewSessionSettings) {
        guard value != settings else { return }
        settings = value
        store?.change { $0.settings = value }
    }

    // MARK: Drafts

    /// The drafts with text, newest first: what the sidebar lists (with Discard), and the order of the file.
    public var visibleDrafts: [SessionDraft] {
        drafts.values.filter(\.isVisible).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The id of the draft the project shows, nil until one was opened or typed in.
    public func currentID(for projectID: UUID?) -> UUID? {
        current[SessionDraft.projectKey(for: projectID)].flatMap { drafts[$0] == nil ? nil : $0 }
    }

    /// The draft the project shows, nil until one was opened or typed in.
    public func draft(for projectID: UUID?) -> SessionDraft? { currentID(for: projectID).flatMap { drafts[$0] } }

    public func draft(id: UUID) -> SessionDraft? { drafts[id] }

    /// Opens the project's draft: the one it shows, else an empty one (in memory only).
    func open(projectID: UUID?) {
        if currentID(for: projectID) == nil { makeCurrent(SessionDraft(projectID: projectID, updatedAt: clock())) }
    }

    /// Makes one of a project's drafts the one it shows.
    func show(id: UUID) {
        if let draft = drafts[id] { current[draft.projectKey] = id }
    }

    /// Puts a draft in and makes it the one its project shows.
    private func makeCurrent(_ draft: SessionDraft) {
        drafts[draft.id] = draft
        current[draft.projectKey] = draft.id
    }

    /// The project's draft to edit: the one it shows, else a new empty one (not yet put in).
    private func editable(_ projectID: UUID?) -> SessionDraft {
        draft(for: projectID) ?? SessionDraft(projectID: projectID, updatedAt: clock())
    }

    func setFullAccessConfirmed(_ confirmed: Bool, for projectID: UUID?) {
        guard let id = currentID(for: projectID) else { return }
        if confirmed { fullAccessConfirmed.insert(id) } else { fullAccessConfirmed.remove(id) }
    }

    func isFullAccessConfirmed(for projectID: UUID?) -> Bool { currentID(for: projectID).map(fullAccessConfirmed.contains) ?? false }

    /// The remora origin of the draft the project shows.
    func remoraOrigin(for projectID: UUID?) -> DraftRemoraOrigin? { currentID(for: projectID).flatMap { remoraOrigins[$0] } }

    func update(_ projectID: UUID?, touching: Bool = true, _ edit: (inout SessionDraft) -> Void) {
        var draft = editable(projectID)
        let before = draft
        let isNew = drafts[draft.id] == nil
        edit(&draft)
        guard draft != before || isNew else { return }
        if touching { draft.updatedAt = clock() }
        makeCurrent(draft)
        persistDrafts()
    }

    /// The text of a draft, typed or pasted: the one edit that happens on every keystroke, so it makes no
    /// comparison of whole drafts and builds nothing for the file (that happens when the save is due).
    func setText(_ text: String, for projectID: UUID?) {
        var draft = editable(projectID)
        draft.text = text
        draft.updatedAt = clock()
        makeCurrent(draft)
        // An emptied draft holds no brief of Remora's any more.
        if !draft.hasText { remoraOrigins[draft.id] = nil }
        persistDrafts()
    }

    /// Throws the project's shown draft away: the project shows an empty one, and the file forgets it.
    public func discard(projectID: UUID?) {
        if let id = currentID(for: projectID) { discard(id: id) } else { open(projectID: projectID) }
    }

    /// Throws one draft away; the project's other drafts stay. When it was the one its project shows, an empty one takes its
    /// place.
    public func discard(id: UUID) {
        guard let draft = drafts[id] else { return }
        let wasCurrent = current[draft.projectKey] == id
        forget(id)
        if wasCurrent { makeCurrent(SessionDraft(projectID: draft.projectID, updatedAt: clock())) }
        persistDrafts()
    }

    /// Takes a draft out with what was kept beside it.
    private func forget(_ id: UUID) {
        drafts[id] = nil
        fullAccessConfirmed.remove(id)
        remoraOrigins[id] = nil
        remoraStartedAt[id] = nil
    }

    /// Moves a draft to another project when the draft that project shows is empty (picking another project in the question
    /// carries what was typed); a project whose draft has text of its own shows it as it is.
    func move(from old: UUID?, to new: UUID?) {
        guard old != new, var moved = draft(for: old), moved.isVisible, !(draft(for: new)?.isVisible ?? false) else { return }
        // The empty draft the other project showed gives way to the one that moves in.
        if let empty = currentID(for: new), !sending.contains(empty) { forget(empty) }
        moved.projectID = new
        moved.updatedAt = clock()
        makeCurrent(moved)
        makeCurrent(SessionDraft(projectID: old, updatedAt: clock()))
        // Remora's brief was about the old project: the moved text is no longer its draft there or here.
        remoraOrigins[moved.id] = nil
        persistDrafts()
    }

    /// The drafts changed: the file takes them when the save is due (`NewSessionStore.draftsSnapshot`), not now.
    private func persistDrafts() { store?.draftsChanged() }

    // MARK: A send

    func beginSending(draft id: UUID) { sending.insert(id) }
    func endSending(draft id: UUID) { sending.remove(id) }
    func isSending(draft id: UUID) -> Bool { sending.contains(id) }
    /// Whether the draft the project shows is being sent.
    func isSending(_ projectID: UUID?) -> Bool { currentID(for: projectID).map(sending.contains) ?? false }

    /// Takes a draft out for a send that leaves the window on a fresh draft of its project (⌘↵).
    func handOver(draft id: UUID) -> SessionDraft? {
        guard let draft = drafts[id] else { return nil }
        let wasCurrent = current[draft.projectKey] == id
        drafts[id] = nil
        remoraOrigins[id] = nil
        if wasCurrent { makeCurrent(SessionDraft(projectID: draft.projectID, updatedAt: clock())) }
        persistDrafts()
        return draft
    }

    /// A start that failed gives a handed-over draft back: as the project's shown draft when that is empty, else in front of
    /// what was typed meanwhile. Nothing the user wrote is lost.
    func restore(_ draft: SessionDraft) {
        guard let current = self.draft(for: draft.projectID), current.isVisible else {
            if let empty = currentID(for: draft.projectID) { forget(empty) }
            makeCurrent(draft)
            persistDrafts()
            return
        }
        var merged = current
        merged.text = draft.text + "\n\n" + current.text
        merged.updatedAt = clock()
        drafts[merged.id] = merged
        persistDrafts()
    }

    /// The session started: a draft that stayed in (↵) is cleared. The project remembers what it was started with in the
    /// catalog (the runtime records it when the card is made); the next draft shows it at once, and the catalog's own record
    /// replaces this copy when it is read (`CatalogModel.refreshLastUsedChoices`).
    func started(_ draft: SessionDraft, choices: ClaudeLaunchChoices, clearsSlot: Bool) {
        if clearsSlot { discard(id: draft.id) }
        endSending(draft: draft.id)
        let key = draft.projectKey
        let updated = choices.remembered(over: lastUsedChoices[key])
        if !updated.isEmpty, updated != lastUsedChoices[key] { lastUsedChoices[key] = updated }
        store?.flush()
    }

    /// The catalog's record wins for a project it has one for; a start's optimistic copy stays for one it does not have yet.
    func setLastUsedChoices(_ all: [String: ClaudeLaunchChoices]) {
        let merged = lastUsedChoices.merging(all) { _, catalog in catalog }
        if merged != lastUsedChoices { lastUsedChoices = merged }
    }

    func lastUsed(for projectID: UUID?) -> ClaudeLaunchChoices? { lastUsedChoices[SessionDraft.projectKey(for: projectID)] }

    /// What the older new-session file remembered: every launch (newest wins) and each project's last used choices, for the
    /// one-time copy into the catalog (`ConversationController.begin`). Nothing writes either list any more.
    public func legacyLaunchRecords() -> (launched: [UUID: ClaudeLaunchChoices], lastUsed: [String: ClaudeLaunchChoices]) {
        var choices: [UUID: ClaudeLaunchChoices] = [:]
        for entry in store?.file.launched ?? [] { choices[entry.sessionID] = entry.choices }
        return (choices, store?.file.lastUsed ?? [:])
    }

    // MARK: Branch facts

    func setBranch(_ branch: GitBranch, for projectID: UUID) {
        if branches[projectID.uuidString] != branch { branches[projectID.uuidString] = branch }
    }

    func branch(for projectID: UUID?) -> GitBranch? { projectID.flatMap { branches[$0.uuidString] } }

    // MARK: Presets

    func addPreset(_ preset: NewSessionPreset) {
        presets.append(preset)
        store?.change { $0.presets = presets }
    }

    func removePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        store?.change { $0.presets = presets }
    }

    /// The presets a project's draft offers: its own, then those for every project.
    func presets(for projectID: UUID?) -> [NewSessionPreset] {
        presets.filter { $0.projectID == projectID } + presets.filter { $0.projectID == nil && projectID != nil }
    }
}

// MARK: - The model

extension CatalogModel {
    /// Shows a project's draft (`nil`: a draft with no project). Opening costs nothing: an empty draft is
    /// in memory only, and one with text comes back as it was.
    public func showDraft(projectID: UUID?) {
        prepareNewSession()
        newSession.open(projectID: projectID)
        navigate(to: .draft(projectID: projectID))
        loadDraftBranch(projectID: projectID)
    }

    /// "New Session" (⌘N, the menu bar item): the draft of the project the window is in. Nothing starts
    /// until its first send.
    public func beginNewSession(projectID: UUID?) { showDraft(projectID: projectID) }

    /// Opens the new-session file beside the catalog once; with no catalog the drafts stay in memory. The
    /// sidebar calls it before it lists `newSession.visibleDrafts` (one small read, nothing when the file is absent).
    /// Reads what each project's next draft starts with from the catalog, which records a start and every live change of mode,
    /// model or effort (`SessionCatalog.recordLaunchChoices`). Asked at start, after a start and after a live change.
    func refreshLastUsedChoices() {
        guard let catalog else { return }
        Task { [weak self] in
            guard let all = try? await catalog.lastUsedLaunchChoices() else { return }
            self?.newSession.setLastUsedChoices(all)
        }
    }

    public func prepareNewSession() {
        guard newSession.store == nil, let catalog else { return }
        newSession.attach(store: NewSessionStore(url: catalog.dataRoot.appendingPathComponent("new-session.json")))
    }

    /// The drafts the sidebar lists: with text, in a project that still exists.
    public var visibleDrafts: [SessionDraft] {
        newSession.visibleDrafts.filter { draft in draft.projectID.map { id in projects.contains { $0.id == id } } ?? true }
    }

    func draftProject(_ projectID: UUID?) -> CatalogProject? {
        projectID.flatMap { id in projects.first { $0.id == id } }
    }

    // MARK: Editing

    /// A keystroke: stores the text and nothing more. The file is written after a pause (`NewSessionStore`), so the
    /// cost of a keystroke does not grow with the text.
    public func setDraftText(_ text: String, projectID: UUID?) {
        guard newSession.draft(for: projectID)?.text != text else { return }
        newSession.setText(text, for: projectID)
    }

    func setDraftMode(_ pick: DraftPick, projectID: UUID?) {
        newSession.update(projectID) { $0.modePick = pick }
        // Only a pick made now, in this window, is a decision seen on screen.
        newSession.setFullAccessConfirmed(pick == .value(ClaudePermissionMode.fullAccess.rawValue), for: projectID)
    }

    /// The draft would start in Full access because of a pick kept from earlier (a draft saved before a relaunch,
    /// or a preset), not one made in this window: the mode chip says so.
    public func draftKeepsFullAccess(projectID: UUID?) -> Bool {
        let resolved = resolvedStart(for: projectID).mode
        return resolved.value == ClaudePermissionMode.fullAccess.rawValue && resolved.source == .pick
            && !newSession.isFullAccessConfirmed(for: projectID)
    }
    /// Development evidence: the strip's choice by name (`stay`, `newBranch`, `newWorktree`) with an optional name.
    public func setDraftBranchForEvidence(_ kind: String, name: String?, projectID: UUID?) {
        guard let kind = BranchKind(rawValue: kind) else { return }
        setDraftBranch(kind, name: name, projectID: projectID)
    }

    func setDraftModel(_ pick: DraftPick, projectID: UUID?) { newSession.update(projectID) { $0.modelPick = pick } }

    func setDraftEffort(_ pick: DraftPick, projectID: UUID?) { newSession.update(projectID) { $0.effortPick = pick } }

    func setDraftBranch(_ kind: BranchKind, name: String? = nil, projectID: UUID?) {
        newSession.update(projectID) {
            $0.branchKind = kind
            if let name { $0.branchName = name.isEmpty ? nil : name }
        }
    }

    public func discardDraft(projectID: UUID?) { newSession.discard(projectID: projectID) }

    /// Another project in the question: the draft follows when the other project's draft is empty.
    func chooseDraftProject(_ new: UUID?, from old: UUID?) {
        guard new != old else { return }
        newSession.move(from: old, to: new)
        showDraft(projectID: new)
    }

    // MARK: Defaults

    /// What the draft would start with now, and where each value comes from.
    func resolvedStart(for projectID: UUID?) -> ResolvedStart {
        resolvedStart(draft: newSession.draft(for: projectID), projectID: projectID)
    }

    func resolvedStart(draft: SessionDraft?, projectID: UUID?) -> ResolvedStart {
        NewSessionDefaults.resolve(
            modePick: draft?.modePick ?? .inherit, modelPick: draft?.modelPick ?? .inherit,
            effortPick: draft?.effortPick ?? .inherit,
            lastUsed: newSession.lastUsed(for: projectID), settings: newSession.settings, askAllowed: newSessionAllowsAsk)
    }

    /// Development evidence: the choices a new session of this project would start with, resolved as the draft resolves them (a
    /// project with no remembered mode starts with the explicit `default`).
    public func draftStartChoices(projectID: UUID?) -> ClaudeLaunchChoices { resolvedStart(for: projectID).choices }

    /// Whether a new session starts in the face that has Ask: Ask is a Chat mode (D-63), and the terminal never runs it. The
    /// one place that says which face a new session starts in for the mode menu: Settings → "Sessions run in" (V19, D-69).
    var newSessionStartsInChat: Bool { newSessionFace == .chat }

    var newSessionAllowsAsk: Bool { newSessionStartsInChat }

    /// Settings → General → Mode of new sessions (D-69): nil is "Last used in the project", else the one fixed mode.
    public var defaultStartMode: String? { newSession.settings.permissionMode }

    /// Sets the mode new sessions start in (nil: the project's last used mode). Full access is allowed because the user
    /// picks it here, but it asks first: switching to it without `confirmedFullAccess` changes nothing and returns
    /// false. Choosing it again while it is the default asks nothing. A mode the menus do not offer is refused.
    @discardableResult
    public func setDefaultStartMode(_ raw: String?, confirmedFullAccess: Bool = false) -> Bool {
        if let raw, !ClaudePermissionMode.isOffered(raw) { return false }
        if raw == ClaudePermissionMode.fullAccess.rawValue, defaultStartMode != raw, !confirmedFullAccess { return false }
        setNewSessionDefaults(permissionMode: raw, model: newSession.settings.model)
        return true
    }

    /// Loom's own start defaults. Nil clears one. A mode that could pass for an option is not stored.
    public func setNewSessionDefaults(permissionMode: String?, model: String?) {
        prepareNewSession()
        newSession.setSettings(NewSessionSettings(
            permissionMode: permissionMode.flatMap { ClaudeLaunchChoices.isSafeToken($0) ? $0 : nil },
            model: model.flatMap { ClaudeLaunchChoices.isSafeToken($0) ? $0 : nil }))
    }

    // MARK: Branch

    /// Reads the project folder's branch for the strip (`.git/HEAD`, a few small file reads, no process).
    func loadDraftBranch(projectID: UUID?) {
        guard let project = draftProject(projectID) else { return }
        let id = project.id, path = project.path
        Task { [weak self] in
            let branch = await Task.detached(priority: .utility) { GitBranch.read(directory: path) }.value
            self?.newSession.setBranch(branch, for: id)
        }
    }

    /// The branch the strip would create: the typed name, else one made from the first words.
    func draftBranchName(_ draft: SessionDraft) -> String {
        draft.branchName ?? NewSessionBranchNames.suggest(text: draft.text)
    }

    // MARK: Send

    /// Why ↵ would not start a draft that has text, when the text itself is the reason: a first message that is
    /// too long to be one argument of the process. Checked before any git step.
    public func draftSendBlock(projectID: UUID?) -> String? {
        // The trimmed text is never longer than the text, so the common case needs no trimming: this is asked on
        // every redraw of the draft.
        guard let draft = newSession.draft(for: projectID),
              draft.text.utf8.count > NewSessionLaunch.maxFirstMessageBytes,
              draft.trimmedText.utf8.count > NewSessionLaunch.maxFirstMessageBytes else { return nil }
        return "This message is too long to start a session with (the limit is "
            + "\(NewSessionLaunch.maxFirstMessageBytes / 1024) KB). Shorten it, or keep the long part in a file and name it here."
    }

    /// Whether ↵ would start the draft now.
    public func canSendDraft(projectID: UUID?) -> Bool {
        guard draftSendBlock(projectID: projectID) == nil, actionsAvailable, capabilities(of: .claude).startable, !isStarting(.claude, projectID: projectID),
              let draft = newSession.draft(for: projectID), draft.isVisible, !newSession.isSending(draft: draft.id),
              intents is any NewSessionIntents else { return false }
        if draft.branchKind != .stay {
            guard draftProject(projectID) != nil, newSession.branch(for: projectID).map({ $0 != .unavailable }) ?? true,
                  NewSessionBranchNames.isPlausible(draftBranchName(draft))
            else { return false }
        }
        return true
    }

    /// ↵ starts the session with the draft's text as its first message; ⌘↵ (`startsFreshDraft`) does the same
    /// and leaves the window on a fresh draft of the project. The draft is cleared only when the session
    /// started: a start that fails keeps every word.
    public func sendDraft(projectID: UUID?, startsFreshDraft: Bool = false) {
        guard canSendDraft(projectID: projectID), let intents = intents as? any NewSessionIntents,
              let snapshot = newSession.draft(for: projectID) else { return }
        newSession.beginSending(draft: snapshot.id)
        let launch = self.launch(for: snapshot)
        let draft: SessionDraft
        if startsFreshDraft {
            guard let handed = newSession.handOver(draft: snapshot.id) else { newSession.endSending(draft: snapshot.id); return }
            draft = handed
            newSession.endSending(draft: snapshot.id)
        } else {
            draft = snapshot
        }
        intents.startSession(
            projectID: projectID, launch: launch, focus: startsFreshDraft ? .freshDraft : .session
        ) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .started:
                self.newSession.started(draft, choices: launch.choices, clearsSlot: !startsFreshDraft)
                self.refreshLastUsedChoices()
                if let projectID, self.projects.first(where: { $0.id == projectID })?.collapsed == true {
                    Task { [weak self] in await self?.expandProject(projectID) }
                }
            case .failed:
                if startsFreshDraft { self.newSession.restore(draft) } else { self.newSession.endSending(draft: draft.id) }
            }
        }
    }

    /// The first send as the runtime takes it: the message, the resolved mode and model and the strip's branch
    /// choice. A draft is never titled by Loom: Claude names the session.
    func launch(for draft: SessionDraft) -> NewSessionLaunch {
        let workspace: SessionWorkspace
        switch draft.branchKind {
        case .stay: workspace = .projectFolder
        case .newBranch: workspace = .newBranch(draftBranchName(draft))
        case .newWorktree: workspace = .newWorktree(draftBranchName(draft))
        }
        return NewSessionLaunch(
            firstMessage: draft.trimmedText,
            choices: resolvedStart(draft: draft, projectID: draft.projectID).choices, workspace: workspace)
    }

    // MARK: Presets

    func presets(for projectID: UUID?) -> [NewSessionPreset] { newSession.presets(for: projectID) }

    /// "Save as preset": the draft's text with its mode and model, named from its first line, for this project.
    func savePreset(projectID: UUID?) {
        guard let draft = newSession.draft(for: projectID), draft.isVisible else { return }
        let resolved = resolvedStart(for: projectID)
        let line = draft.trimmedText.split(whereSeparator: \.isNewline).first.map(String.init) ?? draft.trimmedText
        let name = line.count > 40 ? String(line.prefix(39)) + "…" : line
        newSession.addPreset(NewSessionPreset(
            name: name, message: draft.trimmedText, permissionMode: resolved.mode.value, model: resolved.model.value,
            projectID: projectID))
    }

    /// One click: the preset's message goes into the draft (after what is there, if anything) and its mode and
    /// model are picked. Nothing starts; the user sends.
    func applyPreset(_ preset: NewSessionPreset, projectID: UUID?) {
        newSession.update(projectID) { draft in
            if !preset.message.isEmpty {
                draft.text = draft.isVisible ? draft.text + "\n\n" + preset.message : preset.message
            }
            if let mode = preset.permissionMode { draft.modePick = .value(mode) }
            if let model = preset.model { draft.modelPick = .value(model) }
        }
        // A preset's mode is a pick kept from earlier, even when it was just clicked.
        newSession.setFullAccessConfirmed(false, for: projectID)
    }

    func removePreset(_ preset: NewSessionPreset) { newSession.removePreset(preset.id) }
}
