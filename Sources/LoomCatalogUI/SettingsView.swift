import AppKit
import SwiftUI

public enum SettingsSection: CaseIterable, Identifiable, Hashable, Sendable {
    case general, usage, about

    public var id: Self { self }
    public var title: String {
        switch self {
        case .general: "General"
        case .usage: "Usage"
        case .about: "About"
        }
    }
}

/// Which section the one Settings window shows. The window controller and the view share it, so
/// the gear (no section) and the footer chip (Usage) reuse the same window.
@MainActor @Observable
public final class SettingsNavigation {
    public var section: SettingsSection

    public init(section: SettingsSection = .general) { self.section = section }

    /// A requested section wins; no section keeps the one the window already shows.
    public func open(_ requested: SettingsSection?) {
        if let requested, requested != section { section = requested }
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

/// The Settings window's content: a top section switcher over General, Usage and About, one fixed
/// size for all three (DESIGN §6; the window controller forces dark and sets the size).
public struct SettingsView: View {
    let model: CatalogModel
    let usage: UsageModel?
    let navigation: SettingsNavigation
    let about: SettingsAbout

    public init(model: CatalogModel, usage: UsageModel?, navigation: SettingsNavigation, about: SettingsAbout) {
        self.model = model
        self.usage = usage
        self.navigation = navigation
        self.about = about
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                SegmentedControl(
                    values: SettingsSection.allCases, title: \.title, selection: navigation.section,
                    onSelect: { navigation.section = $0 })
                    .accessibilityLabel("Settings section")
            }
            .frame(maxWidth: .infinity)
            .frame(height: LoomTheme.Layout.settingsTopHeight)
            switch navigation.section {
            case .general: GeneralSettings(model: model)
            case .usage: UsageSettings(usage: usage, profile: about.claudeProfile)
            case .about: AboutSettings(about: about)
            }
        }
        .frame(width: LoomTheme.Layout.settingsWidth, height: LoomTheme.Layout.settingsHeight)
        .background(LoomTheme.Surface.panel)
        .foregroundStyle(LoomTheme.Text.primary)
        .font(LoomTheme.Typography.body)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .tint(LoomTheme.Accent.base)
    }
}

// MARK: General

