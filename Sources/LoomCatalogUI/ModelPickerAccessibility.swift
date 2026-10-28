import AppKit
import SwiftUI

/// SwiftUI's visual stack is a group on macOS; the picker needs native menu/list containers with the same live children.
struct ModelPickerAccessibility<Content: View>: NSViewRepresentable {
    let role: NSAccessibility.Role
    let label: String
    let size: CGSize
    let content: Content

    init(role: NSAccessibility.Role, label: String, size: CGSize, @ViewBuilder content: () -> Content) {
        self.role = role
        self.label = label
        self.size = size
        self.content = content()
    }

    func makeNSView(context: Context) -> ModelPickerAccessibilityHost<Content> {
        ModelPickerAccessibilityHost(rootView: content, role: role, label: label)
    }

    func updateNSView(_ view: ModelPickerAccessibilityHost<Content>, context: Context) {
        view.rootView = content
        view.roleLabel = label
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ModelPickerAccessibilityHost<Content>, context: Context) -> CGSize? {
        size
    }
}

/// A native accessibility container whose picker-owned size never requires measuring its nested SwiftUI host.
final class ModelPickerAccessibilityHost<Content: View>: NSView {
    private let hosting: NSHostingView<Content>
    let role: NSAccessibility.Role
    var roleLabel: String
    var rootView: Content {
        get { hosting.rootView }
        set { hosting.rootView = newValue }
    }

    @MainActor init(rootView: Content, role: NSAccessibility.Role, label: String) {
        hosting = NSHostingView(rootView: rootView)
        self.role = role
        roleLabel = label
        super.init(frame: .zero)
        hosting.sizingOptions = []
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @MainActor @preconcurrency required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { role }
    override func accessibilityLabel() -> String? { roleLabel }
}
