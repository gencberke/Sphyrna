import Foundation
import LoomCore
import LoomRemora

/// The main window's frame in screen coordinates (AppKit, bottom-left origin).
public struct WindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// The saved frame to open with, or nil when the default centered one applies.
    public func restorable(onScreens screens: [CGRect]) -> CGRect? {
        let frame = rect
        guard isValid else { return nil }
        let fits = screens.contains { visible in
            let overlap = frame.intersection(visible)
            guard !overlap.isNull else { return false }
            // Mostly on this screen, and the title bar is not under the menu bar.
            return overlap.width * overlap.height >= frame.width * frame.height / 2
                && frame.maxY <= visible.maxY
        }
        return fits ? frame : nil
    }

    /// Finite, and not smaller than the window's minimum size.
    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && width >= UIPreferences.windowMinimumSize.width && height >= UIPreferences.windowMinimumSize.height
    }
}

public enum CatalogViewMode: String, Codable, Sendable, CaseIterable {
    case activity
    case projects
}

/// Settings → Theme → Sidebar (D-57; General until D-63). Solid, the opaque canvas, is the default (D-81); Glass is the canvas at
/// 0.8 over the behind-window material. A stored choice is kept. Reduce Transparency draws Solid whatever this says.
/// The cases are in the segment's order, Solid first (DESIGN §5); the raw values are what is stored.
public enum SidebarStyle: String, Codable, Sendable, CaseIterable {
    case solid
    case glass

    /// The label in Settings.
    public var title: String {
        switch self {
        case .solid: "Solid"
        case .glass: "Glass"
        }
    }
}

/// Settings → Theme → Appearance (D-63). Ink (dark) is the default, so a file written before the setting existed
/// looks as it did; Match system follows macOS live. The terminal face stays dark whatever this says. The raw values
/// are the stored ones and stay `dark`, `light` and `system`.
public enum AppearanceSetting: String, Codable, Sendable, CaseIterable {
    case dark
    case light
    case system

    /// The label in Settings.
    public var title: String {
        switch self {
        case .dark: "Ink"
        case .light: "Paper"
        case .system: "Match system"
        }
    }
}

/// Settings → Theme → Tone (D-63, D-81): the cast over Ink's six greys (DESIGN §3 Tones). Neutral is Ink's own greys, Warm
/// and Cool cast them; every other token stays as it is. The terminal face takes the tone's canvas.
public enum PaneTone: String, Codable, Sendable, CaseIterable {
    case neutral
    case warm
    case cool

    /// The label in Settings.
    public var title: String {
        switch self {
        case .neutral: "Neutral"
        case .warm: "Warm"
        case .cool: "Cool"
        }
    }

    /// The line under the label.
    public var detail: String {
        switch self {
        case .neutral: "Ink's own greys."
        case .warm: "A slight brown cast."
        case .cool: "A slight blue cast."
        }
    }

    /// The tones Night Fleece 2 stored, and the cast each became.
    private static let legacy: [String: PaneTone] = ["nightFleece": .neutral, "workshop": .warm, "instrument": .cool]

    /// A stored `nightFleece`, `workshop` or `instrument` decodes as `neutral`, `warm` or `cool`; an unknown string as
    /// `neutral`. A value that is not a string fails, and `UIPreferences` falls back to `neutral` for it.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaneTone(rawValue: raw) ?? Self.legacy[raw] ?? .neutral
    }
}

/// What the main window opens on (Settings, later). `home` opens Home whatever was stored; only `lastSession`
/// brings back the destination the window was closed with.
public enum LaunchView: String, Codable, Sendable, CaseIterable {
    case home
    case lastSession
}

/// Presentation preferences only. Conversation identity, provider state and
/// lifecycle stay in the catalog and the supervisor.
public struct UIPreferences: Codable, Equatable, Sendable {
    public static let sidebarWidthRange: ClosedRange<Double> = 220...520
    public static let defaultSidebarWidth = 300.0
    public static let terminalFontSizeRange: ClosedRange<Double> = 11...20
    public static let defaultTerminalFontSize = 14.0
    /// First launch opens at the default size, centered; no window gets smaller than the minimum.
    public static let defaultWindowSize = CGSize(width: 1220, height: 780)
    public static let windowMinimumSize = CGSize(width: 780, height: 500)

