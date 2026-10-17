import SwiftUI

/// The Home screen. A placeholder until the Home slice (V05) fills it; `DetailContent` draws it for `.home`.
struct HomeView: View {
    let model: CatalogModel

    var body: some View {
        Message(symbol: "house", title: "Home", text: "Your sessions and plan limits will appear here.")
            .accessibilityIdentifier("home")
    }
}
