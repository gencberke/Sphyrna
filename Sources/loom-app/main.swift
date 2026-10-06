import AppKit

// AppKit owns the single main window (CP5 §5). Top-level code runs on MainActor.
let application = NSApplication.shared
let delegate = AppDelegate(arguments: Array(CommandLine.arguments.dropFirst()))
application.delegate = delegate
application.setActivationPolicy(.regular)
withExtendedLifetime(delegate) { application.run() }
