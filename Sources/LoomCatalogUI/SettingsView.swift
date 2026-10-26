import AppKit
import LoomCore
import SwiftUI

public enum SettingsSection: CaseIterable, Identifiable, Hashable, Sendable {
    case general, connections, theme, usage, conversations, remora, about

    public var id: Self { self }
    public var title: String {
        switch self {
        case .general: "General"
        case .connections: "Connections"
        case .theme: "Theme"
        case .usage: "Usage"
        case .conversations: "Sessions"
        case .remora: "Remora"
        case .about: "About"
        }
    }

    /// Conversations (the cleanup review, which deletes) exists only where the app offers it.
    static func available(cleanupReview: Bool) -> [SettingsSection] {
        allCases.filter { $0 != .conversations || cleanupReview }
    }
}

/// Which section the one Settings window shows, and which sheet is open over it. The window controller and the view share it, so
/// the gear (no section) and the footer chip (Usage) reuse the same window.
@MainActor @Observable
public final class SettingsNavigation {
    public var section: SettingsSection
    /// The Full Access, Delete and Clear questions and Remora's memory: sheets of §6's family over the window.
    let sheets = SheetPresenter<SettingsSheet>()
    /// The tab Remora's memory sheet shows.
    public internal(set) var memoryTab: RemoraMemoryTab = .journal
    /// The memory note's two native panels (Choose… and Open); a test replaces them.
    @ObservationIgnored var noteActions: RemoraNoteActions = .live

    public init(section: SettingsSection = .general) { self.section = section }

    /// A requested section wins; no section keeps the one the window already shows.
    public func open(_ requested: SettingsSection?) {
        if let requested, requested != section { section = requested }
    }

    /// Opens Remora's tab with its memory sheet over it, on the tab named (the journal by default). This is the one call a door outside
    /// Settings makes (Home's ⋯ → Memory… and the footer's Memory…): show the window (`showSettings(section: .remora)`), then
    /// `openRemoraMemory()` on its navigation.
    public func openRemoraMemory(tab: RemoraMemoryTab = .journal) {
        section = .remora
        memoryTab = tab
        sheets.present(.remoraMemory)
    }

    /// Clear…: asks first. Nothing is cleared until the question's own button is pressed; from the memory sheet, either answer
    /// brings that sheet back.
    func askToClearRemoraMemory(fromMemorySheet: Bool) { sheets.present(.remoraClear(returnsToMemory: fromMemorySheet)) }

    /// The sheet that is open, if any.
    public var openSheet: SettingsSheet? { sheets.presented }

    /// Opens a sheet without acting on it, or closes the open one (nil). The evidence run uses this.
    public func setSheet(_ sheet: SettingsSheet?) {
        if let sheet { sheets.present(sheet) } else { sheets.dismiss() }
    }
}

/// Read-only facts the About section shows; the app supplies them.
public struct SettingsAbout: Equatable, Sendable {
    public var version: String
    public var dataFolder: URL
    /// The Claude profile usage is read from; nil when there is no usage index.
    public var claudeProfile: URL?

    public init(version: String, dataFolder: URL, claudeProfile: URL?) {
        self.version = version
        self.dataFolder = dataFolder
        self.claudeProfile = claudeProfile
    }
}

/// The Settings window's content: the 52 pt band with the section tabs (General, Connections, Theme, Usage, Sessions where offered, Remora, About), the open
/// section under it, and the sheets over both. One fixed size (DESIGN §2 item 5; the window controller sets the size).
public struct SettingsView: View {
    let model: CatalogModel
    let usage: UsageModel?
    let navigation: SettingsNavigation
    let about: SettingsAbout
    let diagnostics: DiagnosticsCollection?

    public init(model: CatalogModel, usage: UsageModel?, navigation: SettingsNavigation, about: SettingsAbout,
                diagnostics: DiagnosticsCollection? = nil) {
        self.model = model
        self.usage = usage
        self.navigation = navigation
        self.about = about
        self.diagnostics = diagnostics
    }