struct GeneralSettings: View {
    let model: CatalogModel

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.settingsSectionGap) {
            SettingsCard {
                SettingsRow(title: "Terminal font size", detail: "Applies to existing and new terminals.") {
                    Picker("Terminal font size", selection: Binding(
                        get: { model.terminalFontSize }, set: { model.setTerminalFontSize($0) }
                    )) {
                        ForEach(11...20, id: \.self) { size in Text("\(size) pt").tag(Double(size)) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .accessibilityLabel("Terminal font size")
                }
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(LoomTheme.Status.failure).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LoomTheme.Space.settingsInset)
        .padding(.top, LoomTheme.Space.settingsSegmentH)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: About

struct AboutSettings: View {
    let about: SettingsAbout

    var body: some View {
        VStack(spacing: LoomTheme.Space.settingsSectionGap) {
            VStack(spacing: LoomTheme.Space.aboutHeadSpacing) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: LoomTheme.Layout.aboutMark, height: LoomTheme.Layout.aboutMark)
                    .accessibilityHidden(true)
                Text("Loom").font(LoomTheme.Typography.heading).padding(.top, LoomTheme.Space.aboutHeadSpacing)
                Text(about.version).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, LoomTheme.Space.aboutHeadTop)
            .padding(.bottom, LoomTheme.Space.aboutHeadBottom - LoomTheme.Space.settingsSectionGap)
            SettingsCard {
                SettingsRow(title: "Data folder", detail: "Catalog, usage index and logs.") {
                    HStack(spacing: LoomTheme.Space.settingsRowInset) {
                        PathText(url: about.dataFolder)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([about.dataFolder]) }
                            .buttonStyle(SettingsButtonStyle())
                            .accessibilityLabel("Reveal data folder in Finder")
                    }
                }
                if let profile = about.claudeProfile {
                    SettingsRowDivider()
                    SettingsRow(title: "Claude profile", detail: "Where usage is read from. Read only.") {
                        PathText(url: profile)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LoomTheme.Space.settingsInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A path in the home-relative form people recognise, in the mono face, cut in the middle if long.
struct PathText: View {
    let url: URL

    var body: some View {
        Text(SettingsPaths.display(url))
            .font(LoomTheme.Typography.mono).foregroundStyle(LoomTheme.Text.secondary)
            .lineLimit(1).truncationMode(.middle)
            .textSelection(.enabled)
    }
}

enum SettingsPaths {
    static func display(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
}

// MARK: Building blocks

/// A rounded group of rows on the 6 % control tone.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, LoomTheme.Space.settingsRowInset)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.card).fill(LoomTheme.Surface.control))
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: LoomTheme.Space.settingsRowInset) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(LoomTheme.Typography.smallMedium)
                Text(detail).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
            }
            Spacer(minLength: LoomTheme.Space.settingsRowInset)
            trailing
        }
        .padding(.vertical, LoomTheme.Space.settingsRowV)
        .frame(minHeight: LoomTheme.Layout.settingsRowMinHeight)
    }
}

struct SettingsRowDivider: View {
    var body: some View { Rectangle().fill(LoomTheme.Surface.hairline).frame(height: LoomTheme.Line.hairline) }
}

/// The section switcher and the period control: a 6 % track, the selected segment in the
/// selected-card look (7 % fill, 10 % stroke).
struct SegmentedControl<Value: Hashable>: View {
    let values: [Value]
    let title: (Value) -> String
    let selection: Value
    let onSelect: (Value) -> Void
    var compact = false
    var enabled = true

    init(values: [Value], title: @escaping (Value) -> String, selection: Value,
         compact: Bool = false, enabled: Bool = true, onSelect: @escaping (Value) -> Void) {
        self.values = values
        self.title = title
        self.selection = selection
        self.compact = compact
        self.enabled = enabled
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: LoomTheme.Space.settingsTrack) {
            ForEach(values, id: \.self) { value in
                Button(title(value)) { onSelect(value) }
                    .buttonStyle(SegmentButtonStyle(selected: value == selection, compact: compact))
                    .accessibilityAddTraits(value == selection ? .isSelected : [])
            }
        }
        .padding(LoomTheme.Space.settingsTrack)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.search).fill(LoomTheme.Surface.control))
        .disabled(!enabled)
        .accessibilityElement(children: .contain)
    }
}

struct SegmentButtonStyle: ButtonStyle {
    let selected: Bool
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Segment(configuration: configuration, selected: selected, compact: compact)
    }

    private struct Segment: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        let compact: Bool
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(compact ? LoomTheme.Typography.statusLabel : LoomTheme.Typography.smallMedium)
                .foregroundStyle(selected || configuration.isPressed ? LoomTheme.Text.primary : LoomTheme.Text.secondary)
                .padding(.horizontal, compact ? LoomTheme.Space.settingsSegmentH - 2 : LoomTheme.Space.settingsSegmentH)
                .frame(height: LoomTheme.Layout.settingsSegmentHeight)
                .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.control)
                    .fill(selected ? LoomTheme.Surface.selected : .clear))
                .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.control)
                    .strokeBorder(ChromeButtonStyle.showsFocusRing(
                        focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled)
                        ? LoomTheme.Surface.focusRing : (selected ? LoomTheme.Surface.hairline : .clear),
                        lineWidth: LoomTheme.Line.focusRing))
                .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.control))
        }
    }
}

/// A quiet text button for Settings rows (hover tone, no accent).
struct SettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LoomTheme.Typography.small)
            .foregroundStyle(LoomTheme.Text.primary)
            .padding(.horizontal, LoomTheme.Space.settingsSegmentH - 2)
            .frame(height: LoomTheme.Layout.settingsSegmentHeight)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.control)
                .fill(configuration.isPressed ? LoomTheme.Surface.controlPressed : LoomTheme.Surface.controlHover))
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.control))
    }
}
