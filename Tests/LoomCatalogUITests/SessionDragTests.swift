import AppKit
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport

/// W3-b: the session drag payload, and the sidebar rows that carry it without losing their click, double click and
/// accessibility.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SessionDragPayloadTests {
    @Test func thePayloadRoundTripsThroughARealPasteboardAndNothingElseReadsAsASession() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("loom-session-drag-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let id = UUID()
        SessionDrag.write(id, title: "Fix the build", to: pasteboard)
        #expect(SessionDrag.sessionID(from: pasteboard) == id)
        #expect(pasteboard.types?.contains(SessionDrag.pasteboardType) == true)
        #expect(pasteboard.string(forType: .string) == "Fix the build", "outside the app it is the title, no path")
        #expect(SessionDrag.pasteboardType.rawValue == "local.loom.desktop.session-reference")

        // Plain text that is an id, and a file, are not sessions.
        pasteboard.clearContents()
        pasteboard.setString(id.uuidString, forType: .string)
        #expect(SessionDrag.sessionID(from: pasteboard) == nil)
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp") as NSURL])
        #expect(SessionDrag.sessionID(from: pasteboard) == nil)
    }

    @Test func aDragOffersTheSameBytesAsThePasteboardAndOnlyTheTitleAsText() async throws {
        let id = UUID()
        let provider = SessionDrag.itemProvider(for: id, title: "Fix the build")
        #expect(provider.registeredTypeIdentifiers.contains(SessionDrag.typeIdentifier))
        #expect(!provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier))
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: SessionDrag.typeIdentifier) { data, _ in continuation.resume(returning: data) }
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("loom-session-drag-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        SessionDrag.write(id, title: nil, to: pasteboard)
        #expect(data == pasteboard.data(forType: SessionDrag.pasteboardType))
        #expect(provider.canLoadObject(ofClass: NSString.self))
    }
}
