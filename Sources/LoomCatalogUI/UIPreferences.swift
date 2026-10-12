import Foundation

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
    public var selectedSessionID: UUID?
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

    public static let maxOpenTabs = 8

    public init(viewMode: CatalogViewMode = .activity, selectedSessionID: UUID? = nil,
                sidebarWidth: Double = UIPreferences.defaultSidebarWidth,
                sidebarCollapsed: Bool = false, terminalFontSize: Double = UIPreferences.defaultTerminalFontSize,
                openTabs: [UUID] = [], windowFrame: WindowFrame? = nil, projectColors: Bool = true,
                showInMenuBar: Bool = true, notifyApprovals: Bool = true) {
        self.viewMode = viewMode
        self.selectedSessionID = selectedSessionID
        self.sidebarWidth = Self.clamped(sidebarWidth)
        self.sidebarCollapsed = sidebarCollapsed
        self.terminalFontSize = Self.clampedFontSize(terminalFontSize)
        self.openTabs = Self.normalizedTabs(openTabs)
        self.windowFrame = windowFrame.flatMap { $0.isValid ? $0 : nil }
        self.projectColors = projectColors
        self.showInMenuBar = showInMenuBar
        self.notifyApprovals = notifyApprovals
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown or missing keys fall back to defaults.
        self.init(
            viewMode: (try? container.decodeIfPresent(CatalogViewMode.self, forKey: .viewMode)) ?? .activity,
            selectedSessionID: try? container.decodeIfPresent(UUID.self, forKey: .selectedSessionID),
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
            notifyApprovals: (try? container.decodeIfPresent(Bool.self, forKey: .notifyApprovals)) ?? true
        )
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
