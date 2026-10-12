import AppKit
import Foundation
import LoomCore
import SwiftTerm
import Synchronization

/// CHECKPOINT-5-HISTORY §3.2 starting limits. Kitty and inline-image (Sixel, iTerm2) storage
/// are per screen (main + alternate): 8 MiB each keeps each store at 16 MiB.
/// Inline bytes are counted from reported image dimensions (see §18).
public enum TerminalSurfaceLimits {
    public static let scrollbackLines = 2_000
    public static let maximumOscBytes = 1024 * 1024
    public static let kittyBytesPerScreen: UInt32 = 8 * 1024 * 1024
    public static let inlineImageBytesPerScreen = 8 * 1024 * 1024
    public static let inlineImagesPerScreen = 1_024
    /// Input accepted but not yet written to the PTY (keys, paste, replies).
    public static let pendingInputBytes = 4 * 1024 * 1024

    public static var options: TerminalOptions {
        var options = TerminalOptions(
            cols: 80, rows: 24, termName: "xterm-256color", cursorStyle: .steadyBlock,
            scrollback: scrollbackLines,
            // Sixel is still parsed by the engine; do not advertise it.
            enableSixelReported: false,
            kittyGraphics: KittyGraphicsConfiguration(
                storageLimitBytesPerScreen: kittyBytesPerScreen, localMediaPolicy: []
            ),
            maximumOscBytes: maximumOscBytes, kittyClipboardPolicy: []
        )
        options.featureReport = nil
        // The standard xterm cube and grays; the default derives them from the
        // base 16 and mutes every 256-color index (see `TerminalTheme`).
        options.ansi256PaletteStrategy = .xterm
        options.inlineImageStorageLimitBytesPerScreen = inlineImageBytesPerScreen
        options.inlineImageLimitPerScreen = inlineImagesPerScreen
        return options
    }
}

/// Output side of one run: the PTY IO queue feeds the engine directly. It
/// retains only the engine's Sendable feed handle, never the view, so the
/// sink can outlive a closed window without touching AppKit off the main thread.
final class TerminalOutputBridge: TerminalOutputSink {
    struct Counters {
        var bytes = 0
        var batches = 0
        var maxFeedNanoseconds: UInt64 = 0
        var lastReceiveUptimeNanoseconds: UInt64 = 0
        /// Cumulative feed durations; bucket i counts durations below 2^i µs
        /// (last bucket open-ended). Differencing two snapshots gives the
        /// distribution of exactly that interval.
        var feedHistogram = [Int](repeating: 0, count: TerminalSurfaceStatistics.histogramBuckets)
    }
    private let feed: TerminalFeedSender
    private let counters = Mutex(Counters())

    init(feed: TerminalFeedSender) { self.feed = feed }

    func receive(_ data: Data) {
        let start = DispatchTime.now().uptimeNanoseconds
        data.withUnsafeBytes { raw in
            feed.feed(byteArray: ArraySlice(raw.bindMemory(to: UInt8.self)))
        }
        let end = DispatchTime.now().uptimeNanoseconds
        let elapsed = end - start
        let microseconds = elapsed / 1_000
        let bucket = min(TerminalSurfaceStatistics.histogramBuckets - 1,
                         microseconds == 0 ? 0 : 64 - microseconds.leadingZeroBitCount)
        counters.withLock {
            $0.feedHistogram[bucket] += 1
            $0.bytes += data.count
            $0.batches += 1
            $0.maxFeedNanoseconds = max($0.maxFeedNanoseconds, elapsed)
            $0.lastReceiveUptimeNanoseconds = end
        }
    }

    var snapshot: Counters { counters.withLock { $0 } }
}

