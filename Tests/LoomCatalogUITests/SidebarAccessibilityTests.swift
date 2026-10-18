import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI

/// One node of the accessibility tree as an assistive technology would read it.
struct AXNode {
    let role: String
    let subrole: String?
    let label: String?
    let value: String?
    let title: String?
    let roleDescription: String?
    let help: String?
    let traits: Int
    let children: [AXNode]

    /// UIAccessibilityTraitHeader, the bit SwiftUI sets for `.isHeader`.
    var isHeader: Bool { traits & 0x10000 != 0 }

    func flattened() -> [AXNode] { [self] + children.flatMap { $0.flattened() } }
    var description: String { "\(role)\(subrole.map { "/\($0)" } ?? "") label=\(label ?? "-") value=\(value ?? "-") title=\(title ?? "-") rd=\(roleDescription ?? "-") help=\(help ?? "-")" }
}

@MainActor
func axTree(of object: Any, depth: Int = 0) -> AXNode {
    let element = object as AnyObject
    func string(_ selector: String) -> String? {
        guard element.responds(to: NSSelectorFromString(selector)) else { return nil }
        let result = element.perform(NSSelectorFromString(selector))?.takeUnretainedValue()
        return (result as? String) ?? (result as? NSNumber).map { "\($0)" }
    }
    let children: [Any] = depth > 40 ? [] : ((element.accessibilityChildren?() as? [Any]) ?? [])
    return AXNode(role: string("accessibilityRole") ?? "?", subrole: string("accessibilitySubrole"),
                  label: string("accessibilityLabel"), value: string("accessibilityValue"),
                  title: string("accessibilityTitle"),
                  roleDescription: string("accessibilityRoleDescription"), help: string("accessibilityHelp"),
                  traits: (element.accessibilityAttributeValue?(NSAccessibility.Attribute(rawValue: "AXTraits")) as? Int) ?? 0,
                  children: children.map { axTree(of: $0, depth: depth + 1) })
}

/// What a hosted SwiftUI view exposes to VoiceOver. AppKit builds the SwiftUI tree only for an
/// accessibility client, so the test process asks for it (no system setting is touched).
@MainActor
func enableAccessibilityTree() {
    for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
        _ = NSApplication.shared.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                                         with: true as NSNumber, with: attribute)
    }
}

@MainActor
func accessibilityElements(in object: Any) -> [AnyObject] {
    let element = object as AnyObject
    let children = (element.accessibilityChildren?() as? [Any]) ?? []
    return [element] + children.flatMap(accessibilityElements(in:))
}

