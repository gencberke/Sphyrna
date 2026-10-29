import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
@testable import LoomRemora
import LoomTestSupport
@testable import LoomCatalogUITestRigs

private typealias DropFolder = ComposerFileDropShared.DropFolder

// W3-d: files and folders dropped into every composer (the live Chat one, the draft page's, Side's and Quick Question's) and
// anywhere on the live stream or the draft page. A drop only edits a composer; nothing here sends.

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ComposerFileDropTests {
    // MARK: The three text-only composers

    @Test func sideTakesAFileAndAFolderRelativeToTheParentSessionsFolder() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 1, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let project = rig.projects[0]
        let parent = try #require(rig.ids[project.id]?.first)
        let folder = URL(fileURLWithPath: project.path)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("notes.md"))
        let session = rig.model.side.session(for: parent)
        session.composerText = "why"
        let host = SideComposerEditorHost(model: rig.model, parent: parent)
        let board = ComposerFileDropShared.pasteboard([folder.appendingPathComponent("notes.md"), folder.appendingPathComponent("src", isDirectory: true)])
        defer { board.releaseGlobally() }
        #expect(host.drop(board))
        #expect(session.composerText == "why @notes.md @src/ ")
    }

    @Test func quickQuestionTakesAFileAndAFolderRelativeToItsSessionsFolder() throws {
        let place = try DropFolder()
        defer { place.remove() }
        let panel = QuickQuestionPanel { _ in "" }
        let host = QuickQuestionEditorHost(panel: panel, workingDirectory: place.root.path)
        let board = ComposerFileDropShared.pasteboard([place.file, place.spaced])
        defer { board.releaseGlobally() }
        #expect(host.drop(board))
        #expect(panel.text == "@notes.md @\"my docs/\" ")

        // Without a folder the paths stay absolute; at the caret of the field when it is there, and the field takes the keyboard.
        let bare = QuickQuestionEditorHost(panel: panel)
        let field = ComposerTextEditor.ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        let editor = ComposerTextEditor(host: bare, height: .constant(60))
        let coordinator = editor.makeCoordinator()
        field.coordinator = coordinator
        field.delegate = coordinator
        coordinator.textView = field
        bare.editorAttached(field)
        let folderOnly = ComposerFileDropShared.pasteboard([place.folder])
        defer { folderOnly.releaseGlobally() }
        #expect(bare.drop(folderOnly))
        #expect(field.string == "@\(place.folder.standardizedFileURL.path)/ ")
        withExtendedLifetime(coordinator) {}
    }
}

/// The live Chat composer: a drop on its stream lands in it, as on its field.
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(4)))
struct ComposerPaneDropTests {
    @Test func filesDroppedOnTheStreamLandInTheSessionsComposerWhichTakesTheKeyboard() async throws {
        let place = try DropFolder()
        defer { place.remove() }
        let rig = try await LiveRig.make()
        let id = UUID()
        let host = ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root, driverForgotten: { _ in })
        var environment = ComposerEnvironment()
        environment.workingDirectory = { place.root.path }
        let composer = ChatComposerModel(driver: host.driver(for: id), card: id, drafts: host.draftStore, environment: environment)
        await composer.attachmentsRestored()
        let editor = FakeComposerEditor(model: composer)
        editor.type("see ")
        // The stream's drop target hands the drag pasteboard to this handler.
        let drop = ComposerPaneDrop { composer.dropOnPane($0) }
        let board = ComposerFileDropShared.pasteboard([place.file, place.folder])
        defer { board.releaseGlobally() }
        let focused = editor.focusCount
        #expect(drop.land(board))
        #expect(editor.text == "see @notes.md @src/ ")
        #expect(editor.focusCount > focused, "the composer takes the keyboard after the drop")

        // Text dropped on the stream is not a file: nothing lands.
        let text = NSPasteboard(name: NSPasteboard.Name("loom-drop-test-\(UUID())"))
        defer { text.releaseGlobally() }
        text.clearContents()
        text.setString("plain words", forType: .string)
        #expect(!drop.land(text))
        #expect(editor.text == "see @notes.md @src/ ")
        await rig.finish()
    }
}
