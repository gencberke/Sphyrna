import AppKit
import Darwin
import Foundation
import SwiftTerm

enum TerminalFileDrop {
    static func pasteText(for urls: [URL]) -> String? {
        guard !urls.isEmpty else { return nil }
        var paths: [String] = []
        for url in urls {
            let path = url.path
            guard url.isFileURL, path.hasPrefix("/"),
                  path.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            paths.append("'\(path.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
        return " " + paths.joined(separator: " ") + " "
    }
}

final class FileDropTerminalView: LocalProcessTerminalView {
    var canAcceptFileDrop: (() -> Bool)?
    var onFileDrop: (([URL]) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAcceptFileDrop?() == true,
              sender.draggingPasteboard.canReadObject(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
              ) else { return [] }
        return .copy
    }

    // Local agents read clipboard images on Ctrl+V. Forward image-only Cmd+V
    // as that key while keeping SwiftTerm’s normal text paste handling.
    override func paste(_ sender: Any) {
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string) == nil,
           pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) {
            send(data: [0x16])
            return
        }
        super.paste(sender)
    }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else { return }
        if scheme == "http" || scheme == "https" {
            guard url.host != nil else { return }
            NSWorkspace.shared.open(url)
        } else if scheme == "file", url.isFileURL {
            let file = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            NSWorkspace.shared.open(file)
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard canAcceptFileDrop?() == true,
              let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
              ) as? [NSURL] else { return false }
        return onFileDrop?(urls.map { $0 as URL }) ?? false
    }
}

@MainActor
final class TerminalHost: NSObject, LocalProcessTerminalViewDelegate {
    let view = NSView()
    private var sessions: [String: NativeTerminalSession] = [:]
    private var demoView: FileDropTerminalView?
    private(set) var attachedSessionID: String?
    var onError: ((String) -> Void)?
    var onClosed: ((String) -> Void)?
    var onTitle: ((String, String) -> Void)?

    var runningSessionIDs: Set<String> {
        Set(sessions.keys)
    }
    var performanceRoots: [String: String] {
        Dictionary(uniqueKeysWithValues: sessions.compactMap { id, session in
            let pid = session.view.process.shellPid
            return pid > 0 && session.isRunning ? (String(pid), id) : nil
        })
    }
    /// Includes sessions that are stopping and still waiting for child reaping.
    var isRunning: Bool { !sessions.isEmpty }

    var fontSize: Double = 14 {
        didSet {
            guard fontSize != oldValue else { return }
            for session in sessions.values { session.view.font = Self.terminalFont(size: fontSize) }
            demoView?.font = Self.terminalFont(size: fontSize)
        }
    }

    func start(sessionID: String, executable: URL, arguments: [String],
               environment: [String: String], directory: String) throws {
        guard !sessionID.isEmpty, sessions[sessionID] == nil else {
            throw NativeTerminalError.invalidSession
        }
        let terminal = makeTerminal()
        let session = NativeTerminalSession(view: terminal)
        try session.start(executable: executable, arguments: arguments,
                          environment: environment, directory: directory)
        sessions[sessionID] = session
        terminal.canAcceptFileDrop = { [weak self, weak session] in
            self?.attachedSessionID == sessionID && session?.isRunning == true && session?.stopping == false
        }
        terminal.onFileDrop = { [weak self] urls in self?.pasteFilePaths(urls) ?? false }
    }

    func attach(sessionID: String) {
        guard attachedSessionID != sessionID else { return }
        guard let session = sessions[sessionID], !session.stopping else {
            onError?("The selected terminal is no longer running.")
            return
        }
        detach()
        attachedSessionID = sessionID
        show(session.view)
        view.window?.makeFirstResponder(session.view)
    }

    /// Removing the view suspends rendering; the PTY and terminal parser remain alive.
    func detach() {
        view.subviews.forEach { $0.removeFromSuperview() }
        attachedSessionID = nil
        demoView = nil
    }

    func stop(sessionID: String) {
        if attachedSessionID == sessionID { detach() }
        sessions[sessionID]?.stop()
    }

    func stopAll() {
        detach()
        for session in sessions.values { session.stop() }
    }