    public var viewMode: CatalogViewMode
    /// Where the window was when it closed (a session, Home or a project page). A file written before
    /// destinations existed holds only `selectedSessionID`, which reads as the session destination.
    public var destination: Destination?
    public var sidebarWidth: Double
    public var sidebarCollapsed: Bool
    public var terminalFontSize: Double
    /// Pinned conversation tabs, in strip order (D-33). De-duplicated and capped.
    public var openTabs: [UUID]
    /// Where the main window last was; nil until the user moves or resizes it.
    public var windowFrame: WindowFrame?
    /// Settings → General → Project colors (D-48). Off draws no project colour anywhere and keeps the
    /// stored ones; a file written before the setting existed reads as on.
    public var projectColors: Bool
    /// Settings → General → Show in menu bar (D-49, D-52). Off removes the status item. A file written
    /// before the setting existed reads as on.
    public var showInMenuBar: Bool
    /// Settings → General → Notify when a session needs approval. A file written before the setting
    /// existed reads as on. (Open at login is not a preference: the system holds it.)
    public var notifyApprovals: Bool
    /// Settings → General → Sidebar: Glass or Solid (D-57). A file written before the setting existed reads as Solid (D-81).
    public var sidebarStyle: SidebarStyle
    /// What the window opens on. A file written before the setting existed reads as the last session.
    public var launchView: LaunchView
    /// The sessions whose inspector is open (V2: closed by default, remembered per session). Least recently
    /// opened first, de-duplicated and capped.
    public var inspectorOpen: [UUID]
    /// The inspector's remembered width per class (W1-b), written once per release of its resize handle. A file written before
    /// the setting existed reads as the defaults, and so does any class that is missing or unreadable.
    public var inspectorWidths: InspectorWidths
    /// Settings → General → Search session text. Off, the command palette never reads a transcript. A file written
    /// before the setting existed reads as on.
    public var searchSessionText: Bool
    /// Settings → General → Sessions run in (V19, D-69). The face of every Claude session as it starts or resumes; a
    /// running session keeps its face until it stops. The key keeps its old name. A file written before the setting
    /// existed reads as Chat.
    public var newSessionFace: SessionFace
    /// Settings → Theme → Appearance (D-63). A file written before the setting existed reads as Dark.
    public var appearance: AppearanceSetting
    /// Settings → Theme → Tone (D-63, D-81). A file written before the setting existed reads as Neutral.
    public var paneTone: PaneTone
    /// Settings → Theme → Animated art (DESIGN §17, D-79). On, the art moves, under Reduce Motion too; off, every drawing stands
    /// still on one frame. A file written before the setting existed reads as on.
    public var animatedArt: Bool
    /// Remora's settings (LOMBOT §6.2); the defaults live in `RemoraPreferences`. A file written before Remora existed reads as
    /// those defaults, and so does any field of it that is missing or unreadable.
    public var remora: RemoraPreferences
    /// Settings → General → Keep Mac awake. A file written before the setting existed reads as Off.
    public var keepAwake: KeepAwakeSetting = .off
    /// Settings → General → Notify when a long turn finishes. A file written before the setting existed reads as off.
    public var notifyLongTurns = false

    /// The selected session, as every caller before destinations knew it; setting it sets the destination.
    /// The key is still written when the destination is a session, so an older build reads it too.
    public var selectedSessionID: UUID? {
        get { destination?.sessionID }
        set { destination = newValue.map(Destination.session) }
    }

    public static let maxOpenTabs = 8
    public static let maxInspectorSessions = 64

