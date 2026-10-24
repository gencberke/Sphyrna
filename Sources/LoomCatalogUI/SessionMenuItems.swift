import AppKit
import LoomCore
import SwiftUI
import UniformTypeIdentifiers

/// What the "where is it, how do I get back to it" entries do (D-45).
enum SessionLocationActions {
    /// Whether the folder is there to reveal.
    static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
    }

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The folder in the app macOS opens source code with, the way the Changes tab's "Open in editor" hands a file to the app
    /// macOS opens it with. A folder has no such app of its own (the workspace would show it in Finder), so the source-code
    /// app (or the plain-text one) is asked by name. Returns whether an app was found.
    @discardableResult
    static func openInEditor(_ path: String) -> Bool {
        let workspace = NSWorkspace.shared
        guard let editor = workspace.urlForApplication(toOpen: .sourceCode) ?? workspace.urlForApplication(toOpen: .plainText)
        else { return false }
        workspace.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: editor,
                       configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    static let terminalBundleID = "com.apple.Terminal"

    /// A new Terminal window at the folder: the folder is handed to the Terminal app, no shell command is built.
    @discardableResult
    static func openInTerminal(_ path: String) -> Bool {
        let workspace = NSWorkspace.shared
        guard let terminal = workspace.urlForApplication(withBundleIdentifier: terminalBundleID) else { return false }
        workspace.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: terminal,
                       configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    /// Which of the folder and transcript entries apply to a session. Each needs the folder; the transcript path needs a Claude
    /// session with its conversation id, and a Claude profile to look in.
    struct Availability: Equatable {
        var revealFolder: Bool
        var openFolder: Bool
        var openTerminal: Bool
        var copyTranscriptPath: Bool
    }

    @MainActor static func availability(of row: SessionRowModel, configDirectory: URL?,
                             folderExists: (String) -> Bool = directoryExists) -> Availability {
        let folder = folderExists(row.record.session.workingDirectory)
        return Availability(revealFolder: folder, openFolder: folder, openTerminal: folder,
                            copyTranscriptPath: folder && row.claudeSessionID != nil && configDirectory != nil)
    }

    /// The session's transcript file, found as `sessionMentionText` finds it (`ClaudeTranscriptLocator`), off the main actor: the
    /// lookup may list the profile's project folders.
    @MainActor static func transcriptPath(of row: SessionRowModel, configDirectory: URL) async -> String? {
        guard let id = row.claudeSessionID else { return nil }
        let folder = row.record.session.workingDirectory
        return await Task.detached(priority: .userInitiated) {
            ClaudeTranscriptLocator.locate(sessionID: id, configDirectory: configDirectory, workingDirectory: folder)?.path
        }.value
    }

    /// Copy Transcript Path: the path on the pasteboard, or a beep when the file is not there. Returns what was copied.
    @discardableResult
    @MainActor static func copyTranscriptPath(of row: SessionRowModel, configDirectory: URL,
                                   to pasteboard: NSPasteboard = .general) async -> String? {
        guard let path = await transcriptPath(of: row, configDirectory: configDirectory) else {
            NSSound.beep()
            return nil
        }
        copy(path, to: pasteboard)
        return path
    }
}

/// Reveal in Finder, Open Folder in Editor, Open in Terminal, Copy Claude Session ID, Copy Resume Command and Copy Transcript Path:
/// the group before the delete group in the card's context menu and the detail header's actions menu. It starts with its own
/// divider. Copy Transcript Path needs the model (the Claude profile to look in); without it the item stays disabled.
struct SessionLocationMenuItems: View {
    let row: SessionRowModel
    var model: CatalogModel?

    var body: some View {
        Divider()
        let directory = row.record.session.workingDirectory
        let configDirectory = model?.claudeConfigDirectory
        let available = SessionLocationActions.availability(of: row, configDirectory: configDirectory)
        Button("Reveal in Finder") { SessionLocationActions.reveal(directory) }
            .disabled(!available.revealFolder)
        Button("Open Folder in Editor") { SessionLocationActions.openInEditor(directory) }
            .disabled(!available.openFolder)
        Button("Open in Terminal") { SessionLocationActions.openInTerminal(directory) }
            .disabled(!available.openTerminal)
        Button("Copy Claude Session ID") {
            if let id = row.claudeSessionID { SessionLocationActions.copy(id) }
        }
        .disabled(row.claudeSessionID == nil)
        Button("Copy Resume Command") {
            if let command = row.resumeCommand { SessionLocationActions.copy(command) }
        }
        .disabled(row.resumeCommand == nil)
        Button("Copy Transcript Path") {
            guard let configDirectory else { return }
            Task { await SessionLocationActions.copyTranscriptPath(of: row, configDirectory: configDirectory) }
        }
        .disabled(!available.copyTranscriptPath)
    }
}
