import SwiftUI

extension LoomTheme {
    /// The reference's common 16-unit, round-stroked outline artwork.
    enum Icon {
        static let viewport: CGFloat = 16
        static let stroke: CGFloat = 1.4
        static let chrome: CGFloat = 16
        static let navigation: CGFloat = 15
        static let heading: CGFloat = 14
        static let body: CGFloat = 13
        static let compact: CGFloat = 12
        static let small: CGFloat = 11
        static let tiny: CGFloat = 10
        static func fallbackFont(size: CGFloat) -> Font { .system(size: size, weight: .regular) }
    }
}
