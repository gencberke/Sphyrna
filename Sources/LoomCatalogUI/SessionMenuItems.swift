import AppKit
import LoomCore
import SwiftUI

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

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Reveal in Finder, Copy Claude Session ID and Copy Resume Command: the group before the delete group in
/// the card's context menu and the detail header's actions menu. It starts with its own divider.
struct SessionLocationMenuItems: View {
    let row: SessionRowModel

    var body: some View {
        Divider()
        let directory = row.record.session.workingDirectory
        Button("Reveal in Finder") { SessionLocationActions.reveal(directory) }
            .disabled(!SessionLocationActions.directoryExists(directory))
        Button("Copy Claude Session ID") {
            if let id = row.claudeSessionID { SessionLocationActions.copy(id) }
        }
        .disabled(row.claudeSessionID == nil)
        Button("Copy Resume Command") {
            if let command = row.resumeCommand { SessionLocationActions.copy(command) }
        }
        .disabled(row.resumeCommand == nil)
    }
}
