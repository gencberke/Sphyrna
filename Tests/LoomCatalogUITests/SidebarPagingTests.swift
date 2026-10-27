import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// The sidebar's project view stays lazy (planner review of A1): an expanded project whose rows are off screen reads its
/// first page only. v2 before A1 reads 100 rows and no more pages; wrapping a project's rows in one plain stack made every
/// row appear at once, so each last row asked for the next page until all 350 were read.
@MainActor
struct SidebarPagingTests {
    @Test func anExpandedProjectReadsOnlyItsFirstPageWhileItsRowsAreOffScreen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-probe-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let project = try await catalog.addProject(path: folder.path).project
        for index in 0..<350 {
            try await catalog.insertSession(
                ManagedSession(provider: .claude, workingDirectory: "/tmp"), title: "Row \(index)",
                createdAt: Date(timeIntervalSince1970: 1_000 + Double(index)),
                lastUsedAt: Date(timeIntervalSince1970: 10_000 + Double(index)), lifecycle: .idle,
                projectID: project.id
            )
        }
        let preferences = UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json"))
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(), preferences: preferences)
        await model.start()
        model.setViewMode(.projects)
        await model.settle()
        let before = model.statistics.pageQueries
        let host = NSHostingView(rootView: SidebarList(model: model).frame(width: 280, height: 500))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            await model.settle()
        }
        let rows = model.list(for: .project(project.id)).rows.count
        let reads = model.statistics.pageQueries - before
        #expect(rows <= 100, "an off-screen project loaded \(rows) rows with \(reads) more page reads")
        window.contentView = nil
        model.stop()
    }
}