    /// Yields the main actor so SwiftTerm can deliver exit callbacks and finish reaping.
    func waitForStop(sessionIDs: Set<String>, timeout: TimeInterval = 3) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while sessionIDs.contains(where: { sessions[$0] != nil }) {
            if Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    func waitForShutdown(timeout: TimeInterval = 3) async -> Bool {
        await waitForStop(sessionIDs: Set(sessions.keys), timeout: timeout)
    }

    func showDemo() {
        detach()
        let terminal = makeTerminal()
        demoView = terminal
        show(terminal)
        terminal.feed(text: Self.demoText)
    }

    @discardableResult
    func pasteFilePaths(_ urls: [URL]) -> Bool {
        guard let terminal = activeTerminal,
              let text = TerminalFileDrop.pasteText(for: urls) else { return false }
        terminal.pasteText(text)
        view.window?.makeFirstResponder(terminal)
        return true
    }

    @discardableResult
    func pasteTranscriptPath(_ path: String, into sessionID: String) -> Bool {
        guard attachedSessionID == sessionID, let terminal = activeTerminal,
              path.rangeOfCharacter(from: .controlCharacters) == nil,
              path.hasPrefix("/"), path.hasSuffix(".jsonl"),
              FileManager.default.fileExists(atPath: path) else { return false }
        terminal.pasteText(" Session transcript: \(path) ")
        view.window?.makeFirstResponder(terminal)
        return true
    }

    private var activeTerminal: FileDropTerminalView? {
        guard let id = attachedSessionID, let session = sessions[id],
              session.isRunning, !session.stopping else { return nil }
        return session.view
    }

    private func show(_ terminal: FileDropTerminalView) {
        terminal.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: view.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func makeTerminal() -> FileDropTerminalView {
        let options = TerminalOptions(cols: 80, rows: 24, termName: "xterm-256color",
                                      cursorStyle: .steadyBlock, scrollback: 2_000,
                                      maximumOscBytes: 1024 * 1024, kittyClipboardPolicy: [])
        let terminal = FileDropTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500),
                                            font: Self.terminalFont(size: fontSize), options: options)
        terminal.processDelegate = self
        terminal.cursorBlinkResetsOnInput = false
        terminal.suspendsRenderingWhenNotVisible = true
        terminal.registerForDraggedTypes([.fileURL])
        terminal.nativeBackgroundColor = NSColor(srgbRed: 29 / 255, green: 28 / 255, blue: 34 / 255, alpha: 1)
        terminal.nativeForegroundColor = NSColor(srgbRed: 214 / 255, green: 211 / 255, blue: 222 / 255, alpha: 1)
        return terminal
    }

    private func session(for source: TerminalView) -> (key: String, value: NativeTerminalSession)? {
        sessions.first { $0.value.view === source }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let (id, session) = session(for: source) else { return }
        Task { @MainActor [weak self] in
            await session.finish()
            guard let self, self.sessions[id] === session else { return }
            if self.attachedSessionID == id { self.detach() }
            self.sessions.removeValue(forKey: id)
            self.onClosed?(id)
            if !session.stopping, let exitCode, exitCode != 0 {
                self.onError?("Terminal exited with status \(exitCode).")
            }
        }
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        guard let (id, _) = session(for: source) else { return }
        if attachedSessionID == id { detach() }
        sessions.removeValue(forKey: id)
        onClosed?(id)
        onError?("Could not start the terminal: \(error)")
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard let (id, _) = session(for: source) else { return }
        onTitle?(id, String(title.prefix(512)))
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    private static func terminalFont(size: Double) -> NSFont {
        let size = min(32, max(9, size))
        return NSFont(name: "SFMono-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static let demoText = ([
        "\u{1b}[0;22m\u{1b}[38;2;152;152;164m# Synthetic terminal preview\u{1b}[0;22m",
        "\u{1b}[0;22m$ swift test",
        "\u{1b}[0;22m\u{1b}[38;2;130;170;255mBuilding example targets...\u{1b}[0;22m",
        "\u{1b}[0;22m[12/12] Linking ExamplePackageTests",
        "\u{1b}[0;22m\u{1b}[38;2;126;211;158m✓ NativeTerminal example\u{1b}[0;22m  0.018 seconds",
        "\u{1b}[0;22m\u{1b}[38;2;126;211;158m✓ CatalogStore example\u{1b}[0;22m    0.011 seconds",
        "",
        "\u{1b}[0;22mSynthetic preview completed.",
        "",
        "\u{1b}[0;22m$ git status --short",
        "\u{1b}[0;22m M Sources/Example/TerminalHost.swift",
        "",
        "\u{1b}[0;22m\u{1b}[38;2;152;152;164m# No harness process is running in this preview.\u{1b}[0;22m",
        "\u{1b}[0;22m$ "
    ]).joined(separator: "\r\n")
}