@MainActor
func host<Content: View>(_ content: Content, size: NSSize, key: Bool = true) -> (NSWindow, NSHostingController<Content>) {
    let hosting = NSHostingController(rootView: content)
    hosting.sizingOptions = []
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    window.contentViewController = hosting
    window.setContentSize(size)
    if key { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
    return (window, hosting)
}

extension WindowEventTests {
/// I3: header traits, expanded or collapsed value and grouped notices as the accessibility tree reports them.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct SidebarAccessibilityTests {
    private func fixture() async throws -> (CatalogModel, URL, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ui-\(UUID())")
        let folder = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let project = try await catalog.addProject(path: folder.path).project
        try await catalog.insertSession(ManagedSession(provider: .claude, workingDirectory: folder.path),
                                        title: "In project", lifecycle: .idle, projectID: project.id)
        try await catalog.insertSession(ManagedSession(provider: .claude, workingDirectory: root.path),
                                        title: "Loose", lifecycle: .idle)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        await model.start()
        await model.stopAndWait()
        await model.settle()
        return (model, root, project.id)
    }

    @Test func projectHeaderIsAHeaderThatOpensThePageAndItsChevronReportsExpandedAndCollapsed() async throws {
        enableAccessibilityTree()
        let (model, root, projectID) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setViewMode(.projects)
        await model.settle()
        let (window, hosting) = host(SidebarView(model: model), size: NSSize(width: 300, height: 500))
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500))
        func element(labelled text: String) -> (node: AXNode, element: AnyObject)? {
            for element in accessibilityElements(in: hosting.view) where (element.accessibilityLabel?() ?? "") == text {
                return (axTree(of: element), element)
            }
            return nil
        }
        // The name: a header that is a button, and opens the project page.
        let name = try #require(element(labelled: "proj"))
        #expect(name.node.role == "AXButton", "operable by keyboard and VoiceOver, not a bare tap gesture")
        #expect(name.node.isHeader)
        #expect(name.node.help == "Opens the project page")
        print("AXDUMP header:", name.node.description, "traits=\(name.node.traits)")

        // The chevron beside it keeps the old affordance: expanded or collapsed, and it presses.
        let chevron = try #require(element(labelled: "Sessions in proj"))
        #expect(chevron.node.role == "AXButton")
        #expect(chevron.node.value == "Expanded")

        // The project actions button keeps its drawn size but answers over at least 24 x 24.
        let menu = try #require(accessibilityElements(in: hosting.view).first {
            ($0.accessibilityRole?() == .menuButton) && ($0.accessibilityHelp?() ?? "").contains("Only an empty project")
        })
        let menuFrame = try #require(menu.accessibilityFrame?())
        print("AXDUMP project actions frame:", menuFrame)
        #expect(menuFrame.width >= 24 && menuFrame.height >= 24)
        let chevronFrame = try #require(chevron.element.accessibilityFrame?())
        #expect(chevronFrame.width >= 24 && chevronFrame.height >= 24)

        #expect(chevron.element.accessibilityPerformPress?() == true)
        try await Task.sleep(for: .milliseconds(600))
        await model.settle()
        let again = try #require(element(labelled: "Sessions in proj"))
        print("AXDUMP after press:", again.node.description)
        #expect(again.node.value == "Collapsed")
        #expect(model.destination != .projectPage(projectID), "collapsing does not open the page")

        #expect(name.element.accessibilityPerformPress?() == true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.destination == .projectPage(projectID))
        let selected = try #require(element(labelled: "proj"))
        #expect(selected.node.isHeader)
    }

    @Test func dayHeadingsAndTheSessionsSectionAreHeadings() async throws {
        enableAccessibilityTree()
        let (model, root, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setViewMode(.activity)
        await model.settle()
        let (window, hosting) = host(SidebarView(model: model), size: NSSize(width: 300, height: 500))
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500))
        let day = axTree(of: hosting.view).flattened().filter { $0.role == "AXHeading" }
        print("AXDUMP day headings:", day.map(\.description))
        #expect(day.contains { $0.label == "Today" })

        model.setViewMode(.projects)
        await model.settle()
        try await Task.sleep(for: .milliseconds(500))
        let nodes = axTree(of: hosting.view).flattened()
        let sessions = try #require(nodes.first { $0.label == "Sessions" })
        print("AXDUMP sessions section:", sessions.description, "traits=\(sessions.traits)")
        #expect(sessions.role == "AXHeading" && sessions.isHeader)
    }

    @Test func messagesAndNoticesAreGroupsOfTheirTextWithoutADecorativeImage() async throws {
        enableAccessibilityTree()
        let content = VStack {
            Message(symbol: "folder.badge.plus", title: "Add a project to begin", text: "Your projects appear in the sidebar.")
            Notice(symbol: "exclamationmark.triangle.fill", color: LoomTheme.Status.failure,
                   title: "Stop could not be verified", text: "The process is still running.")
        }
        let (window, hosting) = host(content, size: NSSize(width: 500, height: 400))
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        let root = axTree(of: hosting.view)
        for node in root.flattened() { print("AXDUMP notice:", node.description) }
        #expect(!root.flattened().contains { $0.role == "AXImage" }, "the decorative symbol is hidden")
        // Each notice is one group whose children are its title and its text.
        let groups = root.flattened().filter { $0.role == "AXGroup" && !$0.children.isEmpty && $0.subrole == nil }
        func group(containing text: String) -> AXNode? {
            groups.first { $0.children.contains { ($0.label ?? $0.value ?? "") == text } }
        }
        let message = try #require(group(containing: "Add a project to begin"))
        #expect(message.children.contains { ($0.label ?? $0.value) == "Your projects appear in the sidebar." })
        let notice = try #require(group(containing: "Stop could not be verified"))
        #expect(notice.children.contains { ($0.label ?? $0.value) == "The process is still running." })
    }
}
}
