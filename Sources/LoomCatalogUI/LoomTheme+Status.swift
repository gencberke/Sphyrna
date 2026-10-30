import CoreGraphics

/// Ink's status marks (DESIGN §4): the braille spinner and the dots. All of the spinner's and the dots' sizes live here.
extension LoomTheme {
    /// The working mark: ten frames of one SF Mono braille cell, stepped from the app twice a second (D-125: at 12 frames a
    /// second the render server kept WindowServer at about 9 % of one core while a session worked).
    enum Spinner {
        static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        static let framesPerSecond = 2.0
        /// In the 12 pt status slot: 14 pt, in primary.
        static let statusPointSize: CGFloat = 14
        /// In a subagent row: 12.5 pt, in secondary.
        static let subagentPointSize: CGFloat = 12.5
        /// The side of the square a frame is drawn in, for both sizes (the status slot's width).
        static let side: CGFloat = 12
        /// The menu bar badge: the badge slot of `MenuBar` (the old chase's 12 pt square at 0.8), the cell at 14 pt.
        static let menuBarPointSize: CGFloat = 14
        static let menuBarSide: CGFloat = 9.6
    }

    /// The other marks of the status column.
    enum StatusMark {
        /// The attention, unviewed and failure dots (and the failure diamond, `Layout.failureDiamond`).
        static let dot: CGFloat = 7
        /// The hollow rings: State unknown (faint) and Identity unclear (attention).
        static let ring: CGFloat = 8
    }
}
