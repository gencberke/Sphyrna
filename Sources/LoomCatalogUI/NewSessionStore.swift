import Foundation
import LoomCore

/// A draft with text as it is kept on disk. An empty draft is never written.
struct StoredDraft: Equatable, Codable {
    var projectID: UUID?
    var text: String
    var modePick: DraftPick
    var modelPick: DraftPick
    var branchKind: BranchKind
    var branchName: String?
    var updatedAt: Date

    init(_ draft: SessionDraft) {
        projectID = draft.projectID
        text = draft.text
        modePick = draft.modePick
        modelPick = draft.modelPick
        branchKind = draft.branchKind
        branchName = draft.branchName
        updatedAt = draft.updatedAt
    }

    var draft: SessionDraft {
        var value = SessionDraft(projectID: projectID, text: text, updatedAt: updatedAt)
        value.modePick = modePick
        value.modelPick = modelPick
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
/// presets, the start defaults of Loom's settings, and the modes and models of the sessions Loom started
/// from a draft (the newest `maxLaunched`).
struct NewSessionFile: Equatable, Codable {
    static let maxLaunched = 300

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
/// disk; a draft that was never typed in never makes a write.
@MainActor
final class NewSessionStore {
    let url: URL
    private(set) var file: NewSessionFile
    private var lastSaved: NewSessionFile
    private var saveTask: Task<Void, Never>?
    /// Successful writes (tests and evidence).
    private(set) var writeCount = 0
    /// The last write failure, for the model to report.
    private(set) var lastFailure: (any Error)?
    var delay: Duration = .milliseconds(300)

    init(url: URL) {
        self.url = url
        // A missing or unreadable file reads as empty and counts as saved: nothing is written until something changes.
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.newSession.decode(NewSessionFile.self, from: $0) }
        file = loaded ?? NewSessionFile()
        lastSaved = file
    }

    deinit { saveTask?.cancel() }

    func change(_ edit: (inout NewSessionFile) -> Void) {
        edit(&file)
        file.launched = Array(file.launched.suffix(NewSessionFile.maxLaunched))
        scheduleSave()
    }

    func scheduleSave() {
        guard file != lastSaved else { return }
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