public struct TerminalSurfaceStatistics: Codable, Sendable {
    public let runID: UUID?
    public let outputBytes: Int
    public let outputBatches: Int
    public static let histogramBuckets = 24
    /// Whole-run maximum of IO-queue time spent inside the engine feed.
    public let maxFeedMilliseconds: Double
    /// Cumulative; see `TerminalOutputBridge` for bucket bounds.
    public let feedHistogramMicroseconds: [Int]
    /// `DispatchTime` uptime of the last output batch handed to the engine.
    public let lastOutputUptimeNanoseconds: UInt64
    public let engineBytesFed: Int
    public let frames: Int
    public let renders: Int
    public let pendingInputBytes: Int
    public let inputErrors: [String]
    /// Exact engine line occupancy/capacity under its existing lock. Nil means
    /// the engine session is unavailable, never an inferred zero.
    public let mainBufferLines: Int?
    public let alternateBufferLines: Int?
    public let mainBufferCapacity: Int?
    public let alternateBufferCapacity: Int?
    public let resizePendingJobs: Int
}

/// Uptimes of the last presented terminal frames (either renderer). The
/// engine offers one process-wide hook; the A slice has a single terminal.
public enum TerminalPresentationLog {
    private static let presented = Mutex<[UInt64]>([])

    public static func install() {
        TerminalView.onFramePresented = {
            let now = DispatchTime.now().uptimeNanoseconds
            presented.withLock {
                if $0.count >= 256 { $0.removeFirst() }
                $0.append(now)
            }
        }
    }

    public static func firstPresentation(after uptimeNanoseconds: UInt64) -> UInt64? {
        presented.withLock { $0.first { $0 > uptimeNanoseconds } }
    }
}

/// One terminal view bound to exactly one managed run. Keyboard, paste and
/// terminal replies share one ordered queue; a later run needs a new surface.
@MainActor
public final class TerminalSurface: NSObject, TerminalViewDelegate {
    public let view: LoomTerminalView
    private let output: TerminalOutputBridge
    private enum InputState {
        /// Replies produced before `attach` are kept in order, bounded.
        case launching([UInt8])
        case attached(TerminalInputQueue, TerminalEndpoint)
        case ended
    }
    private var input: InputState = .launching([])
    private var inputGate: TerminalInputGate?
    /// The ended run's last screen is kept for reading (`keepAsReadOnly`): keys and pastes are dropped quietly.
    private var isReadOnly = false
    private var inputErrors: [String] = []
    private var requestedSize: (rows: UInt16, columns: UInt16)?
    private var resizeTask: Task<Void, Never>?
    public private(set) var runID: UUID?
    public var onTitle: ((String) -> Void)?
    public var onInputError: ((TerminalInputError) -> Void)?

