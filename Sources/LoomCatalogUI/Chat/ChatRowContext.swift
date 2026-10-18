import AppKit
import Foundation
import LoomChat
import Observation

/// The one-second clock of the live row (CHAT-SPEC → Live row). Only views that read `now` redraw when it ticks: the
/// live row's elapsed label and a running subagent card's. It runs only while a live row exists and the window can be
/// seen, so a hidden window or a settled session has no timer at all.
@MainActor
@Observable
final class ChatLiveClock {
    private(set) var now = Date()
    @ObservationIgnored private var timer: Timer?

    var isRunning: Bool { timer != nil }

    func setActive(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            now = Date()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.now = Date() }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    deinit { MainActor.assumeIsolated { timer?.invalidate() } }
}

/// What a row view needs besides its row: the actions it can ask for and the shared clock. Set up once by the stream;
/// everything that changes what a row draws travels in the row itself.
@MainActor
final class ChatRowContext {
    let clock = ChatLiveClock()
    var workingDirectory: String?
    /// The persistent animations (the working chase) run only while the stream can be seen.
    var animates = false
    var toggle: (_ rowID: String) -> Void = { _ in }
    var toggleFlag: (_ rowID: String, _ flag: String) -> Void = { _, _ in }
    var showAll: (_ entry: ChatEntry) -> Void = { _ in }
    /// Whether "Show all" can read a clipped result: from a transcript, the entry's own line; a live chat scans the file.
    var canShowAll: (_ entry: ChatEntry) -> Bool = { $0.sourceOffset != nil }
    var openSubagent: ((SubagentRun) -> Void)?
    var openImage: (_ image: ImageRef) -> Void = { _ in }
    var copy: (_ text: String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
