import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
@testable import LoomRemora

// W3-d: files and folders dropped into every composer (the live Chat one, the draft page's, Side's and Quick Question's) and
// anywhere on the live stream or the draft page. A drop only edits a composer; nothing here sends.

/// A temporary folder with a file, a folder and a folder whose name has a space, and a file outside it.
private struct DropFolder {
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
private func pasteboard(_ urls: [URL]) -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name("loom-drop-test-\(UUID())"))
    board.clearContents()
    board.writeObjects(urls.map { $0 as NSURL })
    return board
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ComposerFileDropTests {
    // MARK: Folders

    @Test func aFolderBecomesAtFolderSlashRelativeInsideTheFolderAndAbsoluteOutside() throws {
        let place = try DropFolder()
        defer { place.remove() }
        #expect(ComposerPasteboard.mention(for: place.folder, relativeTo: place.root.path) == "@src/")
        #expect(ComposerPasteboard.mention(for: place.spaced, relativeTo: place.root.path) == "@\"my docs/\"")
        let absolute = place.folder.standardizedFileURL.path
        #expect(ComposerPasteboard.mention(for: place.folder, relativeTo: place.outside.path) == "@\(absolute)/")
        #expect(ComposerPasteboard.mention(for: place.folder, relativeTo: nil) == "@\(absolute)/")
        let board = pasteboard([place.file, place.folder, place.image])
        defer { board.releaseGlobally() }
        #expect(ComposerPasteboard.textOnlyMentions(from: board, relativeTo: place.root.path) == "@notes.md @src/ @shot.png ",
                "a text-only composer takes an image file as a path")
    }

    // MARK: The three text-only composers

    @Test func theDraftPageTakesAFileAndAFolderRelativeToItsProject() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 1, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let project = rig.projects[0]
        try Data("x".utf8).write(to: URL(fileURLWithPath: project.path).appendingPathComponent("notes.md"))
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: project.path).appendingPathComponent("src"),
                                                withIntermediateDirectories: true)
        let model = rig.model
        model.setDraftText("look at", projectID: project.id)
        let host = DraftComposerHost(model: model, projectID: project.id)
        let board = pasteboard([URL(fileURLWithPath: project.path).appendingPathComponent("notes.md"),
                                URL(fileURLWithPath: project.path).appendingPathComponent("src", isDirectory: true)])
        defer { board.releaseGlobally() }
        #expect(host.drop(board))
        #expect(model.newSession.draft(for: project.id)?.text == "look at @notes.md @src/ ")

        // A drop anywhere on the page lands in the same draft.
        let other = pasteboard([URL(fileURLWithPath: project.path).appendingPathComponent("src", isDirectory: true)])
        defer { other.releaseGlobally() }
        #expect(DraftComposerHost.dropOnPage(other, model: model, projectID: project.id))
        #expect(model.newSession.draft(for: project.id)?.text == "look at @notes.md @src/ @src/ ")

        // Text is not this target's: the field's own handling takes it.
        let text = NSPasteboard(name: NSPasteboard.Name("loom-drop-test-\(UUID())"))
        defer { text.releaseGlobally() }
        text.clearContents()
        text.setString("plain words", forType: .string)
        #expect(!host.drop(text))
        #expect(!DraftComposerHost.dropOnPage(text, model: model, projectID: project.id))
    }

    /// Review fix: a draft being sent (↵ with a new worktree can take 30 s) is the session's now. A drop on its page or its
    /// locked field, or a Draft Again brief, wrote into it and was discarded with it when the session started.
    @Test func aDraftBeingSentTakesNoDropAndNoBrief() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 1, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let project = rig.projects[0]
        let folder = URL(fileURLWithPath: project.path)
        try Data("x".utf8).write(to: folder.appendingPathComponent("notes.md"))
        let model = rig.model
        model.newSession.open(projectID: project.id)
        model.remora.draft = .drafted(RemoraDraftedBrief(project: project.id, text: "Remora's brief.", citedSessionIDs: [],
                                                         sessionsRead: 1, draftedAt: Date()))
        #expect(model.landRemoraDraft() == .placed)
        let sendingID = try #require(model.newSession.currentID(for: project.id))
        model.newSession.beginSending(draft: sendingID)

        let board = pasteboard([folder.appendingPathComponent("notes.md")])
        defer { board.releaseGlobally() }
        #expect(!ComposerPaneDrop(accepts: { !model.newSession.isSending(project.id) }) { _ in true }.accepts(),
                "the page shows the not-allowed feedback")
        #expect(!DraftComposerHost.dropOnPage(board, model: model, projectID: project.id))
        #expect(!DraftComposerHost(model: model, projectID: project.id).drop(board), "the locked field takes none either")
        #expect(model.newSession.draft(id: sendingID)?.text == "Remora's brief.")

        // Draft Again lands in a new draft, as it does over the user's own text.
        model.remora.draft = .drafted(RemoraDraftedBrief(project: project.id, text: "A second brief.", citedSessionIDs: [],
                                                         sessionsRead: 1, draftedAt: Date().addingTimeInterval(10)))
        #expect(model.landRemoraDraft() == .placedInNewDraft)
        #expect(model.newSession.draft(id: sendingID)?.text == "Remora's brief.", "the sending draft keeps its text")
    }

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
        let board = pasteboard([folder.appendingPathComponent("notes.md"), folder.appendingPathComponent("src", isDirectory: true)])
        defer { board.releaseGlobally() }
        #expect(host.drop(board))
        #expect(session.composerText == "why @notes.md @src/ ")
    }

    @Test func quickQuestionTakesAFileAndAFolderRelativeToItsSessionsFolder() throws {
        let place = try DropFolder()
        defer { place.remove() }
        let panel = QuickQuestionPanel { _ in "" }
        let host = QuickQuestionEditorHost(panel: panel, workingDirectory: place.root.path)
        let board = pasteboard([place.file, place.spaced])
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
        let folderOnly = pasteboard([place.folder])
        defer { folderOnly.releaseGlobally() }
        #expect(bare.drop(folderOnly))
        #expect(field.string == "@\(place.folder.standardizedFileURL.path)/ ")
        withExtendedLifetime(coordinator) {}
    }

    @Test func theThreeComposersRefuseASessionAndInsertNoText() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 1, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let parent = try #require(rig.ids[rig.projects[0].id]?.first)
        rig.model.side.session(for: parent).composerText = ""
        let hosts: [any ComposerEditorHost] = [
            DraftComposerHost(model: rig.model, projectID: rig.projects[0].id),
            SideComposerEditorHost(model: rig.model, parent: parent),
            QuickQuestionEditorHost(panel: QuickQuestionPanel { _ in "" }),
        ]
        for host in hosts {
            let editor = ComposerTextEditor(host: host, height: .constant(60))
            let coordinator = editor.makeCoordinator()
            let field = ComposerTextEditor.ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
            field.coordinator = coordinator
            coordinator.textView = field
            let board = NSPasteboard(name: NSPasteboard.Name("loom-drop-test-\(UUID())"))
            defer { board.releaseGlobally() }
            SessionDrag.write(parent, title: "A session title", to: board)
            #expect(field.sessionDragOperation(board) == [], "\(type(of: host)) shows the not-allowed feedback")
            #expect(field.dropSession(board) == false)
            #expect(!host.drop(board), "\(type(of: host)) takes no session as a file")
            #expect(field.string.isEmpty)
            withExtendedLifetime(coordinator) {}
        }
        #expect(rig.model.side.existing(for: parent)?.composerText == "")
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
        let board = pasteboard([place.file, place.folder])
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
