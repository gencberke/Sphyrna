import AppKit
import Foundation
import LoomCore
import Observation
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport

/// What both halves of `InkHostTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum InkHostShared {
    @Observable @MainActor
    final class OpenFlag {
        var on = true
    }
}

/// `InkHostOpenersTests`'s fixtures, for both halves of the suite.
@MainActor protocol InkHostOpenersFixtures {}

extension InkHostOpenersFixtures {
    typealias OpenFlag = InkHostShared.OpenFlag

    func host<V: View>(_ view: V, size: CGSize) -> (NSWindow, InkHost) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = InkHost()
        let hosting = NSHostingView(rootView: view.inkHost(host).frame(width: size.width, height: size.height))
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        hosting.frame = content.bounds
        host.view.frame = content.bounds
        content.addSubview(hosting)
        content.addSubview(host.view)
        window.contentView = content
        return (window, host)
    }

    func settle(_ window: NSWindow, _ host: InkHost) async {
        for _ in 0..<60 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if host.state.frame != nil { return }
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    func check(_ host: InkHost, side: InkPlacement.Side, alignment: InkPlacement.Alignment, id: String) throws {
        let state = host.state
        let active = try #require(state.active, "\(id) is open")
        #expect(active.id == id && active.side == side && active.alignment == alignment)
        let anchor = try #require(state.anchorRect)
        let frame = try #require(state.frame)
        switch side {
        case .above: #expect(abs(frame.maxY - (anchor.minY - 6)) < 0.5, "\(id): \(frame) over \(anchor)")
        case .below: #expect(abs(frame.minY - (anchor.maxY + 6)) < 0.5, "\(id): \(frame) under \(anchor)")
        }
        switch alignment {
        case .leading: #expect(abs(frame.minX - anchor.minX) < 0.5, "\(id): \(frame) from \(anchor)")
        case .trailing: #expect(abs(frame.maxX - anchor.maxX) < 0.5, "\(id): \(frame) from \(anchor)")
        }
    }

    func chips(_ flag: OpenFlag, onDraft: Bool) -> some View {
        let open = Binding(get: { flag.on }, set: { flag.on = $0 })
        return HStack {
            Spacer(minLength: 300)
            ComposerModeChip(selected: "auto", title: "Auto", help: "Mode", identifier: "composer-mode", onDraft: onDraft, isOpen: open) { _ in }
            Spacer(minLength: 300)
        }
    }
}
