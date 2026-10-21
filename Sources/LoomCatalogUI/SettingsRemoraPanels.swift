import AppKit
import Foundation

/// The memory note's two native panels as the app runs them. Choose… shows a file panel (a folder means `Remora.md` inside it) and Open
/// opens the note in Obsidian where it is installed, else in whatever opens the file. No test calls these: tests replace
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
                var allowed = CharacterSet.urlQueryAllowed
                allowed.remove(charactersIn: "&=+#?")
                if let path = url.path.addingPercentEncoding(withAllowedCharacters: allowed),
                   let obsidian = URL(string: "obsidian://open?path=" + path),
                   NSWorkspace.shared.urlForApplication(toOpen: obsidian) != nil {
                    NSWorkspace.shared.open(obsidian)
                } else {
                    NSWorkspace.shared.open(url)
                }
            })
    }
}
