import AppKit
import SwiftUI

/// SwiftUI's visual stack is a group on macOS; the picker needs native menu/list containers with the same live children.
struct ModelPickerAccessibility<Content: View>: NSViewRepresentable {
    let role: NSAccessibility.Role
    let label: String
    let content: Content

    init(role: NSAccessibility.Role, label: String, @ViewBuilder content: () -> Content) {
        self.role = role
        self.label = label
        self.content = content()
    }

    func makeNSView(context: Context) -> ModelPickerAccessibilityHost<Content> {
        ModelPickerAccessibilityHost(rootView: content, role: role, label: label)
    }

    func updateNSView(_ view: ModelPickerAccessibilityHost<Content>, context: Context) {
        view.rootView = content
        view.roleLabel = label
    }
}

final class ModelPickerAccessibilityHost<Content: View>: NSHostingView<Content> {
    let role: NSAccessibility.Role
    var roleLabel: String

    @MainActor init(rootView: Content, role: NSAccessibility.Role, label: String) {
        self.role = role
        roleLabel = label
        super.init(rootView: rootView)
        // Keep the content's natural size without installing min/max constraints inside the enclosing SwiftUI host.
        sizingOptions = [.intrinsicContentSize]
    }

    @MainActor @preconcurrency required init(rootView: Content) { fatalError("init(rootView:) is not used") }
    @MainActor @preconcurrency required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { role }
    override func accessibilityLabel() -> String? { roleLabel }
}