    public init(viewMode: CatalogViewMode = .activity, selectedSessionID: UUID? = nil, destination: Destination? = nil,
                sidebarWidth: Double = UIPreferences.defaultSidebarWidth,
                sidebarCollapsed: Bool = false, terminalFontSize: Double = UIPreferences.defaultTerminalFontSize,
                openTabs: [UUID] = [], windowFrame: WindowFrame? = nil, projectColors: Bool = true,
                showInMenuBar: Bool = true, notifyApprovals: Bool = true, sidebarStyle: SidebarStyle = .solid,
                launchView: LaunchView = .lastSession, inspectorOpen: [UUID] = [],
                inspectorWidths: InspectorWidths = InspectorWidths(), searchSessionText: Bool = true,
                newSessionFace: SessionFace = .chat,
                appearance: AppearanceSetting = .dark, paneTone: PaneTone = .neutral, animatedArt: Bool = true,
                remora: RemoraPreferences = RemoraPreferences()) {
        self.viewMode = viewMode
        self.destination = destination ?? selectedSessionID.map(Destination.session)
        self.sidebarWidth = Self.clamped(sidebarWidth)
        self.sidebarCollapsed = sidebarCollapsed
        self.terminalFontSize = Self.clampedFontSize(terminalFontSize)
        self.openTabs = Self.normalizedTabs(openTabs)
        self.windowFrame = windowFrame.flatMap { $0.isValid ? $0 : nil }
        self.projectColors = projectColors
        self.showInMenuBar = showInMenuBar
        self.notifyApprovals = notifyApprovals
        self.sidebarStyle = sidebarStyle
        self.launchView = launchView
        self.inspectorOpen = Self.normalizedInspectors(inspectorOpen)
        self.inspectorWidths = inspectorWidths
        self.searchSessionText = searchSessionText
        self.newSessionFace = newSessionFace
        self.appearance = appearance
        self.paneTone = paneTone
        self.animatedArt = animatedArt
        self.remora = remora
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown or missing keys fall back to defaults.
        self.init(
            viewMode: (try? container.decodeIfPresent(CatalogViewMode.self, forKey: .viewMode)) ?? .activity,
            selectedSessionID: try? container.decodeIfPresent(UUID.self, forKey: .selectedSessionID),
            // The newer key wins; an unreadable one falls back to the selected session.
            destination: (try? container.decodeIfPresent(Destination.self, forKey: .destination)) ?? nil,
            sidebarWidth: (try? container.decodeIfPresent(Double.self, forKey: .sidebarWidth))
                ?? Self.defaultSidebarWidth,
            sidebarCollapsed: (try? container.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed)) ?? false,
            terminalFontSize: (try? container.decodeIfPresent(Double.self, forKey: .terminalFontSize))
                ?? Self.defaultTerminalFontSize,
            // One unreadable entry drops only itself, not the whole list.
            openTabs: ((try? container.decodeIfPresent([Lossy<UUID>].self, forKey: .openTabs)) ?? nil)?
                .compactMap(\.value) ?? [],
            windowFrame: (try? container.decodeIfPresent(WindowFrame.self, forKey: .windowFrame)) ?? nil,
            projectColors: (try? container.decodeIfPresent(Bool.self, forKey: .projectColors)) ?? true,
            showInMenuBar: (try? container.decodeIfPresent(Bool.self, forKey: .showInMenuBar)) ?? true,
            notifyApprovals: (try? container.decodeIfPresent(Bool.self, forKey: .notifyApprovals)) ?? true,
            sidebarStyle: (try? container.decodeIfPresent(SidebarStyle.self, forKey: .sidebarStyle)) ?? .solid,
            launchView: (try? container.decodeIfPresent(LaunchView.self, forKey: .launchView)) ?? .lastSession,
            inspectorOpen: ((try? container.decodeIfPresent([Lossy<UUID>].self, forKey: .inspectorOpen)) ?? nil)?
                .compactMap(\.value) ?? [],
            inspectorWidths: (try? container.decodeIfPresent(InspectorWidths.self, forKey: .inspectorWidths)) ?? InspectorWidths(),
            searchSessionText: (try? container.decodeIfPresent(Bool.self, forKey: .searchSessionText)) ?? true,
            newSessionFace: (try? container.decodeIfPresent(SessionFace.self, forKey: .newSessionFace)) ?? .chat,
            appearance: (try? container.decodeIfPresent(AppearanceSetting.self, forKey: .appearance)) ?? .dark,
            paneTone: (try? container.decodeIfPresent(PaneTone.self, forKey: .paneTone)) ?? .neutral,
            animatedArt: (try? container.decodeIfPresent(Bool.self, forKey: .animatedArt)) ?? true,
            remora: (try? container.decodeIfPresent(RemoraPreferences.self, forKey: .remora)) ?? RemoraPreferences()
        )
        keepAwake = (try? container.decodeIfPresent(KeepAwakeSetting.self, forKey: .keepAwake)) ?? .off
        notifyLongTurns = (try? container.decodeIfPresent(Bool.self, forKey: .notifyLongTurns)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case viewMode, selectedSessionID, destination, sidebarWidth, sidebarCollapsed, terminalFontSize, openTabs
        case windowFrame, projectColors, showInMenuBar, notifyApprovals, sidebarStyle, launchView, inspectorOpen
        case inspectorWidths, searchSessionText, newSessionFace, appearance, paneTone, animatedArt, remora
        case keepAwake, notifyLongTurns
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(viewMode, forKey: .viewMode)
        try container.encodeIfPresent(destination, forKey: .destination)
        try container.encodeIfPresent(selectedSessionID, forKey: .selectedSessionID)
        try container.encode(sidebarWidth, forKey: .sidebarWidth)
        try container.encode(sidebarCollapsed, forKey: .sidebarCollapsed)
        try container.encode(terminalFontSize, forKey: .terminalFontSize)
        try container.encode(openTabs, forKey: .openTabs)
        try container.encodeIfPresent(windowFrame, forKey: .windowFrame)
        try container.encode(projectColors, forKey: .projectColors)
        try container.encode(showInMenuBar, forKey: .showInMenuBar)
        try container.encode(notifyApprovals, forKey: .notifyApprovals)
        try container.encode(sidebarStyle, forKey: .sidebarStyle)
        try container.encode(launchView, forKey: .launchView)
        try container.encode(inspectorOpen, forKey: .inspectorOpen)
        try container.encode(inspectorWidths, forKey: .inspectorWidths)
        try container.encode(searchSessionText, forKey: .searchSessionText)
        try container.encode(newSessionFace, forKey: .newSessionFace)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(paneTone, forKey: .paneTone)
        try container.encode(animatedArt, forKey: .animatedArt)
        try container.encode(remora, forKey: .remora)
        try container.encode(keepAwake, forKey: .keepAwake)
        try container.encode(notifyLongTurns, forKey: .notifyLongTurns)
    }

    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
    }

    /// First occurrence wins; at most `maxOpenTabs` entries.
    static func normalizedTabs(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return Array(ids.filter { seen.insert($0).inserted }.prefix(maxOpenTabs))
    }

    /// First occurrence wins; the newest `maxInspectorSessions` entries are kept.
    static func normalizedInspectors(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return Array(ids.filter { seen.insert($0).inserted }.suffix(maxInspectorSessions))
    }

    public static func clampedFontSize(_ size: Double) -> Double {
        guard size.isFinite else { return defaultTerminalFontSize }
        return min(max(size, terminalFontSizeRange.lowerBound), terminalFontSizeRange.upperBound)
    }

    static func clamped(_ width: Double) -> Double {
        guard width.isFinite else { return defaultSidebarWidth }
        return min(max(width, sidebarWidthRange.lowerBound), sidebarWidthRange.upperBound)
    }
}

