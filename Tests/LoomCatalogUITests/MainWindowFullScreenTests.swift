import AppKit
import Testing
@testable import LoomCatalogUI

/// The main window's full-screen presentation (`AppDelegate.window(_:willUseFullScreenPresentationOptions:)`): the empty toolbar
/// hides with the menu bar, so it does not cover the top of the pane. What the screen shows is the pool's check.
@Suite struct MainWindowFullScreenTests {
    @Test func fullScreenAutoHidesTheToolbarWithTheMenuBar() {
        let proposed: NSApplication.PresentationOptions = [.fullScreen, .autoHideMenuBar, .autoHideDock]
        let options = MainWindowFullScreen.presentationOptions(proposed: proposed)
        #expect(options.contains(.autoHideToolbar))
        #expect(options.isSuperset(of: proposed), "what AppKit proposed is kept")
    }

    /// AppKit takes `.autoHideToolbar` only with `.fullScreen` and `.autoHideMenuBar`, `.autoHideMenuBar` not with `.hideMenuBar` and
    /// only with the Dock hidden or auto-hidden.
    @Test func theOptionsAreACombinationAppKitAccepts() {
        for proposed: NSApplication.PresentationOptions in [[], [.fullScreen], [.fullScreen, .hideMenuBar, .hideDock]] {
            let options = MainWindowFullScreen.presentationOptions(proposed: proposed)
            #expect(options.isSuperset(of: [.fullScreen, .autoHideMenuBar, .autoHideToolbar]), "\(proposed.rawValue)")
            #expect(!options.contains(.hideMenuBar), "\(proposed.rawValue)")
            #expect(options.contains(.hideDock) != options.contains(.autoHideDock), "the Dock hidden or auto-hidden, one of them: \(proposed.rawValue)")
        }
    }
}
