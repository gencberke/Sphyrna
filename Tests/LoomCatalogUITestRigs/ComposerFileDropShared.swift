import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
@testable import LoomRemora
import LoomTestSupport

/// What both halves of `ComposerFileDropTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum ComposerFileDropShared {
    /// A temporary folder with a file, a folder and a folder whose name has a space, and a file outside it.
    struct DropFolder {
        let root: URL
        let outside: URL
        var file: URL { root.appendingPathComponent("notes.md") }
        var folder: URL { root.appendingPathComponent("src", isDirectory: true) }
        var spaced: URL { root.appendingPathComponent("my docs", isDirectory: true) }
        var image: URL { root.appendingPathComponent("shot.png") }

        init() throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("loom-r5-drop-\(UUID())", isDirectory: true)
            root = base.appendingPathComponent("work", isDirectory: true)
            outside = base.appendingPathComponent("elsewhere", isDirectory: true)
            for directory in [root, outside, root.appendingPathComponent("src"), root.appendingPathComponent("my docs")] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try Data("x".utf8).write(to: root.appendingPathComponent("notes.md"))
            try Data("not really a png".utf8).write(to: root.appendingPathComponent("shot.png"))
        }

        func remove() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    @MainActor
    static func pasteboard(_ urls: [URL]) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("loom-drop-test-\(UUID())"))
        board.clearContents()
        board.writeObjects(urls.map { $0 as NSURL })
        return board
    }
}
