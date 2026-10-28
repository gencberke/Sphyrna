import SwiftUI

extension LoomTheme {
    enum ModelPicker {
        static let width: CGFloat = 412
        static let height: CGFloat = 344
        static let searchHeight: CGFloat = 44
        static let searchInset: CGFloat = 14
        static let searchGap: CGFloat = 9
        static let railWidth: CGFloat = 44
        static let listWidth: CGFloat = width - railWidth - Line.hairline
        static let bodyHeight: CGFloat = height - searchHeight - Line.hairline
        static let railButton = CGSize(width: 32, height: 32)
        static let railGap: CGFloat = 2
        static let railInset: CGFloat = 6
        static let railDividerWidth: CGFloat = 20
        static let mark: CGFloat = 15
        static let rowMark: CGFloat = 13
        static let groupMark: CGFloat = 12
        static let groupHeight: CGFloat = 30
        static let rowHeight: CGFloat = 32
        static let rowInset: CGFloat = 8
        static let rowGap: CGFloat = 8
        static let listInset: CGFloat = 6
        static let listVertical: CGFloat = 4
        static let checkWidth: CGFloat = 14
        static let dot: CGFloat = 5
        static let rowRadius = InkRadius.row
        static let chipGap: CGFloat = 6
        static let chipMark: CGFloat = 14
        static let chipFont = Font.system(size: 12)
        static let rowFont = Font.system(size: 13)
        static let descriptionFont = Font.system(size: 12)
        static let groupFont = Font.system(size: 11, weight: .semibold)
        static let countFont = Font.system(size: 10.5, design: .monospaced)
        static let iconFont = Font.system(size: 13)
        static let searchFont = Font.system(size: 13)
        static let emptyFont = Font.system(size: 11.5)
        static let emptyInset: CGFloat = 10
        static let effortWidth: CGFloat = 300
        static let effortInset: CGFloat = 4
        static let effortHeaderHeight: CGFloat = 30
        static let effortListMaxHeight: CGFloat = 240
        static let effortNameWidth: CGFloat = 72
        static let effortTagHeight: CGFloat = 18
        static let effortTagInset: CGFloat = 6
        static var railFill: Color { Surface.muted.opacity(0.4) }
    }
}
