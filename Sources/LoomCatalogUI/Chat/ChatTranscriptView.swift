import AppKit
import LoomChat
import QuickLookUI
import SwiftUI

/// The chat view of a Claude session whose history is a transcript file: every session's history, readable as chat.
/// Read only for a stopped session; a live tail for a session running in a terminal. Release B's live chat reuses it.
///
/// - Parameters:
///   - sessionID: the Claude session id (the transcript is `<config>/projects/<folder>/<id>.jsonl`).
///   - configDirectory: the Claude config directory of the profile that ran the session (`CLAUDE_CONFIG_DIR`, or `~/.claude`
///     for the default profile).
///   - workingDirectory: the session's folder; Claude names the transcript's folder after it, and tool paths are shown
///     relative to it.
///   - isWorking: the session works now (its newest turn is live: never folded, ending in the live row). Read from the
///     session's status by the owner; false for a stopped session.
///   - onOpenSubagent: a subagent card was clicked (the inspector's Agents tab opens it): its agent id, when known, and the
///     id of the Agent call.
///   - onOpenChanges: a changed-files card's "Open in Changes" was clicked; `true` when the card is the newest turn's.
///   - fallback: drawn when no transcript resolves (the kept last screen, D-54).
public struct ChatTranscriptView<Fallback: View>: View {
    private let sessionID: String
    private let configDirectory: URL
    private let workingDirectory: String?
    private let isWorking: Bool
    private let onOpenSubagent: ((String?, String) -> Void)?
    private let onOpenChanges: ((Bool) -> Void)?
    private let fallback: () -> Fallback
    /// Made when the view first shows a session and again when the session changes, never on a parent's re-render: a model
    /// owns a scroll view, a table, a measurer and observers.
    @State private var model: ChatTranscriptModel?

    public init(sessionID: String, configDirectory: URL, workingDirectory: String?, isWorking: Bool = false,
                onOpenSubagent: ((String?, String) -> Void)? = nil, onOpenChanges: ((Bool) -> Void)? = nil,
                @ViewBuilder fallback: @escaping () -> Fallback) {
        self.sessionID = sessionID
        self.configDirectory = configDirectory
        self.workingDirectory = workingDirectory
        self.isWorking = isWorking
        self.onOpenSubagent = onOpenSubagent
        self.onOpenChanges = onOpenChanges
        self.fallback = fallback
    }

    public var body: some View {
        ZStack {
            if let model {
                ChatTranscriptContent(model: model, isWorking: isWorking, onOpenSubagent: onOpenSubagent,
                                      onOpenChanges: onOpenChanges, fallback: fallback)
                    .id(ObjectIdentifier(model))
            } else {
                LoomTheme.Surface.canvas
            }
        }
        .task(id: Subject(sessionID: sessionID, configPath: configDirectory.path)) { show() }
        .onChange(of: workingDirectory) { _, value in model?.setWorkingDirectory(value) }
    }

    private struct Subject: Hashable {
        var sessionID: String
        var configPath: String
    }

    private func show() {
        if let model, model.sessionID == sessionID, model.configDirectory == configDirectory { return }
        model?.close()
        model = ChatTranscriptModel(sessionID: sessionID, configDirectory: configDirectory, workingDirectory: workingDirectory,
                                    isWorking: isWorking)
    }
}

/// The view over a model (the tests and the screenshot harness build the model themselves).
struct ChatTranscriptContent<Fallback: View>: View {
    let model: ChatTranscriptModel
    let isWorking: Bool
    let onOpenSubagent: ((String?, String) -> Void)?
    var onOpenChanges: ((Bool) -> Void)?
    let fallback: () -> Fallback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width = LoomTheme.Chat.chipCompactBelow

    var body: some View {
        ZStack {
            LoomTheme.Surface.canvas
            switch model.phase {
            case .resolving:
                Color.clear
            case .unavailable:
                fallback()
            case .ready:
                stream
            }
            ChatWindowVisibility { model.setWindowVisible($0) }.frame(width: 0, height: 0)
        }
        .onAppear {
            model.onOpenSubagent = onOpenSubagent
            model.onOpenChanges = onOpenChanges
            model.setWorking(isWorking)
            model.setOnScreen(true)
        }
        .onDisappear { model.setOnScreen(false) }
        .onChange(of: isWorking) { _, value in model.setWorking(value) }
    }

