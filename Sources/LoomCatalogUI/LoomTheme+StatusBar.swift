import SwiftUI

extension LoomTheme {
    /// The window-wide status strip and its utilities.
    enum StatusBar {
        static let height: CGFloat = 26
        static let inset: CGFloat = 8
        static let gap: CGFloat = 4
        static let segmentGap: CGFloat = 7
        static let mark: CGFloat = 12
        static let meter = CGSize(width: 40, height: 4)
        static let meterRadius: CGFloat = 2
        static let caption = Font.system(size: 11)
        static let figures = Font.system(size: 10.5, design: .monospaced)
        static let reset = Font.system(size: 10, design: .monospaced)
        static let popoverWidth: CGFloat = 360
        static let popoverInset: CGFloat = 14
        static let popoverVertical: CGFloat = 11
        static let popoverGap: CGFloat = 8
        static let popoverPacesMaxHeight: CGFloat = 260
        static let popoverPacesBeforeScrolling = 4
        static let popoverTitle = Font.system(size: 12.5, weight: .semibold)
        static let utilityGap: CGFloat = 2
        static let utilitySize = CGSize(width: InkHeight.xs, height: InkHeight.xs)
        static let switchSize = CGSize(width: 22, height: 12)
        static let switchThumb: CGFloat = 8
        static let switchInset: CGFloat = 2
        static var fill: Color { Surface.sidebar }
    }
}
