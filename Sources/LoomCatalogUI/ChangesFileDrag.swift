import AppKit
import SwiftUI

/// A changed file dragged out of the Changes tab (W3-e): its absolute URL in the session's folder, and its path as the list shows it
/// as plain text. A Chat composer takes the URL as an `@path` mention (`ComposerPasteboard`: a file URL wins over the text); Finder
/// and other apps take it as any file drag. A file that is not on disk any more offers no drag.
enum ChangesFileDrag {
    static func provider(for file: ChangesFile,
                         exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> NSItemProvider? {
        guard exists(file.absolutePath) else { return nil }
        let url = URL(fileURLWithPath: file.absolutePath)
        let provider = NSItemProvider(object: url as NSURL)
        provider.registerObject(file.displayPath as NSString, visibility: .all)
        provider.suggestedName = url.lastPathComponent
        return provider
    }
}

/// Makes a file's row a drag source. The drag starts past the system's threshold, so a click on the row stays a click; a file that
/// is gone adds no drag at all.
struct ChangesFileDragSource: ViewModifier {
    let file: ChangesFile

    @ViewBuilder func body(content: Content) -> some View {
        if FileManager.default.fileExists(atPath: file.absolutePath) {
            content.onDrag { ChangesFileDrag.provider(for: file) ?? NSItemProvider() }
        } else {
            content
        }
    }
}
