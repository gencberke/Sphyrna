import AppKit
import LoomCore
import SwiftUI

/// The harness marks (DESIGN §6 Iconography): the Claude spark keeps its own clay; Codex is the ChatGPT knot as a template
/// image drawn in primary text, so it is white in Ink and dark in Paper (`assets/harness/harness-codex-template.png`). A bundle
/// that carries only `harness-codex.png` (the packaging scripts copy it today) draws that file as it is.
@MainActor
enum ProviderImages {
    private static var cache: [String: NSImage] = [:]

    /// The file a harness draws from, and whether it is a template tinted with the text colour. `exists` asks the bundle.
    static func asset(for provider: ManagedSession.Provider, exists: (String) -> Bool) -> (name: String, template: Bool)? {
        switch provider {
        case .claude: return ("harness-claude", false)
        case .codex: return exists("harness-codex-template") ? ("harness-codex-template", true) : ("harness-codex", false)
        case .synthetic: return nil
        }
    }

    static func image(for provider: ManagedSession.Provider) -> (image: NSImage, template: Bool)? {
        guard let asset = asset(for: provider, exists: { Bundle.main.url(forResource: $0, withExtension: "png") != nil })
        else { return nil }
        if let cached = cache[asset.name] { return (cached, asset.template) }
        guard let url = Bundle.main.url(forResource: asset.name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = asset.template
        cache[asset.name] = image
        return (image, asset.template)
    }

    /// Catalogue-only marks: the existing provider paths above stay unchanged.
    static func image(forHarness id: HarnessID) -> (image: NSImage, template: Bool)? {
        if let provider = id.provider { return image(for: provider) }
        guard id == .opencode || id == .agy, let descriptor = HarnessCatalogue.descriptor(for: id) else { return nil }
        let name = descriptor.mark
        let template = id == .agy
        if let cached = cache[name] { return (cached, template) }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = template
        cache[name] = image
        return (image, template)
    }

}

extension ProviderImages {
    private static var menuCache: [ManagedSession.Provider: NSImage] = [:]

    /// The mark of a menu item (DESIGN §6 Iconography: 14 in menus). A template stays one, so the menu tints it.
    static func menuImage(for provider: ManagedSession.Provider) -> NSImage? {
        if let cached = menuCache[provider] { return cached }
        guard let found = image(for: provider), let sized = found.image.copy() as? NSImage else { return nil }
        let side = LoomTheme.Layout.harnessMarkMenu
        sized.size = NSSize(width: side, height: side)
        sized.isTemplate = found.template
        menuCache[provider] = sized
        return sized
    }
}

extension MenuBarArt {
    /// Claude's mark at 14 for the menu bar's New Claude Session row (DESIGN §19: the menu carries the harness's mark). Nil where
    /// the build carries no image.
    @MainActor
    public static func newSessionImage() -> NSImage? { ProviderImages.menuImage(for: .claude) }
}

/// A menu item's title with its harness's mark (14) before it; the title alone where the build carries no image.
struct HarnessMenuLabel: View {
    let provider: ManagedSession.Provider
    let title: String

    var body: some View {
        if let image = ProviderImages.menuImage(for: provider) {
            Label { Text(title) } icon: { Image(nsImage: image) }
        } else {
            Text(title)
        }
    }
}

/// opencode's public mark has a light body and a darker inset; a plain alpha template would merge them.
/// A luminance mask preserves those tones while the foreground supplies the appearance's text color.
struct OpencodeHarnessMark: View {
    let image: NSImage
    var tint: Color = LoomTheme.Text.primary

    var body: some View {
        tint.mask {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).luminanceToAlpha()
        }
    }
}

struct ProviderIcon: View {
    let provider: ManagedSession.Provider?
    let harness: HarnessID?
    var size: CGFloat

    init(provider: ManagedSession.Provider, size: CGFloat = LoomTheme.Layout.harnessMarkRow) {
        self.provider = provider
        self.harness = nil
        self.size = size
    }

    init(harness: HarnessID, size: CGFloat = LoomTheme.Layout.harnessMarkRow) {
        self.provider = harness.provider
        self.harness = harness
        self.size = size
    }

    var body: some View {
        Group {
            if harness == .pi {
                ZStack {
                    RoundedRectangle(cornerRadius: LoomTheme.Connect.piRadius)
                        .strokeBorder(LoomTheme.Surface.strongerHairline, lineWidth: LoomTheme.Line.hairline)
                    Text("π").projectType(LoomTheme.Connect.piGlyph).foregroundStyle(LoomTheme.Text.secondaryStyle)
                }
            } else if let found = harness.flatMap({ ProviderImages.image(forHarness: $0) })
                ?? provider.flatMap({ ProviderImages.image(for: $0) }) {
                if harness == .opencode {
                    OpencodeHarnessMark(image: found.image)
                } else if found.template {
                    Image(nsImage: found.image).renderingMode(.template).resizable().interpolation(.high)
                        .aspectRatio(contentMode: .fit).foregroundStyle(LoomTheme.Text.primary)
                } else {
                    Image(nsImage: found.image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                }
            } else {
                Image(systemName: provider == .synthetic ? "terminal" : "sparkles")
                    .resizable().aspectRatio(contentMode: .fit).foregroundStyle(LoomTheme.Text.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
