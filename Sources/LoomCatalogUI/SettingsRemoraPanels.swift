import AppKit
import Foundation

/// The memory note's two native panels as the app runs them. Choose… shows a file panel (a folder means `Remora.md` inside it) and Open
/// opens the note in Obsidian when it sits in a vault and Obsidian is installed, else in whatever opens the file. No test calls these: tests replace
/// `RemoraNoteActions` on the navigation.
extension RemoraNoteActions {
    @MainActor static var live: RemoraNoteActions {
        RemoraNoteActions(
            choose: {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = "Choose"
                panel.message = "Choose the note file, or the folder to keep Remora.md in."
                guard panel.runModal() == .OK, let url = panel.url else { return nil }
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                return RemoraNoteChoice.url(forChosen: url, isDirectory: isDirectory.boolValue)
            },
            open: { url in
                if let obsidian = RemoraNoteChoice.obsidianURL(forNote: url), NSWorkspace.shared.urlForApplication(toOpen: obsidian) != nil {
                    NSWorkspace.shared.open(obsidian)
                } else {
                    NSWorkspace.shared.open(url)
                }
            })
    }
}