    public var body: some View {
        VStack(spacing: 0) {
            SettingsBand(sections: SettingsSection.available(cleanupReview: model.cleanupReview != nil),
                         selection: navigation.section, onSelect: { navigation.section = $0 })
                // Over the page for the pointer: the page's scroll view reaches up under the title strip and took the tabs' clicks.
                .zIndex(1)
            switch navigation.section {
            case .general: GeneralSettings(model: model, sheets: navigation.sheets)
            case .connections: ConnectionsSettings(model: model)
            case .theme: ThemeSettings(model: model)
            case .usage: UsageSettings(usage: usage, profile: about.claudeProfile)
            case .remora: RemoraSettingsView(model: model, navigation: navigation)
            case .about: AboutSettings(about: about, diagnostics: diagnostics)
            case .conversations:
                if let review = model.cleanupReview {
                    CleanupReviewView(review: review, catalog: model, sheets: navigation.sheets)
                } else {
                    GeneralSettings(model: model, sheets: navigation.sheets)
                }
            }
        }
        .frame(width: LoomTheme.Settings.width, height: LoomTheme.Settings.height)
        .background(LoomTheme.Surface.canvas)
        .foregroundStyle(LoomTheme.Text.primary)
        .font(LoomTheme.InkType.body.font)
        .tint(LoomTheme.Accent.base)
        .environment(\.animatedArt, model.animatedArt)
        .sheetLayer(navigation.sheets, headerOffset: LoomTheme.Settings.bandHeight) { sheet in
            SettingsSheets.view(for: sheet, model: model, profile: about.claudeProfile, navigation: navigation)
        }
        // After the sheet layer, so the page, the scrim and the sheet's 52 pt are all measured from the window's top, title strip
        // included (DESIGN §6 Sheets, §3 scrim): before it, the layer sat under the title strip's safe area, which stayed undimmed.
        .ignoresSafeArea()
    }
}

// MARK: The band

/// The title band: 52 high with a hairline under it, where the window's title would be. The sections are view tabs, centred, at the
/// band's bottom edge. Only the close button shows, at the left, on the band's centre line.
struct SettingsBand: View {
    let sections: [SettingsSection]
    let selection: SettingsSection
    let onSelect: (SettingsSection) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            ViewTabs(
                tabs: sections.map {
                    ViewTabItem(id: $0, title: $0.title, identifier: "settings-tab-\($0.title)", hoverKey: "settings-tab:\($0.title)")
                },
                selection: selection, onSelect: onSelect)
                .fixedSize(horizontal: true, vertical: false)
                // The tabs bring their own hairline; the canvas under them hides the band's, so the rule is drawn once.
                .background(LoomTheme.Surface.canvas)
        }
        .frame(maxWidth: .infinity)
        .frame(height: LoomTheme.Settings.bandHeight)
        .background(alignment: .bottom) {
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings section")
    }
}

// MARK: General

/// What picking a mode as the default asks: only Full access, and only when it changes the default (D-83).
enum FullAccessRule {
    static func asks(choosing raw: String, current: String?) -> Bool {
        raw == ClaudePermissionMode.fullAccess.rawValue && current != raw
    }
}

struct GeneralSettings: View {
    let model: CatalogModel
    /// Full access, picked as the default, waits here for its question (D-83).
    let sheets: SheetPresenter<SettingsSheet>

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: LoomTheme.Settings.groupGap) {
                SettingsGroup(label: "Sessions") {
                    // D-100: no face to choose while the Chat face is frozen (`ChatFreeze`).
                    if !ChatFreeze.isFrozen {
                        SettingsRow(title: "Sessions run in", detail: Self.sessionFaceDetail) {
                            InkSegmented(values: SessionFace.allCases, title: \.title, selection: model.newSessionFace,
                                         onSelect: { model.setNewSessionFace($0) })
                                .accessibilityLabel("Sessions run in")
                        }
                        SettingsRowDivider()
                    }
                    SettingsRow(title: "Mode of new sessions", detail: Self.startModeDetail) { modePicker }
                    SettingsRowDivider()
                    SettingsRow(title: "Terminal font size", detail: "Applies to existing and new terminals.") {
                        SettingsPopup(
                            title: "Terminal font size",
                            selection: Binding(get: { model.terminalFontSize }, set: { model.setTerminalFontSize($0) }),
                            valueText: "\(Int(model.terminalFontSize)) pt"
                        ) {
                            ForEach(11...20, id: \.self) { size in Text("\(size) pt").tag(Double(size)) }
                        }
                    }
                    SettingsRowDivider()
                    SettingsRow(title: "Search session text",
                                detail: "Let the command palette look inside your sessions. It reads Claude's transcript files only while you type, and keeps nothing. Off, it searches titles, projects and actions.") {
                        SettingsSwitch(title: "Search session text", isOn: Binding(
                            get: { model.searchesSessionText }, set: { model.setSearchesSessionText($0) }))
                    }
                }
                SystemSettingsCard(model: model, integration: model.integration)
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(LoomTheme.Status.failureLight).textSelection(.enabled)
                }
            }
        }
    }

    private var modePicker: some View {
        let current = model.defaultStartMode
        let mode = current.flatMap(ClaudePermissionMode.init(rawValue:))
        return SettingsPopup(
            title: "Mode of new sessions",
            selection: Binding(
                get: { current ?? Self.lastUsedTag },
                set: { chosen in
                    if FullAccessRule.asks(choosing: chosen, current: model.defaultStartMode) {
                        sheets.present(.fullAccess)
                    } else {
                        model.setDefaultStartMode(chosen == Self.lastUsedTag ? nil : chosen)
                    }
                }),
            valueText: mode?.title ?? "Last used in the project",
            icon: current.map { (ComposerModeLook.symbol(forRaw: $0), ComposerModeLook.color(forRaw: $0)) }
        ) {
            Text("Last used in the project").tag(Self.lastUsedTag)
            Divider()
            ForEach(ClaudePermissionMode.menuModes, id: \.rawValue) { mode in
                Text(mode.title).tag(mode.rawValue)
            }
        }
    }

    static let sessionFaceDetail = "Applies when a session starts or resumes. A running session keeps its face until it stops."
    static let startModeDetail = "Last used in the project, or one mode for every new session. Ask runs in Chat only; in the terminal it starts as Ask before edits."

    /// The picker's tag for "Last used in the project" (no mode is stored).
    private static let lastUsedTag = "last-used"
}

