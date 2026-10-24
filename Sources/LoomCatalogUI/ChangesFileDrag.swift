import AppKit
import SwiftUI

/// A changed file dragged out of the Changes tab (W3-e): only text, the composer's own `@path` mention of the file
/// (`ComposerPasteboard.mention`, relative to the session's folder as a file drop on the composer makes it). A Chat composer
/// inserts that text; Finder or a terminal take it as text. It never offers the file's URL or the file itself, so no drop can
/// move or copy a file out of the user's project. A file that is not on disk any more offers no drag.
enum ChangesFileDrag {
    static func provider(for file: ChangesFile, folder: String?,
                         exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> NSItemProvider? {
        guard exists(file.absolutePath) else { return nil }
        let mention = ComposerPasteboard.mention(for: URL(fileURLWithPath: file.absolutePath), relativeTo: folder)
        return NSItemProvider(object: mention as NSString)
    }
}

/// Makes a file's row a drag source. The drag starts past the system's threshold, so a click on the row stays a click. A deleted
/// file (known from its status, no disk read here) adds no drag at all; one that vanished since is found when the drag starts
/// (`ChangesFileDrag.provider`) and offers nothing.
struct ChangesFileDragSource: ViewModifier {
    let model: CatalogModel
    let sessionID: UUID
    let file: ChangesFile

    @ViewBuilder func body(content: Content) -> some View {
        if file.status != .deleted {
            content.onDrag {
                let folder = (model.rowModels[sessionID]?.record ?? model.liveRecords[sessionID])?.session.workingDirectory
                return ChangesFileDrag.provider(for: file, folder: folder) ?? NSItemProvider()
            }
        } else {
            content
        }
    }
}
