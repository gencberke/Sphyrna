import Foundation
import LoomCore

/// A draft with text as it is kept on disk. An empty draft is never written.
struct StoredDraft: Equatable, Codable {
    var projectID: UUID?
    var text: String
    var modePick: DraftPick
    var modelPick: DraftPick
    /// Absent in a file written before the effort slider (D-63): nothing chosen.
    var effortPick: DraftPick?
    var branchKind: BranchKind
    var branchName: String?
    var updatedAt: Date

    init(_ draft: SessionDraft) {
        projectID = draft.projectID
        text = draft.text
        modePick = draft.modePick
        modelPick = draft.modelPick
        effortPick = draft.effortPick
        branchKind = draft.branchKind
        branchName = draft.branchName
        updatedAt = draft.updatedAt
    }

    var draft: SessionDraft {
        var value = SessionDraft(projectID: projectID, text: text, updatedAt: updatedAt)
        value.modePick = modePick
        value.modelPick = modelPick
        value.effortPick = effortPick ?? .inherit
        value.branchKind = branchKind
        value.branchName = branchName
        return value
    }
}

/// The mode and model Loom started a session with (S2: the CLI restores neither, so a resume passes them).
struct LaunchedSession: Equatable, Codable {
    var sessionID: UUID
    var choices: ClaudeLaunchChoices
}

/// The whole file: `<data root>/new-session.json`. Drafts with text, what was last used per project, the
/// presets, and the start defaults of Loom's settings. `lastUsed` and `launched` are what older builds kept per project and
/// per session: nothing writes them now (the catalog records both), and they are read once for the copy into the catalog.
struct NewSessionFile: Equatable, Codable {
    var drafts: [StoredDraft] = []
    /// Keyed by the project id (`SessionDraft.id(for:)`).
    var lastUsed: [String: ClaudeLaunchChoices] = [:]
    var presets: [NewSessionPreset] = []
    var settings = NewSessionSettings()
    var launched: [LaunchedSession] = []

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown or missing keys, and one unreadable entry, fall back to empty.
        drafts = ((try? container.decodeIfPresent([Lossy<StoredDraft>].self, forKey: .drafts)) ?? nil)?
            .compactMap(\.value) ?? []
        lastUsed = (try? container.decodeIfPresent([String: ClaudeLaunchChoices].self, forKey: .lastUsed)) ?? [:]
        presets = ((try? container.decodeIfPresent([Lossy<NewSessionPreset>].self, forKey: .presets)) ?? nil)?
            .compactMap(\.value) ?? []
        settings = (try? container.decodeIfPresent(NewSessionSettings.self, forKey: .settings)) ?? NewSessionSettings()
        launched = ((try? container.decodeIfPresent([Lossy<LaunchedSession>].self, forKey: .launched)) ?? nil)?
            .compactMap(\.value) ?? []
    }

    private enum CodingKeys: String, CodingKey { case drafts, lastUsed, presets, settings, launched }

    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
    }
}

/// Reads and writes the new-session file. Written atomically after `delay` of quiet (CHAT-SPEC: 300 ms after
/// the last change), on `flush()` (a send, a blur, Quit), and only when the content differs from what is on
/// disk; a draft that was never typed in never makes a write. The drafts are not copied into `file` per change:
/// a change to them only marks them (`draftsChanged()`), and the saved form is built from the live drafts when
/// the write is due (`draftsSnapshot`), so typing in a long draft costs the same as typing in a short one.
@MainActor
final class NewSessionStore {
    let url: URL
    private(set) var file: NewSessionFile
    private var lastSaved: NewSessionFile
    private var saveTask: Task<Void, Never>?
    private var draftsDirty = false
    /// Successful writes (tests and evidence).
    private(set) var writeCount = 0
    /// How often the saved form of the drafts was built (tests): once per write that is due, never per change.
    private(set) var snapshotsBuilt = 0
    /// The last write failure, for the model to report.
    private(set) var lastFailure: (any Error)? {
        didSet { if oldValue != nil || lastFailure != nil { onFailureChange?(lastFailure) } }
    }
    /// Set when an unreadable file was moved aside at load time.
    private(set) var loadNotice: String?
    var delay: Duration = .milliseconds(300)
    /// Called when a write fails and again when the next one succeeds.
    var onFailureChange: (((any Error)?) -> Void)?
    /// The drafts with text in their saved form, asked for when a write is due.
    var draftsSnapshot: (() -> [StoredDraft])?

    init(url: URL) {
        self.url = url
        var loaded: NewSessionFile?
        if FileManager.default.fileExists(atPath: url.path) {
            loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.newSession.decode(NewSessionFile.self, from: $0) }
            // A file that cannot be read is kept, not replaced: the next change would otherwise overwrite what
            // the user may still be able to recover by hand.
            if loaded == nil { loadNotice = Self.moveAside(url) }
        }
        // A missing file reads as empty and counts as saved: nothing is written until something changes.
        file = loaded ?? NewSessionFile()
        lastSaved = file
    }

    deinit { saveTask?.cancel() }

    private static func moveAside(_ url: URL) -> String {
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("new-session.unreadable-\(Int(Date().timeIntervalSince1970)).json")
        if (try? FileManager.default.moveItem(at: url, to: aside)) != nil {
            return "Your saved drafts could not be read. The old file was kept as \(aside.lastPathComponent)."
        }
        return "Your saved drafts could not be read, and the file could not be moved aside."
    }

    func change(_ edit: (inout NewSessionFile) -> Void) {
        edit(&file)
        scheduleSave()
    }

    /// The live drafts changed: they are read when the write is due, not now.
    func draftsChanged() {
        draftsDirty = true
        scheduleSave()
    }

    func scheduleSave() {
        guard draftsDirty || file != lastSaved else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard let delay = self?.delay else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        if draftsDirty {
            draftsDirty = false
            if let draftsSnapshot {
                snapshotsBuilt += 1
                let drafts = draftsSnapshot()
                if file.drafts != drafts { file.drafts = drafts }
            }
        }
        guard file != lastSaved else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONEncoder.newSession.encode(file).write(to: url, options: .atomic)
            // Drafts and presets hold what the user wrote: the file is the user's alone.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastSaved = file
            lastFailure = nil
            writeCount += 1
        } catch {
            lastFailure = error
        }
    }
}

private extension JSONEncoder {
    static var newSession: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var newSession: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
