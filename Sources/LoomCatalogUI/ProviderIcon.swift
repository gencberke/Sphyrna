import AppKit
import LoomCore
import SwiftUI

@MainActor
enum ProviderImages {
    private static var cache: [String: NSImage] = [:]

    static func image(for provider: ManagedSession.Provider) -> NSImage? {
        let name: String
        switch provider {
        case .claude: name = "harness-claude"
        case .codex: name = "harness-codex"
        case .synthetic: return nil
        }
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }
}

struct ProviderIcon: View {
    let provider: ManagedSession.Provider
    var size: CGFloat = 15

    var body: some View {
        Group {
            if let image = ProviderImages.image(for: provider) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: provider == .synthetic ? "terminal" : "sparkles")
                    .resizable().aspectRatio(contentMode: .fit).foregroundStyle(LoomTheme.Text.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