/// Bundle-specific preferences file inside the app's data directory (Loom-Dev
/// and Loom never share it). Written atomically, and only when a value changed.
@MainActor
public final class UIPreferencesStore {
    public let url: URL
    public private(set) var current: UIPreferences
    /// Set when an unreadable file was moved aside at load time.
    public private(set) var loadNotice: String?
    private var lastSaved: UIPreferences?
    /// Number of successful file writes (tests and evidence).
    public private(set) var writeCount = 0

    public init(url: URL) {
        self.url = url
        var loaded = UIPreferences()
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode(UIPreferences.self, from: data) {
                loaded = decoded
                lastSaved = decoded
            } else {
                let aside = url.deletingLastPathComponent()
                    .appendingPathComponent("ui-preferences.unreadable-\(Int(Date().timeIntervalSince1970)).json")
                if (try? FileManager.default.moveItem(at: url, to: aside)) != nil {
                    loadNotice = "Preferences could not be read; defaults are used and the old file was kept as \(aside.lastPathComponent)."
                } else {
                    loadNotice = "Preferences could not be read; defaults are used."
                }
            }
        }
        current = loaded
    }

    /// Applies the change and writes it when it differs from what is on disk.
    /// Throws when the write fails; the in-memory value is kept either way so
    /// the window stays consistent, and the caller reports the failure.
    public func update(_ change: (inout UIPreferences) -> Void) throws {
        apply(change)
        try flush()
    }

    /// Applies the change in memory only; `flush()` (or the next `update`)
    /// writes it. Lets rapid changes such as tab switching coalesce into one write.
    public func apply(_ change: (inout UIPreferences) -> Void) {
        var updated = current
        change(&updated)
        updated.sidebarWidth = UIPreferences.clamped(updated.sidebarWidth)
        updated.terminalFontSize = UIPreferences.clampedFontSize(updated.terminalFontSize)
        updated.openTabs = UIPreferences.normalizedTabs(updated.openTabs)
        updated.inspectorOpen = UIPreferences.normalizedInspectors(updated.inspectorOpen)
        if updated.windowFrame?.isValid == false { updated.windowFrame = nil }
        current = updated
    }

    /// Writes the current value when it differs from what is on disk.
    public func flush() throws {
        guard current != lastSaved else { return }
        let updated = current
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: url, options: .atomic)
        lastSaved = updated
        writeCount += 1
    }
}
