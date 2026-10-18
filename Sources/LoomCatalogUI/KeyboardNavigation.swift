import AppKit
import Observation

/// Whether Full Keyboard Access is on, read once and refreshed when a window
/// becomes key (the setting changes in System Settings, outside the app), so
/// each chrome button only reads a flag instead of subscribing on its own.
@MainActor @Observable
final class KeyboardNavigation {
    static let shared = KeyboardNavigation()

    private(set) var isEnabled = NSApplication.shared.isFullKeyboardAccessEnabled
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// Internal so a test can make its own; the app uses `shared`.
    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Writes only a change: a write re-renders every chrome button that reads the flag.
    func refresh(_ value: Bool = NSApplication.shared.isFullKeyboardAccessEnabled) {
        if value != isEnabled { isEnabled = value }
    }
}
