import SwiftUI

extension LoomTheme {
    /// Task-only managed child surface; shared Ink colors and controls carry the tone.
    enum ManagedAgents {
        static let pageInset: CGFloat = 24
        static let columnWidth: CGFloat = 720
        static let sectionGap: CGFloat = 20
        static let lineGap: CGFloat = 6
        static let rowGap: CGFloat = 8
        static let cardGap: CGFloat = 12
        static let cardInset: CGFloat = 16
        static let cardRadius = InkRadius.card
        static let optionRadius = InkRadius.row
        static let optionInset: CGFloat = 8
        static let mark: CGFloat = 16
        static let choiceMark: CGFloat = 14
        static let choiceRadius = InkRadius.key
        static let fieldHeight = InkHeight.standard
        static let fieldInset: CGFloat = 10
        static let fieldRadius = InkRadius.row
        static let fieldFontSize = InkType.body.size
        static let title = InkType.title.font
        static let heading = InkType.header.font
        static let body = InkType.body.font
        static let detail = InkType.small.font
        static let metadata = InkType.meta.font
        static var cardFill: Color { Surface.raised1 }
        static var cardEdge: Color { Surface.strongHairline }
        static var fieldFill: Color { Surface.inputFill }
        static var fieldEdge: Color { Surface.inputEdge }
        static var selectedFill: Color { Accent.base }
        static var selectedMark: Color { Accent.onAccent }
    }
}
