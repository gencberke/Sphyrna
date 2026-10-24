import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// W3-e: a changed file drags out of the Changes tab as its URL and its listed path; a file gone from disk offers no drag, and the
/// rows keep their click.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ChangesFileDragTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-changes-drag-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        return root
    }

    private func file(_ path: String, in root: URL, status: ChangesFileStatus = .modified) -> ChangesFile {
        ChangesFile(id: path, displayPath: path, absolutePath: root.appendingPathComponent(path).path, added: 3, removed: 1,
                    status: status)
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL) as URL?)
            }
        }
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString) as String?)
            }
        }
    }

    @Test func aModifiedFileDragsAsItsURLAndItsListedPath() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let changed = file("src/token service.py", in: root)
        try Data("x\n".utf8).write(to: URL(fileURLWithPath: changed.absolutePath))

        let provider = try #require(ChangesFileDrag.provider(for: changed))
        #expect(provider.hasItemConformingToTypeIdentifier("public.file-url"))
        #expect(provider.hasItemConformingToTypeIdentifier("public.utf8-plain-text"))
        #expect(provider.suggestedName == "token service.py")
        let url = try #require(await loadURL(from: provider))
        #expect(url.isFileURL && url.standardizedFileURL.path == URL(fileURLWithPath: changed.absolutePath).standardizedFileURL.path)
        #expect(await loadText(from: provider) == "src/token service.py")

        // On a composer the URL wins over the text, and becomes the session-relative mention.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("loom-changes-drag-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL, changed.displayPath as NSString])
        #expect(ComposerPasteboard.items(from: pasteboard) == [.otherFile(url)])
        #expect(ComposerPasteboard.mention(for: url, relativeTo: root.path) == #"@"src/token service.py""#)
    }

    @Test func aFileGoneFromDiskOffersNoDrag() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ChangesFileDrag.provider(for: file("src/gone.py", in: root, status: .deleted)) == nil)
        #expect(ChangesFileDrag.provider(for: file("src/gone.py", in: root, status: .modified)) == nil, "status aside, it is gone")
        #expect(ChangesFileDrag.provider(for: file("src/here.py", in: root), exists: { _ in true }) != nil)
    }

    @Test func theRowsStillOpenTheirDiffWithADragSourceOnThem() async throws {
        enableAccessibilityTree()
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await InspectorRig.make()
        defer { rig.cleanup() }
        let model = rig.model
        let id = rig.ids[0]
        model.select(id)
        let row = try #require(model.selectedRow)
        let kept = file("src/kept.py", in: root)
        try Data("x\n".utf8).write(to: URL(fileURLWithPath: kept.absolutePath))
        let gone = file("src/gone.py", in: root, status: .deleted)
        let session = model.changes.session(for: id)
        session.setState(.ready(ChangesScopeData(files: [kept, gone])), for: .lastTurn)

        let size = NSSize(width: LoomTheme.Rhythm.inspectorWidthReview, height: 700)
        let host = NSHostingView(rootView: ChangesTab(model: model, row: row).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        rig.window.contentView = host
        host.layoutSubtreeIfNeeded()
        func element(_ prefix: String) -> AnyObject? {
            accessibilityElements(in: host).first { ($0.accessibilityLabel?() ?? "").hasPrefix(prefix) }
        }

        let keptRow = try #require(element("src/kept.py, Modified"))
        #expect(keptRow.accessibilityPerformPress?() == true)
        #expect(session.selected[.lastTurn] == kept.id, "a click on a draggable row opens its diff")
        host.layoutSubtreeIfNeeded()
        #expect(element("Open kept.py in editor") != nil, "the open diff's header keeps its button")

        let goneRow = try #require(element("src/gone.py, Deleted"))
        #expect(goneRow.accessibilityPerformPress?() == true)
        #expect(session.selected[.lastTurn] == gone.id, "a row without a drag opens its diff too")
    }
}
