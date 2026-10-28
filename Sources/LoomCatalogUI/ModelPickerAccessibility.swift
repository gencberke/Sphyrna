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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ModelPickerAccessibilityHost<Content>, context: Context) -> CGSize? {
        nsView.sizeThatFits(in: CGSize(width: proposal.width ?? 100_000, height: proposal.height ?? 100_000))
    }
}

/// An accessibility container with explicit SwiftUI measurement; its nested host never sizes the enclosing AppKit window.
final class ModelPickerAccessibilityHost<Content: View>: NSView {
    private let hosting: NSHostingController<Content>
    let role: NSAccessibility.Role
    var roleLabel: String
    var rootView: Content {
        get { hosting.rootView }
        set { hosting.rootView = newValue }
    }

    @MainActor init(rootView: Content, role: NSAccessibility.Role, label: String) {
        hosting = NSHostingController(rootView: rootView)
        self.role = role
        roleLabel = label
        super.init(frame: .zero)
        hosting.sizingOptions = []
        hosting.view.frame = bounds
        hosting.view.autoresizingMask = [.width, .height]
        addSubview(hosting.view)
    }

    func sizeThatFits(in size: CGSize) -> CGSize { hosting.sizeThatFits(in: size) }

    @MainActor @preconcurrency required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { role }
    override func accessibilityLabel() -> String? { roleLabel }
}
