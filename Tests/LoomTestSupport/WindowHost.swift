import AppKit
import SwiftUI

/// Hosts `content` in a titled window of `size`. The window is ordered in but not made key unless `key` is true: a key
/// window takes first responder and key events from every other suite running beside it, so only the window tests
/// (LoomWindowTests, `WindowEventTests`) ask for one.
@MainActor
public func host<Content: View>(_ content: Content, size: NSSize, key: Bool = false) -> (NSWindow, NSHostingController<Content>) {
    let hosting = NSHostingController(rootView: content)
    hosting.sizingOptions = []
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    window.contentViewController = hosting
    window.setContentSize(size)
    if key { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
    return (window, hosting)
}
