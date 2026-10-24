import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// CHAT-SPEC → Draft session: "A draft with text shows in the sidebar with Discard". The rows come from
/// `CatalogModel.visibleDrafts`; an empty draft has none.
extension WindowEventTests {
    @MainActor
    @Suite(.timeLimit(.minutes(2)))
    struct SidebarDraftRowTests {
        private struct Rig {
            let root: URL
            let model: CatalogModel
            let api: UUID
            let billing: UUID
        }

        private func rig() async throws -> Rig {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-draft-rows-\(UUID())", isDirectory: true)
            var ids: [UUID] = []
            let catalog = try SessionCatalog(url: {
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                return root.appendingPathComponent("catalog.sqlite3")
            }())
            for name in ["api", "billing"] {
                let folder = root.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                ids.append(try await catalog.addProject(path: folder.path).project.id)
            }
            let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                     preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
            await model.start()
            await model.stopAndWait()
            await model.settle()
            return Rig(root: root, model: model, api: ids[0], billing: ids[1])
        }

        @Test func aDraftWithTextIsListedUnderItsProjectAndAnEmptyOneNever() async throws {
            let rig = try await rig()
            defer { try? FileManager.default.removeItem(at: rig.root) }
            let model = rig.model

            model.beginNewSession(projectID: rig.api)
            #expect(DraftRows.drafts(in: .all, of: model).isEmpty, "an empty draft is invisible")
            model.setDraftText("  fix the flaky test\nsecond line", projectID: rig.api)
            model.beginNewSession(projectID: nil)
            model.setDraftText("an idea for no project", projectID: nil)
            model.beginNewSession(projectID: rig.billing)

            #expect(DraftRows.drafts(in: .project(rig.api), of: model).map(\.projectID) == [rig.api])
            #expect(DraftRows.drafts(in: .project(nil), of: model).map(\.projectID) == [nil])
            #expect(DraftRows.drafts(in: .project(rig.billing), of: model).isEmpty)
            #expect(Set(DraftRows.drafts(in: .all, of: model).map(\.projectID)) == [rig.api, nil])
            #expect(DraftRow.title(of: try #require(model.newSession.draft(for: rig.api))) == "fix the flaky test")
            #expect(DraftRow.accessibilityLabel(title: "fix the flaky test", project: "api") == "Draft, fix the flaky test, api")

            // Discard empties the slot; the file forgets it.
            model.discardDraft(projectID: rig.api)
            #expect(DraftRows.drafts(in: .project(rig.api), of: model).isEmpty)
            #expect(model.newSession.draft(for: rig.api)?.isVisible == false)
            // A project that was removed takes its drafts out of the list.
            model.setDraftText("for a project that goes", projectID: rig.billing)
            #expect(DraftRows.drafts(in: .project(rig.billing), of: model).count == 1)
            await model.removeProject(rig.billing)
            #expect(DraftRows.drafts(in: .project(rig.billing), of: model).isEmpty)
            model.stop()
        }

        @Test func twoDraftsOfOneProjectAreTwoRowsNewestFirstAndAnEmptyDraftHasNone() async throws {
            let rig = try await rig()
            defer { try? FileManager.default.removeItem(at: rig.root) }
            let model = rig.model
            var now = Date(timeIntervalSince1970: 1_000)
            model.newSession.clock = { now }
            model.beginNewSession(projectID: rig.api)
            model.setDraftText("older idea", projectID: rig.api)
            now += 60
            model.beginNewSession(projectID: rig.api)
            model.setDraftText("newer idea\nsecond line", projectID: rig.api)
            now += 60
            // The empty draft on screen is the page, not a row.
            model.beginNewSession(projectID: rig.api)

            let rows = DraftRows.drafts(in: .project(rig.api), of: model)
            #expect(rows.map(DraftRow.title(of:)) == ["newer idea", "older idea"])
            #expect(DraftRows.drafts(in: .all, of: model).count == 2)
            #expect(!rows.contains { model.isShownDraft($0) })
            try #require(rows.count == 2)
            // A row opens its own draft.
            model.showDraft(id: rows[1].id)
            #expect(model.isShownDraft(rows[1]) && !model.isShownDraft(rows[0]))
            model.stop()
        }

        private func element(labelled text: String, in view: NSView) -> AnyObject? {
            accessibilityElements(in: view).first { ($0.accessibilityLabel?() ?? "") == text }
        }

        @Test func theProjectViewDrawsTheRowAClickOpensItAndDiscardRemovesIt() async throws {
            enableAccessibilityTree()
            let rig = try await rig()
            defer { try? FileManager.default.removeItem(at: rig.root) }
            let model = rig.model
            model.setViewMode(.projects)
            model.beginNewSession(projectID: rig.api)
            model.setDraftText("fix the flaky test", projectID: rig.api)
            model.showHome()
            await model.settle()

            let (window, hosting) = host(SidebarView(model: model), size: NSSize(width: 320, height: 520))
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(500))
            let label = "Draft, fix the flaky test, api"
            let row = try #require(element(labelled: label, in: hosting.view), "the draft row is drawn")
            #expect(row.accessibilityPerformPress?() == true)
            #expect(model.destination == .draft(projectID: rig.api), "a click opens the draft")

            try await Task.sleep(for: .milliseconds(300))
            let again = try #require(element(labelled: label, in: hosting.view))
            let actions = (again.accessibilityCustomActions?() as? [NSAccessibilityCustomAction]) ?? []
            let discard = try #require(actions.first { $0.name == "Discard" })
            _ = discard.handler?()
            #expect(model.newSession.draft(for: rig.api)?.isVisible == false)
            try await Task.sleep(for: .milliseconds(300))
            #expect(element(labelled: label, in: hosting.view) == nil, "Discard removes the row")
            model.stop()
        }

        @Test func theActivityViewListsDraftsUnderADraftsHeading() async throws {
            enableAccessibilityTree()
            let rig = try await rig()
            defer { try? FileManager.default.removeItem(at: rig.root) }
            let model = rig.model
            model.setViewMode(.activity)
            model.beginNewSession(projectID: rig.billing)
            model.setDraftText("write the migration", projectID: rig.billing)
            model.showHome()
            await model.settle()

            let (window, hosting) = host(SidebarView(model: model), size: NSSize(width: 320, height: 520))
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(500))
            #expect(element(labelled: "Draft, write the migration, billing", in: hosting.view) != nil)
            let nodes = axTree(of: hosting.view).flattened()
            #expect(nodes.contains { $0.role == "AXHeading" && ($0.label ?? "").hasPrefix("Drafts") })
            model.stop()
        }
    }
}