/// How Loom reaches the user outside its window (D-49, D-52): the menu bar item, approval and long-turn banners,
/// Open at login and Keep Mac awake. A row adds one line and a button only where macOS says something is wrong.
struct SystemSettingsCard: View {
    let model: CatalogModel
    let integration: SystemIntegration

    var body: some View {
        let notifyNotice = SettingsNotice.notifications(integration.notificationAuthorization)
        let loginNotice = SettingsNotice.loginItem(integration.loginItemStatus)
        SettingsGroup(label: "System") {
            SettingsRow(title: "Show in menu bar",
                        detail: "Show Sphyrna's mark in the menu bar, with the sessions that need you or are working.") {
                SettingsSwitch(title: "Show in menu bar", isOn: Binding(
                    get: { model.showInMenuBar }, set: { model.setShowInMenuBar($0) }))
            }
            SettingsRowDivider()
            SettingsRow(title: "Notify when a session needs approval",
                        detail: "A banner when Claude waits for your approval and Sphyrna is not the active app. macOS asks for permission once.",
                        notice: notifyNotice?.text) {
                if let notifyNotice {
                    Button(notifyNotice.buttonTitle) { integration.openNotificationSettings() }
                        .buttonStyle(ControlButtonStyle(kind: .secondary, size: .small))
                }
                SettingsSwitch(title: "Notify when a session needs approval", isOn: Binding(
                    get: { model.notifyApprovals }, set: { model.setNotifyApprovals($0) }))
            }
            SettingsRowDivider()
            SettingsRow(title: "Notify when a long turn finishes",
                        detail: "A silent banner when a turn of 30 seconds or more ends while you are elsewhere, with Open to go to the session.") {
                SettingsSwitch(title: "Notify when a long turn finishes", isOn: Binding(
                    get: { integration.notifyLongTurns }, set: { integration.setNotifyLongTurns($0) }))
            }
            SettingsRowDivider()
            SettingsRow(title: "Open at login", detail: "Start Sphyrna when you log in.", notice: loginNotice?.text) {
                if let loginNotice {
                    Button(loginNotice.buttonTitle) { integration.openLoginItems() }
                        .buttonStyle(ControlButtonStyle(kind: .secondary, size: .small))
                }
                SettingsSwitch(title: "Open at login", isOn: Binding(
                    get: { integration.loginItemStatus.switchIsOn }, set: { integration.setLoginItem($0) }))
            }
            SettingsRowDivider()
            SettingsRow(title: "Keep Mac awake",
                        detail: "Hold off sleep while a session works, so a long turn is not cut short. The display still sleeps. Activity Monitor lists Claude Code's own energy under \"Sphyrna Run Host\".") {
                InkSegmented(values: KeepAwakeSetting.allCases, title: \.title, selection: integration.keepAwake,
                             onSelect: { integration.setKeepAwake($0) })
                    .accessibilityLabel("Keep Mac awake")
            }
        }
        // The system's side can change while Settings is closed or Loom is in the background.
        .onAppear { integration.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            integration.refresh()
        }
    }
}

// MARK: About

struct AboutSettings: View {
    let about: SettingsAbout
    var diagnostics: DiagnosticsCollection?

    private typealias S = LoomTheme.Settings

