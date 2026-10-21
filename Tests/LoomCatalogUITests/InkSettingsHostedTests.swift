import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// I4b: what needs a view, hosted in a window nobody sees (never ordered front): the sheet's place under the header, what is behind
/// it hidden from VoiceOver, and what a switch and a checkbox tell assistive technologies. The scrim's click and the focus on Cancel
/// need a key window on screen (a synthesised click does not reach SwiftUI in a window that was never shown, and an inactive window holds no focus): they are
/// the end batch's checks.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct InkSettingsHostedTests {
    private let size = NSSize(width: LoomTheme.Settings.width, height: LoomTheme.Settings.height)

    private func host<V: View>(_ view: V) -> (NSWindow, NSHostingController<some View>) {
        enableAccessibilityTree()
        let hosting = NSHostingController(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
                              defer: false)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        return (window, hosting)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(80))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func identifier(of element: AnyObject) -> String { InkAX.identifier(element) }

    private func element(identifier wanted: String, in controller: NSViewController) async throws -> AnyObject? {
        for _ in 0..<30 {
            if let found = accessibilityElements(in: controller.view).first(where: { identifier(of: $0) == wanted }) { return found }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func sheetRoot(_ presenter: SheetPresenter<SettingsSheet>, listsFiles: Bool = false, behind: some View = Color.clear)
        -> some View {
        behind.sheetLayer(presenter, headerOffset: LoomTheme.Settings.bandHeight) { _ in
            InkSheet(title: "Start new sessions in Full access?", listsFiles: listsFiles, cancel: presenter.dismiss, actions: [
                SheetAction(id: "go", title: "Use Full Access", tint: .tone(LoomTheme.Composer.ModeTone.fullAccessPair), perform: {})
            ]) { SheetText(text: "Claude runs every tool without asking.") }
        }
    }

    /// A rect from the accessibility tree (screen coordinates) as the window's content sees it: the distance from the top, the middle
    /// and the width.
    private func placement(of rect: NSRect, in window: NSWindow) -> (top: CGFloat, midX: CGFloat, width: CGFloat) {
        let local = window.convertFromScreen(rect)
        return (size.height - local.maxY, local.midX, local.width)
    }

    @Test func aSheetComesDownUnderTheHeaderCentredAt420() async throws {
        let presenter = SheetPresenter<SettingsSheet>()
        presenter.present(.fullAccess)
        let (window, hosting) = host(sheetRoot(presenter))
        defer { window.close() }
        try await settle(window)
        let sheet = try #require(try await element(identifier: "sheet", in: hosting), "the sheet is in the accessibility tree")
        let place = placement(of: InkAX.frame(sheet), in: window)
        #expect(abs(place.top - LoomTheme.Settings.bandHeight) <= 1, "the sheet's top is \(place.top) under the window's top")
        #expect(abs(place.midX - size.width / 2) <= 1, "centred: \(place.midX)")
        #expect(abs(place.width - 420) <= 1, "\(place.width) wide")
    }

    @Test func aSheetThatListsFilesIs480Wide() async throws {
        let presenter = SheetPresenter<SettingsSheet>()
        presenter.present(.delete)
        let (window, hosting) = host(sheetRoot(presenter, listsFiles: true))
        defer { window.close() }
        try await settle(window)
        let sheet = try #require(try await element(identifier: "sheet", in: hosting))
        #expect(abs(placement(of: InkAX.frame(sheet), in: window).width - 480) <= 1)
    }

    @Test func whatIsBehindASheetIsHiddenFromAccessibilityWhileItIsOpen() async throws {
        let presenter = SheetPresenter<SettingsSheet>()
        let behind = Button("Behind the sheet") {}.buttonStyle(.plain).accessibilityIdentifier("behind")
        presenter.present(.fullAccess)
        let (window, hosting) = host(sheetRoot(presenter, behind: behind))
        defer { window.close() }
        try await settle(window)
        _ = try await element(identifier: "sheet", in: hosting)
        let hidden = accessibilityElements(in: hosting.view).first { identifier(of: $0) == "behind" }
        #expect(hidden == nil, "an element behind the open sheet is not in the tree")
        presenter.dismiss()
        try await settle(window)
        let shown = try await element(identifier: "behind", in: hosting)
        #expect(shown != nil, "and it is back when the sheet closes")
    }

    // MARK: Switch and checkbox

    /// A switch and a checkbox of the family read to assistive technologies as the system's own do: the same role, subrole and value.
    @Test func aSwitchAndACheckboxReadAsTheSystemsOwnDo() async throws {
        let view = VStack {
            SettingsSwitch(title: "Our switch on", isOn: .constant(true))
            SettingsSwitch(title: "Our switch off", isOn: .constant(false))
            Toggle("Native switch on", isOn: .constant(true)).toggleStyle(.switch).labelsHidden().accessibilityLabel("Native switch on")
            Toggle("Our box on", isOn: .constant(true)).labelsHidden().toggleStyle(InkCheckboxStyle()).accessibilityLabel("Our box on")
            Toggle("Our box off", isOn: .constant(false)).labelsHidden().toggleStyle(InkCheckboxStyle()).accessibilityLabel("Our box off")
            Toggle("Native box on", isOn: .constant(true)).toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Native box on")
        }
        let (window, hosting) = host(view)
        defer { window.close() }
        try await settle(window)
        var nodes: [AXNode] = []
        for _ in 0..<30 {
            nodes = axTree(of: hosting.view).flattened()
            if nodes.contains(where: { $0.label?.hasPrefix("Native box on") == true }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        func node(_ label: String) throws -> AXNode {
            try #require(nodes.first { $0.label?.hasPrefix(label) == true || $0.title == label }, "\(label) in \(nodes.map(\.description))")
        }
        let nativeSwitch = try node("Native switch on"), nativeBox = try node("Native box on")
        for label in ["Our switch on", "Our switch off"] {
            let ours = try node(label)
            #expect(ours.role == nativeSwitch.role && ours.subrole == nativeSwitch.subrole, "\(ours.description) against \(nativeSwitch.description)")
        }
        #expect(try node("Our switch on").value == "1" && node("Our switch off").value == "0")
        for label in ["Our box on", "Our box off"] {
            let ours = try node(label)
            #expect(ours.role == nativeBox.role && ours.subrole == nativeBox.subrole, "\(ours.description) against \(nativeBox.description)")
        }
        #expect(try node("Our box on").value == "1" && node("Our box off").value == "0")
    }
}
