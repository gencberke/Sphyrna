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
    // MARK: Folders

    @Test func aFolderBecomesAtFolderSlashRelativeInsideTheFolderAndAbsoluteOutside() throws {
        let place = try DropFolder()
        defer { place.remove() }
        #expect(ComposerPasteboard.mention(for: place.folder, relativeTo: place.root.path) == "@src/")
        #expect(ComposerPasteboard.mention(for: place.spaced, relativeTo: place.root.path) == "@\"my docs/\"")
        let absolute = place.folder.standardizedFileURL.path
        #expect(ComposerPasteboard.mention(for: place.folder, relativeTo: place.outside.path) == "@\(absolute)/")
        #expect(ComposerPasteboard.mention(for: place.folder, relativeTo: nil) == "@\(absolute)/")
        let board = ComposerFileDropShared.pasteboard([place.file, place.folder, place.image])
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
        let board = ComposerFileDropShared.pasteboard([URL(fileURLWithPath: project.path).appendingPathComponent("notes.md"),
                                URL(fileURLWithPath: project.path).appendingPathComponent("src", isDirectory: true)])
        defer { board.releaseGlobally() }
        #expect(host.drop(board))
        #expect(model.newSession.draft(for: project.id)?.text == "look at @notes.md @src/ ")

        // A drop anywhere on the page lands in the same draft.
        let other = ComposerFileDropShared.pasteboard([URL(fileURLWithPath: project.path).appendingPathComponent("src", isDirectory: true)])
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

        let board = ComposerFileDropShared.pasteboard([folder.appendingPathComponent("notes.md")])
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