    public init(fontSize: CGFloat = 14) {
        view = LoomTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 500),
            font: Self.font(size: fontSize), options: TerminalSurfaceLimits.options
        )
        output = TerminalOutputBridge(feed: view.feedSender)
        super.init()
        view.terminalDelegate = self
        view.registerForDraggedTypes([.fileURL])
        view.setAccessibilityLabel("Terminal")
        view.cursorBlinkResetsOnInput = false
        view.suspendsRenderingWhenNotVisible = true
        view.nativeBackgroundColor = TerminalTheme.background
        view.nativeForegroundColor = TerminalTheme.foreground
        view.installColors(TerminalTheme.ansi)
    }

    /// Pass to `ProcessSupervisor.launch(outputSink:)`; it replaces the core's
    /// byte scrollback, so this run has only the engine's bounded history.
    public var outputSink: any TerminalOutputSink { output }

    public var gridSize: (rows: UInt16, columns: UInt16) {
        let size = view.terminalDimensions
        return (UInt16(clamping: max(1, size.rows)), UInt16(clamping: max(1, size.cols)))
    }

    /// `inputGate` lets an automatic idle stop close this run's input queue
    /// atomically (late input is then rejected visibly, never lost silently).
    public func attach(runID: UUID, endpoint: TerminalEndpoint, inputGate: TerminalInputGate? = nil) {
        guard case let .launching(early) = input else { return }
        self.runID = runID
        let queue = TerminalInputQueue(
            endpoint: endpoint, capacity: TerminalSurfaceLimits.pendingInputBytes
        ) { [weak self] error in
            Task { @MainActor in self?.report(error) }
        }
        input = .attached(queue, endpoint)
        self.inputGate = inputGate
        inputGate?.register(runID: runID, queue: queue)
        queue.enqueue(early)
        // The grid may have changed between launch and attach.
        let size = gridSize
        requestResize(rows: size.rows, columns: size.columns)
    }

    /// The run ended; input is refused and no work continues for this view.
    public func runEnded() {
        if let runID { inputGate?.unregister(runID: runID) }
        inputGate = nil
        input = .ended
        resizeTask?.cancel()
        resizeTask = nil
    }

    /// The run ended and its screen stays on show: like `runEnded()`, but nothing typed, pasted or dropped
    /// reaches anything, and nothing is reported either (a refused write would raise an error banner
    /// for every key). Selecting and copying text still work.
    public func keepAsReadOnly() {
        runEnded()
        isReadOnly = true
    }

    public var isKeptReadOnly: Bool { isReadOnly }

    public var statistics: TerminalSurfaceStatistics {
        let counters = output.snapshot
        let engine = view.diagnostics
        var pending = 0
        if case let .attached(queue, _) = input { pending = queue.pendingByteCount }
        return TerminalSurfaceStatistics(
            runID: runID, outputBytes: counters.bytes, outputBatches: counters.batches,
            maxFeedMilliseconds: Double(counters.maxFeedNanoseconds) / 1_000_000,
            feedHistogramMicroseconds: counters.feedHistogram,
            lastOutputUptimeNanoseconds: counters.lastReceiveUptimeNanoseconds,
            engineBytesFed: engine.bytesFed, frames: engine.frames, renders: engine.renders,
            pendingInputBytes: pending, inputErrors: inputErrors,
            mainBufferLines: engine.mainBufferLines, alternateBufferLines: engine.alternateBufferLines,
            mainBufferCapacity: engine.mainBufferCapacity, alternateBufferCapacity: engine.alternateBufferCapacity,
            resizePendingJobs: resizeTask == nil ? 0 : 1
        )
    }

    /// Weak-inventory targets for evidence; callers must not retain this array.
    public var resourceObjectsForEvidence: [AnyObject] {
        if case let .attached(queue, _) = input { return [output, queue] }
        return [output]
    }

    public func screenText() -> String {
        String(decoding: view.getBufferAsData(kind: .active), as: UTF8.self)
    }

    // MARK: TerminalViewDelegate

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        switch input {
        case var .launching(early):
            guard early.count + data.count <= 64 * 1024 else {
                report(.overflow(pending: early.count, rejected: data.count, capacity: 64 * 1024))
                return
            }
            early.append(contentsOf: data)
            input = .launching(early)
        case let .attached(queue, _):
            queue.enqueue(data)
        case .ended:
            if !isReadOnly { report(.writeFailed("run has ended")) }
        }
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        requestResize(rows: UInt16(clamping: max(1, newRows)),
                      columns: UInt16(clamping: max(1, newCols)))
    }

    public func setTerminalTitle(source: TerminalView, title: String) {
        onTitle?(String(title.prefix(512)))
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func scrolled(source: TerminalView, position: Double) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    public func bell(source: TerminalView) {}
    public func clipboardCopy(source: TerminalView, content: Data) {}
    public func clipboardRead(source: TerminalView) -> Data? { nil }

    /// Only HTTP(S) and existing local files; arbitrary schemes never run.
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = Self.openableLink(link) else { return }
        NSWorkspace.shared.open(url)
    }

    public func setFontSize(_ size: Double) {
        view.font = Self.font(size: size.isFinite ? size : 14)
    }

    static func openableLink(_ link: String) -> URL? {
        let url: URL
        if link.hasPrefix("/") {
            url = URL(fileURLWithPath: link)
        } else {
            guard let parsed = URL(string: link) else { return nil }
            url = parsed
        }
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            return url.host?.isEmpty == false ? url : nil
        }
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        let file = url.standardizedFileURL
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    // MARK: Private

    /// Coalesces to the latest size; one ioctl is in flight at a time.
    private func requestResize(rows: UInt16, columns: UInt16) {
        requestedSize = (rows, columns)
        guard resizeTask == nil, case let .attached(_, endpoint) = input else { return }
        resizeTask = Task { [weak self] in
            while let self, let size = self.requestedSize {
                self.requestedSize = nil
                do { try await endpoint.resize(rows: size.rows, columns: size.columns) }
                catch { break } // A closed run has no size to keep.
            }
            self?.resizeTask = nil
        }
    }

    private func report(_ error: TerminalInputError) {
        if inputErrors.count < 20 { inputErrors.append(error.description) }
        onInputError?(error)
    }

    static func font(size: CGFloat) -> NSFont {
        let size = min(20, max(11, size))
        return NSFont(name: "SFMono-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// Engine view with Loom's paste rule (CHECKPOINT-5-HISTORY §4.1): an image-only clipboard
/// is forwarded as Ctrl+V for CLIs that read clipboard images themselves; and Loom's Option
/// rule (see `keyDown`).
public final class LoomTerminalView: TerminalView {
    /// Option is the keyboard layout's character layer first, Meta second. A combination that
    /// types a character (Turkish Q: Option+Q is "@", Option+8 "[", Option+P "π") or starts a dead
    /// key (Option+\ then Space is "`") goes to the input system as typing; everything else stays
    /// Meta: Option+Return (newline in Claude Code), Option+Backspace, Option+arrows, Option+Space.
    /// Letter shortcuts that need Meta (Alt+B/F, Option+P/T in Claude Code) therefore type their
    /// character on layouts that have one, as in Terminal.app, iTerm2 and kitty by default (Ghostty
    /// does the same outside the US layouts). Cmd+Option+O turns Meta off for the terminal.
    public override func keyDown(with event: NSEvent) {
        guard optionAsMetaKey, Self.optionTypes(event) else {
            super.keyDown(with: event)
            return
        }
        optionAsMetaKey = false
        defer { optionAsMetaKey = true }
        super.keyDown(with: event)
    }

    /// Option without Command or Control, and the layout makes it typing: printable text that is
    /// not the bare key and not whitespace (Option+Space is a no-break space), or a dead key (no
    /// text yet; the input system composes it with the next key).
    static func optionTypes(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.option), flags.isDisjoint(with: [.command, .control]),
              let bare = event.charactersIgnoringModifiers, !bare.isEmpty,
              !bare.unicodeScalars.contains(where: isFunctionKey),
              let typed = event.characters else { return false }
        if typed.isEmpty { return true }   // dead key
        guard typed != bare else { return false }
        return typed.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && !(0x7f...0x9f).contains(scalar.value)
                && !scalar.properties.isWhitespace && !isFunctionKey(scalar)
        }
    }

    private static func isFunctionKey(_ scalar: Unicode.Scalar) -> Bool {
        (0xF700...0xF8FF).contains(scalar.value)   // AppKit's private-use function-key range
    }

    static func quotedPaths(_ urls: [URL]) -> String {
        urls.filter(\.isFileURL).map { url in
            var quoted = "'"
            for scalar in url.path.unicodeScalars {
                if scalar == "'" {
                    quoted += "'\"'\"'"
                } else if scalar.value < 0x20 || scalar.value == 0x7f {
                    // Keep control bytes out of input; the shell reconstructs
                    // them only when the user submits the line.
                    quoted += "'$'\\x" + String(format: "%02x", scalar.value) + "''"
                } else {
                    quoted.unicodeScalars.append(scalar)
                }
            }
            return quoted + "'"
        }.joined(separator: " ")
    }

    private func droppedFiles(_ sender: any NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? [] : .copy
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        insertDroppedFiles(droppedFiles(sender))
    }

    @discardableResult
    public func insertDroppedFiles(_ urls: [URL]) -> Bool {
        let text = Self.quotedPaths(urls)
        guard !text.isEmpty else { return false }
        pasteText(text)
        return true
    }

    public override func paste(_ sender: Any) {
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string) == nil,
           pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) {
            send(data: [0x16])
            return
        }
        super.paste(sender)
    }
}