    private var stream: some View {
        ZStack(alignment: .bottom) {
            ChatStreamHost(controller: model.controller)
            VStack(spacing: 8) {
                if model.showsJump {
                    ChatJumpPill { model.jumpToLatest() }
                        .transition(reduceMotion ? .identity : .opacity)
                }
                if model.unknownRecordCount > 0, !model.driftDismissed {
                    ChatDriftNotice(count: model.unknownRecordCount) { model.dismissDrift() }
                }
            }
            .padding(.bottom, 12)
            .animation(reduceMotion ? nil : .easeOut(duration: LoomTheme.Chat.fadeDuration), value: model.showsJump)
        }
        .overlay(alignment: .topTrailing) {
            ChatViewChip(mode: model.viewMode, compact: ChatViewChip.isCompact(width: width)) { model.cycleViewMode() }
                .padding(.top, 10).padding(.trailing, 14)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

// MARK: Overlays

/// The view switch: Normal, Thinking, Verbose. ⌃O cycles it only while the stream has focus (the table's key handling), so
/// it never takes the key from a terminal beside the chat. A 24 pt chip, radius 6, on the canvas at 92 % with an inset edge.
struct ChatViewChip: View {
    let mode: ChatViewMode
    /// The glyph and the key only (a narrow stream); the tooltip and the accessibility value still name the view.
    var compact = false
    let cycle: () -> Void
    @State private var hovering = false

    /// Whether a stream this wide gets the compact chip.
    static func isCompact(width: CGFloat) -> Bool { width < LoomTheme.Chat.chipCompactBelow }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.InkRadius.control)
        Button(action: cycle) {
            HStack(spacing: compact ? 5 : 7) {
                Image(systemName: "eye").font(LoomTheme.Chat.linkSymbol)
                if !compact { Text(mode.title) }
                KeyChip(text: "\u{2303}O")
            }
            .font(LoomTheme.Chat.viewChip)
            .foregroundStyle(hovering ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
            .padding(.leading, compact ? 5 : 8).padding(.trailing, 5).frame(height: LoomTheme.Chat.viewChipHeight)
            .background(shape.fill(LoomTheme.Chat.viewChipFill))
            .overlay(shape.strokeBorder(hovering ? LoomTheme.Surface.strongerHairline : LoomTheme.Surface.strongHairline))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("View: \(mode.title). Click for the next view: Normal, Thinking, Verbose. Control-O does the same while the session has focus.")
        .accessibilityLabel("View")
        .accessibilityValue(mode.title)
        .accessibilityHint("Shows the next view")
    }
}

/// "Jump to Latest": a pill on the popover level (its fill, hairline and shadow), 28 pt. The host places it above the composer
/// and fades it in over 150 ms.
struct ChatJumpPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down").font(LoomTheme.Chat.linkSymbol)
                Text("Jump to Latest")
            }
            .font(LoomTheme.Chat.jumpPill)
            .foregroundStyle(LoomTheme.Text.primary)
            .padding(.leading, LoomTheme.Chat.jumpPillPaddingLeading).padding(.trailing, LoomTheme.Chat.jumpPillPaddingTrailing)
            .frame(height: LoomTheme.Chat.jumpPillHeight)
            .background(Capsule().fill(LoomTheme.Chat.jumpFill))
            .overlay(Capsule().strokeBorder(LoomTheme.Surface.hairlineStyle))
            .depth(LoomTheme.Elevation.popover)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to Latest")
    }
}

/// One notice per session when records of an unknown shape were kept as raw rows.
struct ChatDriftNotice: View {
    let count: Int
    let dismiss: () -> Void

    var body: some View {
        ChatNotice(message: "\(count) record\(count == 1 ? "" : "s") in this session \(count == 1 ? "has" : "have") a shape Sphyrna does not know. They show as raw rows.",
                   dismiss: dismiss)
    }
}

/// A dismissible notice over the bottom of the stream.
struct ChatNotice: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle").font(LoomTheme.Chat.rowIcon).foregroundStyle(LoomTheme.Status.attentionLight)
            Text(message)
                .font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.primary).lineLimit(2)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(LoomTheme.Chat.chevron).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Dismiss")
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.md).fill(LoomTheme.Surface.card))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.md).strokeBorder(LoomTheme.Surface.hairlineStyle))
        .frame(maxWidth: LoomTheme.Chat.column - 2 * LoomTheme.Chat.columnPadding)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Window visibility

/// Tells the model when the window can be seen: shown, not minimised, not covered, the app not hidden.
struct ChatWindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) { view.onChange = onChange }

    @MainActor
    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            guard let window else { return report(false) }
            let center = NotificationCenter.default
            let names: [(Notification.Name, AnyObject?)] = [
                (NSWindow.didChangeOcclusionStateNotification, window), (NSWindow.didMiniaturizeNotification, window),
                (NSWindow.didDeminiaturizeNotification, window), (NSApplication.didHideNotification, nil),
                (NSApplication.didUnhideNotification, nil),
            ]
            for (name, object) in names {
                observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.evaluate() }
                })
            }
            evaluate()
        }

        private func evaluate() {
            guard let window else { return report(false) }
            report(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible) && !NSApp.isHidden)
        }

        private func report(_ visible: Bool) {
            guard last != visible else { return }
            last = visible
            onChange?(visible)
        }

        isolated deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

// MARK: Quick Look

/// An image of the transcript, opened in Quick Look from a temporary file.
@MainActor
enum ChatQuickLook {
    private static let source = Source()
    private static var urls: [URL] = []

    static func show(_ image: ImageRef) {
        guard let encoded = image.data, let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loom-chat-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for old in urls { try? FileManager.default.removeItem(at: old) }
        let ext = image.mediaType == "image/jpeg" ? "jpg" : image.mediaType == "image/gif" ? "gif" : image.mediaType == "image/webp" ? "webp" : "png"
        let url = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        urls = [url]
        source.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = source
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    private final class Source: NSObject, QLPreviewPanelDataSource {
        var url: URL?
        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url as NSURL? }
    }
}
