import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport

/// Reads a window's accessibility tree through the entry point AppKit answers an assistive client's request with
/// (`_accessibilityValueForAttribute:clientError:`, the frame below which both signed-app crashes of 29 Oct recursed): every
/// element's role, label and value attributes and its children, as `AXUIElementCopyHierarchy` asks for them. The selector is
/// AppKit's own and private; only this test calls it. The public `accessibilityLabel()` path never reaches the override.
@MainActor
enum AXClientRead {
    private typealias Read = @convention(c) (AnyObject, Selector, NSString, UnsafeMutablePointer<Int32>) -> Unmanaged<AnyObject>?
    private static let selector = NSSelectorFromString("_accessibilityValueForAttribute:clientError:")

    /// The element's answer to `attribute`, or nil.
    static func value(_ element: AnyObject, _ attribute: String) -> AnyObject? {
        guard let object = element as? NSObject, object.responds(to: selector) else { return nil }
        let read = unsafeBitCast(object.method(for: selector), to: Read.self)
        var error: Int32 = 0
        return read(object, selector, attribute as NSString, &error)?.takeUnretainedValue()
    }

    /// Reads the tree under `element` as a client copying the hierarchy does; how many elements it read.
    @discardableResult
    static func copyTree(_ element: AnyObject, depth: Int = 0) -> Int {
        for attribute in ["AXRole", "AXSubrole", "AXIdentifier", "AXDescription", "AXTitle", "AXValue", "AXHelp"] {
            _ = value(element, attribute)
        }
        guard depth < 60 else { return 1 }
        let children = (value(element, "AXChildren") as? [AnyObject]) ?? []
        return 1 + children.reduce(0) { $0 + copyTree($1, depth: depth + 1) }
    }
}

extension WindowEventTests {
/// An assistive client reading the window's accessibility tree must never take the app down. On macOS 27 SwiftUI recurses
/// without end when a selectable Text carries its own accessibility label: the label override it installs on the text's AppKit
/// element resolves the label by asking that element again. A delegation request's message preview did this (two signed-app
/// crashes on 29 Oct), and so did the setup commands in Settings → Connections. The recursion runs only in a node's first
/// moments, so each surface appears and leaves several times while the tree is read every 15 ms (`check-selectable-labels.sh`
/// is the source guard). Without the fix the test process dies of a stack overflow.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SelectableTextAccessibilityTests {
    @Observable final class Shown { var on = false }

    private struct Toggled<Content: View>: View {
        let shown: Shown
        @ViewBuilder let content: () -> Content
        var body: some View {
            VStack(spacing: 0) { if shown.on { content() } }
                .frame(width: 440, height: 380, alignment: .top)
        }
    }

    /// Shows the content `rounds` times and reads the window's tree every 15 ms while it is on screen; the counts of each read.
    private func readWhileAppearing(_ shown: Shown, in window: NSWindow, rounds: Int = 6) async throws -> [Int] {
        var counts: [Int] = []
        for _ in 0..<rounds {
            shown.on = true
            let start = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - start < 0.6 {
                counts.append(AXClientRead.copyTree(window))
                try await Task.sleep(for: .milliseconds(15))
            }
            shown.on = false
            try await Task.sleep(for: .milliseconds(200))
        }
        return counts
    }

    /// An element labelled `label` with a child that reads `text`: the label sits on a group around the selectable text.
    private func group(labelled label: String, around text: String, in view: NSView) -> Bool {
        accessibilityElements(in: view).contains { element in
            InkAX.label(element) == label && accessibilityElements(in: element).dropFirst().contains {
                InkAX.value($0) == text || InkAX.label($0) == text
            }
        }
    }

    @Test func aDelegationRequestCardSurvivesAnAssistiveClientReadingItAsItAppears() async throws {
        enableAccessibilityTree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ax-request-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let request = OpenSessionRequest(
            requesterID: UUID(), requesterTitle: "Planner", projectID: UUID(), projectName: "proj", title: "Fixture child",
            message: "fixture-round-1", choices: HarnessLaunchChoices(harness: .claude),
            task: OpenSessionTaskRequest(taskID: UUID(), childID: UUID(), operationID: UUID()))
        let shown = Shown()
        let (window, hosting) = host(Toggled(shown: shown) { OpenRequestBox(model: model, request: request) },
                                     size: NSSize(width: 440, height: 380), key: false)
        defer { window.orderOut(nil) }

        let counts = try await readWhileAppearing(shown, in: window)
        #expect(counts.count > 40 && counts.max() ?? 0 > 10, "the reads reached the card: \(counts.max() ?? 0) elements at most")

        // VoiceOver still reads the message, as the text of a group named Message.
        shown.on = true
        try await Task.sleep(for: .milliseconds(400))
        #expect(group(labelled: "Message", around: "fixture-round-1", in: hosting.view))
    }

    @Test func theConnectionsSetupCommandsSurviveAnAssistiveClientReadingThemAsTheyAppear() async throws {
        enableAccessibilityTree()
        let connections = HarnessConnections()
        let checker = HarnessHealthChecker(connections: connections, probe: HarnessProbe(connections: connections, sources: [:]),
                                           toolchain: { provider in ConnectionsTests.toolchain(provider) })
        let health = HarnessHealthModel(connections: connections, checker: checker)
        let command = try #require(HarnessSetupCommand.install(forHarness: .claude))
        let alternative = try #require(command.alternative, "Claude's install offers another way, so both texts are on screen")
        let shown = Shown()
        let (window, hosting) = host(Toggled(shown: shown) { HarnessSetupBlock(health: health, id: .claude, command: command) },
                                     size: NSSize(width: 440, height: 380), key: false)
        defer { window.orderOut(nil) }

        let counts = try await readWhileAppearing(shown, in: window)
        #expect(counts.count > 40 && counts.max() ?? 0 > 6, "the reads reached the block: \(counts.max() ?? 0) elements at most")

        shown.on = true
        try await Task.sleep(for: .milliseconds(400))
        #expect(group(labelled: "Install command for Claude", around: command.command, in: hosting.view))
        #expect(group(labelled: "Other way to install Claude", around: "Or: \(alternative)", in: hosting.view))
    }
}
}