    var body: some View {
        SettingsPage {
            VStack(spacing: 0) {
                head.padding(.top, S.aboutTop - S.bodyTop)
                SettingsCard {
                    SettingsRow(title: "Data folder", detail: "Catalog, usage index and logs.") {
                        PathText(url: about.dataFolder)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([about.dataFolder]) }
                            .buttonStyle(ControlButtonStyle(kind: .secondary, size: .small))
                            .accessibilityLabel("Reveal data folder in Finder")
                    }
                    if let profile = about.claudeProfile {
                        SettingsRowDivider()
                        SettingsRow(title: "Claude profile", detail: "Where usage is read from. Read only.") {
                            PathText(url: profile)
                        }
                    }
                    if let diagnostics {
                        SettingsRowDivider()
                        SettingsRow(title: "Diagnostics", detail: "A folder with versions, counts and Sphyrna's log. No session content.") {
                            Button(diagnostics.isRunning ? "Collecting…" : "Collect Diagnostics…") { diagnostics.collect() }
                                .buttonStyle(ControlButtonStyle(kind: .secondary, size: .small))
                                .disabled(!diagnostics.canCollect)
                                .accessibilityLabel("Collect diagnostics")
                        }
                    }
                }
                .padding(.top, S.aboutCardTop)
            }
        }
    }

    /// The app's icon (the image already carries macOS's shape, so it is not rounded again) with a ring, a top highlight and a drop;
    /// then the name and the version, over the crossing hammerhead.
    private var head: some View {
        let shape = RoundedRectangle(cornerRadius: S.iconRadius)
        return VStack(spacing: 0) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: S.iconSide, height: S.iconSide)
                .overlay { shape.strokeBorder(S.iconRing, lineWidth: LoomTheme.Line.hairline) }
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(colors: [S.iconHighlight, .clear], startPoint: .top, endPoint: .center),
                        lineWidth: LoomTheme.Line.hairline)
                }
                .shadow(color: S.iconDrop, radius: 1.5, x: 0, y: 1)
                .accessibilityHidden(true)
            Text("Sphyrna").projectType(LoomTheme.InkType.title).foregroundStyle(LoomTheme.Text.primary)
                .padding(.top, S.aboutNameTop)
            Text(about.version).projectType(LoomTheme.InkType.metaLarge).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .textSelection(.enabled).padding(.top, S.aboutVersionTop)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A path in the home-relative form people recognise, in the mono face, cut in the middle if long.
struct PathText: View {
    let url: URL

    var body: some View {
        Text(SettingsPaths.display(url))
            .projectType(LoomTheme.Settings.path).foregroundStyle(LoomTheme.Text.secondaryStyle)
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: LoomTheme.Settings.pathMaxWidth, alignment: .trailing)
            .textSelection(.enabled)
    }
}

enum SettingsPaths {
    static func display(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
}

// MARK: The Changes tab's controls

// `SegmentButtonStyle` and `SettingsButtonStyle` are the older controls; the Changes tab still draws with them (I6b moves it onto the
// control family). Settings itself uses `InkSegmented`, `ControlButtonStyle` and the rest of `SettingsControls.swift`.

struct SegmentButtonStyle: ButtonStyle {
    let selected: Bool
    var compact = false
    var key: String?

    func makeBody(configuration: Configuration) -> some View {
        Segment(configuration: configuration, selected: selected, compact: compact, key: key)
    }

    private struct Segment: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        let compact: Bool
        let key: String?
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let state = HighlightState.resolve(
                selected: selected, hovering: hovering || LookEvidence.forcesHover(key),
                pressed: configuration.isPressed, enabled: enabled)
            configuration.label
                .font(compact ? LoomTheme.Typography.statusLabel : LoomTheme.Typography.smallMedium)
                .foregroundStyle(state == .none ? LoomTheme.Text.secondary : LoomTheme.Text.primary)
                .padding(.horizontal, compact ? LoomTheme.Space.settingsSegmentH - 4 : LoomTheme.Space.settingsSegmentH)
                .frame(height: LoomTheme.Layout.settingsSegmentHeight)
                .background(RowHighlight(state: state, radius: LoomTheme.Highlight.radiusControl))
                .overlay(RoundedRectangle(cornerRadius: LoomTheme.Highlight.radiusControl)
                    .strokeBorder(ChromeButtonStyle.showsFocusRing(
                        focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled)
                        ? LoomTheme.Surface.focusRing : .clear, lineWidth: LoomTheme.Line.focusRing(for: contrast)))
                .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Highlight.radiusControl))
                .onHover { hovering = $0 }
        }
    }
}

/// A quiet text button for Settings rows: the control fill, a step up under the pointer, another while pressed.
struct SettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(LoomTheme.Typography.small)
                .foregroundStyle(LoomTheme.Text.primary)
                .padding(.horizontal, LoomTheme.Space.settingsSegmentH - 4)
                .frame(height: LoomTheme.Layout.settingsSegmentHeight)
                .background(RoundedRectangle(cornerRadius: LoomTheme.Highlight.radiusControl).fill(
                    configuration.isPressed ? LoomTheme.Surface.controlPressed
                        : (hovering && enabled ? LoomTheme.Surface.controlHover : LoomTheme.Surface.control)))
                .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Highlight.radiusControl))
                .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
                .onHover { hovering = $0 }
        }
    }
}
