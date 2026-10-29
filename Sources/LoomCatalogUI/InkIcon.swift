import SwiftUI

/// Shared reference artwork, drawn natively in a fixed 16-unit coordinate
/// space. Unknown semantic symbols keep their normal SF Symbols fallback.
struct InkIcon: View {
    enum Kind: Hashable {
        case search, home, plus, list, sidebarLeft, sidebarRight, gear, question
        case more, branch, close, check, chevronDown, chevronRight, chevronLeft
        case up, down, copy, open, folder, shield, clock, pencil, trash, document
        case terminal, agent, effort, bubble, pause, play, eye, info, warning, exclamation
        case refresh, compose, book, file, sparkle, slash, bell, ask, upDown, minus, questionDiamond, penline, bolt
    }

    private let kind: Kind?
    private let fallback: String?
    let size: CGFloat

    init(_ kind: Kind, size: CGFloat = LoomTheme.Icon.chrome) {
        self.kind = kind
        fallback = nil
        self.size = size
    }

    init(systemName: String, size: CGFloat = LoomTheme.Icon.body) {
        kind = Self.kind(for: systemName)
        fallback = systemName
        self.size = size
    }

    private static func kind(for name: String) -> Kind? {
        switch name {
        case "magnifyingglass": .search
        case "house": .home
        case "plus": .plus
        case "minus": .minus
        case "list.bullet", "list.bullet.rectangle": .list
        case "sidebar.left": .sidebarLeft
        case "sidebar.right": .sidebarRight
        case "gearshape": .gear
        case "questionmark.circle": .question
        case "questionmark.diamond": .questionDiamond
        case "ellipsis": .more
        case "arrow.triangle.branch": .branch
        case "xmark": .close
        case "checkmark": .check
        case "chevron.down": .chevronDown
        case "chevron.right": .chevronRight
        case "chevron.left": .chevronLeft
        case "arrow.up": .up
        case "arrow.down": .down
        case "doc.on.doc": .copy
        case "arrow.up.forward.square", "arrow.up.right", "arrow.up.right.square": .open
        case "folder": .folder
        case "shield": .shield
        case "clock": .clock
        case "pencil": .pencil
        case "pencil.line": .penline
        case "bolt": .bolt
        case "trash": .trash
        case "doc.text": .document
        case "doc": .file
        case "terminal": .terminal
        case "person": .agent
        case "slider.horizontal.3": .effort
        case "bubble.left", "text.bubble": .bubble
        case "pause": .pause
        case "play": .play
        case "eye": .eye
        case "info.circle": .info
        case "exclamationmark.triangle": .warning
        case "exclamationmark.circle": .exclamation
        case "arrow.clockwise": .refresh
        case "square.and.pencil": .compose
        case "book": .book
        case "sparkles": .sparkle
        case "slash.circle": .slash
        case "bell": .bell
        case "questionmark.bubble": .ask
        case "chevron.up.chevron.down": .upDown
        default: nil
        }
    }

    @ViewBuilder var body: some View {
        if let kind {
            ZStack {
                InkIconShape(kind: kind, filled: false)
                    .stroke(style: StrokeStyle(lineWidth: size * LoomTheme.Icon.stroke / LoomTheme.Icon.viewport,
                                               lineCap: .round, lineJoin: .round))
                InkIconShape(kind: kind, filled: true).fill()
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        } else if let fallback {
            Image(systemName: fallback).font(LoomTheme.Icon.fallbackFont(size: size))
                .frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}

/// Normalized reference geometry, with filled dots drawn separately from
/// the round-stroked outlines. Coordinates describe artwork, not UI layout.
private struct InkIconShape: Shape {
    let kind: InkIcon.Kind
    let filled: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func line(_ points: [(CGFloat, CGFloat)], close: Bool = false) {
            guard let first = points.first else { return }
            path.move(to: CGPoint(x: first.0, y: first.1))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
            if close { path.closeSubpath() }
        }
        func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
            path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        func rounded(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) {
            path.addRoundedRect(in: CGRect(x: x, y: y, width: width, height: height),
                                cornerSize: CGSize(width: radius, height: radius))
        }
        if filled {
            switch kind {
            case .list: circle(4.9, 6.3, 0.75); circle(4.9, 9.7, 0.75)
            case .more: circle(3.6, 8, 0.95); circle(8, 8, 0.95); circle(12.4, 8, 0.95)
            case .question: circle(8, 11.1, 0.8)
            case .warning: circle(8, 11, 0.75)
            case .exclamation: circle(8, 10.8, 0.8)
            case .questionDiamond: circle(8, 10.9, 0.7)
            default: break
            }
        } else {
            switch kind {
            case .search:
                circle(7, 7, 4.6); line([(10.5, 10.5), (14, 14)])
            case .home:
                line([(2.6, 7.2), (8, 2.9), (13.4, 7.2), (13.4, 13)])
                path.addCurve(to: CGPoint(x: 12.5, y: 13.9), control1: CGPoint(x: 13.4, y: 13.497), control2: CGPoint(x: 12.997, y: 13.9))
                line([(12.5, 13.9), (9.7, 13.9), (9.7, 10.2), (6.3, 10.2), (6.3, 13.9), (3.5, 13.9)])
                path.addCurve(to: CGPoint(x: 2.6, y: 13), control1: CGPoint(x: 3.003, y: 13.9), control2: CGPoint(x: 2.6, y: 13.497))
                line([(2.6, 13), (2.6, 7.2)])
            case .plus:
                line([(8, 3.2), (8, 12.8)]); line([(3.2, 8), (12.8, 8)])
            case .minus: line([(4, 8), (12, 8)])
            case .list:
                rounded(2.2, 3, 11.6, 10, 2); line([(7, 6.3), (11.4, 6.3)]); line([(7, 9.7), (11.4, 9.7)])
            case .sidebarLeft, .sidebarRight:
                rounded(2, 3, 12, 10, 2.2)
                let x: CGFloat = kind == .sidebarLeft ? 6.2 : 9.8
                line([(x, 3), (x, 13)])
            case .gear:
                circle(8, 8, 2); circle(8, 8, 4.4)
                line([(8, 1.9), (8, 3.6)]); line([(8, 12.4), (8, 14.1)])
                line([(14.1, 8), (12.4, 8)]); line([(3.6, 8), (1.9, 8)])
                line([(12.3, 3.7), (11.1, 4.9)]); line([(4.9, 11.1), (3.7, 12.3)])
                line([(12.3, 12.3), (11.1, 11.1)]); line([(4.9, 4.9), (3.7, 3.7)])
            case .question:
                circle(8, 8, 5.6)
                path.move(to: CGPoint(x: 6.3, y: 6.4))
                path.addCurve(to: CGPoint(x: 9.8, y: 6.9), control1: CGPoint(x: 6.6, y: 4.3), control2: CGPoint(x: 9.8, y: 4.7))
                path.addCurve(to: CGPoint(x: 8, y: 9.5), control1: CGPoint(x: 9.8, y: 8.1), control2: CGPoint(x: 8, y: 8.4))
            case .questionDiamond:
                line([(8, 1.9), (14.1, 8), (8, 14.1), (1.9, 8), (8, 1.9)])
                path.move(to: CGPoint(x: 6.7, y: 6.7))
                path.addCurve(to: CGPoint(x: 8.6, y: 7.95), control1: CGPoint(x: 6.7, y: 4.8), control2: CGPoint(x: 10.5, y: 4.8))
                path.addCurve(to: CGPoint(x: 8, y: 9.1), control1: CGPoint(x: 8.22, y: 8.13), control2: CGPoint(x: 8, y: 8.43))
            case .more: break
            case .branch:
                circle(5, 3.9, 1.4); circle(5, 12.1, 1.4); circle(11, 6, 1.4)
                line([(5, 5.3), (5, 10.7)])
                path.move(to: CGPoint(x: 11, y: 7.4))
                path.addCurve(to: CGPoint(x: 6.3, y: 11.1), control1: CGPoint(x: 11, y: 9.7), control2: CGPoint(x: 8.9, y: 10.1))
            case .close:
                line([(4.6, 4.6), (11.4, 11.4)]); line([(11.4, 4.6), (4.6, 11.4)])
            case .check: line([(3.6, 8.4), (6.5, 11.3), (12.4, 4.7)])
            case .chevronDown: line([(4.6, 6.4), (8, 9.8), (11.4, 6.4)])
            case .chevronRight: line([(6.4, 4.6), (9.8, 8), (6.4, 11.4)])
            case .chevronLeft: line([(10, 3.5), (5.5, 8), (10, 12.5)])
            case .up: line([(8, 12.6), (8, 3.5)]); line([(4.3, 7.2), (8, 3.5), (11.7, 7.2)])
            case .down: line([(8, 3.4), (8, 12.5)]); line([(4.3, 8.8), (8, 12.5), (11.7, 8.8)])
            case .copy:
                rounded(5.6, 5.6, 7.8, 7.8, 1.6)
                path.move(to: CGPoint(x: 10.4, y: 5.6)); path.addLine(to: CGPoint(x: 10.4, y: 4))
                path.addCurve(to: CGPoint(x: 9, y: 2.6), control1: CGPoint(x: 10.4, y: 3.2), control2: CGPoint(x: 9.8, y: 2.6))
                path.addLine(to: CGPoint(x: 4, y: 2.6))
                path.addCurve(to: CGPoint(x: 2.6, y: 4), control1: CGPoint(x: 3.2, y: 2.6), control2: CGPoint(x: 2.6, y: 3.2))
                path.addLine(to: CGPoint(x: 2.6, y: 9))
                path.addCurve(to: CGPoint(x: 4, y: 10.4), control1: CGPoint(x: 2.6, y: 9.8), control2: CGPoint(x: 3.2, y: 10.4))
                path.addLine(to: CGPoint(x: 5.6, y: 10.4))
            case .open:
                line([(9.2, 2.8), (13.2, 2.8), (13.2, 6.8)]); line([(13.2, 2.8), (7.8, 8.2)])
                path.move(to: CGPoint(x: 11.6, y: 9.6)); path.addLine(to: CGPoint(x: 11.6, y: 12.3))
                path.addCurve(to: CGPoint(x: 10.7, y: 13.2), control1: CGPoint(x: 11.6, y: 12.8), control2: CGPoint(x: 11.2, y: 13.2))
                path.addLine(to: CGPoint(x: 3.7, y: 13.2))
                path.addCurve(to: CGPoint(x: 2.8, y: 12.3), control1: CGPoint(x: 3.2, y: 13.2), control2: CGPoint(x: 2.8, y: 12.8))
                path.addLine(to: CGPoint(x: 2.8, y: 5.3))
                path.addCurve(to: CGPoint(x: 3.7, y: 4.4), control1: CGPoint(x: 2.8, y: 4.8), control2: CGPoint(x: 3.2, y: 4.4))
                path.addLine(to: CGPoint(x: 6.4, y: 4.4))
            case .folder:
                path.move(to: CGPoint(x: 2.3, y: 4.7))
                path.addCurve(to: CGPoint(x: 3.6, y: 3.4), control1: CGPoint(x: 2.3, y: 4), control2: CGPoint(x: 2.9, y: 3.4))
                line([(3.6, 3.4), (6.1, 3.4), (7.5, 4.9), (12.4, 4.9)])
                path.addCurve(to: CGPoint(x: 13.7, y: 6.2), control1: CGPoint(x: 13.1, y: 4.9), control2: CGPoint(x: 13.7, y: 5.5))
                path.addLine(to: CGPoint(x: 13.7, y: 11.8))
                path.addCurve(to: CGPoint(x: 12.4, y: 13.1), control1: CGPoint(x: 13.7, y: 12.5), control2: CGPoint(x: 13.1, y: 13.1))
                path.addLine(to: CGPoint(x: 3.6, y: 13.1))
                path.addCurve(to: CGPoint(x: 2.3, y: 11.8), control1: CGPoint(x: 2.9, y: 13.1), control2: CGPoint(x: 2.3, y: 12.5))
                path.addLine(to: CGPoint(x: 2.3, y: 4.7))
            case .shield:
                line([(8, 2.2), (13, 4), (13, 7.6)])
                path.addCurve(to: CGPoint(x: 8, y: 13.8), control1: CGPoint(x: 13, y: 10.6), control2: CGPoint(x: 10.9, y: 12.7))
                path.addCurve(to: CGPoint(x: 3, y: 7.6), control1: CGPoint(x: 5.1, y: 12.7), control2: CGPoint(x: 3, y: 10.6))
                line([(3, 7.6), (3, 4), (8, 2.2)])
            case .clock:
                circle(8, 8, 5.6); line([(8, 5), (8, 8.2), (10.1, 9.5)])
            case .pencil:
                path.move(to: CGPoint(x: 10.6, y: 2.9))
                path.addCurve(to: CGPoint(x: 12.7, y: 5), control1: CGPoint(x: 12, y: 1.5), control2: CGPoint(x: 14.1, y: 3.6))
                line([(12.7, 5), (5.3, 12.4), (2.5, 13.1), (3.2, 10.3), (10.6, 2.9)])
            case .penline:
                path.move(to: CGPoint(x: 10.3, y: 2.9))
                path.addCurve(to: CGPoint(x: 12.3, y: 4.9), control1: CGPoint(x: 11.6, y: 1.6), control2: CGPoint(x: 13.6, y: 3.6))
                line([(12.3, 4.9), (6.6, 10.6), (3.9, 11.3), (4.6, 8.6), (10.3, 2.9)])
                line([(8.4, 13.3), (13.2, 13.3)])
            case .bolt:
                line([(9, 1.9), (4.3, 9), (7.7, 9), (7.1, 14.1), (11.7, 7), (8.3, 7), (9, 1.9)])
            case .trash:
                line([(3, 4.6), (13, 4.6)]); line([(6.4, 4.6), (6.4, 3.2), (9.6, 3.2), (9.6, 4.6)])
                line([(4.3, 4.6), (4.9, 12.8)])
                path.addCurve(to: CGPoint(x: 6, y: 13.8), control1: CGPoint(x: 4.9, y: 13.4), control2: CGPoint(x: 5.4, y: 13.8))
                path.addLine(to: CGPoint(x: 10, y: 13.8))
                path.addCurve(to: CGPoint(x: 11.1, y: 12.8), control1: CGPoint(x: 10.6, y: 13.8), control2: CGPoint(x: 11.1, y: 13.4))
                path.addLine(to: CGPoint(x: 11.7, y: 4.6))
            case .document, .file:
                line([(4.3, 2.4), (9.1, 2.4), (11.7, 5), (11.7, 12.6)])
                path.addCurve(to: CGPoint(x: 10.7, y: 13.6), control1: CGPoint(x: 11.7, y: 13.2), control2: CGPoint(x: 11.3, y: 13.6))
                path.addLine(to: CGPoint(x: 4.3, y: 13.6))
                path.addCurve(to: CGPoint(x: 3.3, y: 12.6), control1: CGPoint(x: 3.7, y: 13.6), control2: CGPoint(x: 3.3, y: 13.2))
                path.addLine(to: CGPoint(x: 3.3, y: 3.4))
                path.addCurve(to: CGPoint(x: 4.3, y: 2.4), control1: CGPoint(x: 3.3, y: 2.8), control2: CGPoint(x: 3.7, y: 2.4))
                line([(9, 2.5), (9, 5.2), (11.7, 5.2)])
                if kind == .document { line([(5.7, 8.2), (10.3, 8.2)]); line([(5.7, 10.6), (8.9, 10.6)]) }
            case .terminal:
                rounded(2, 3, 12, 10, 2); line([(4.9, 6.3), (6.9, 8), (4.9, 9.7)]); line([(8.6, 10), (11.2, 10)])
            case .agent:
                circle(8, 5.5, 2.4)
                path.move(to: CGPoint(x: 3.4, y: 13.2))
                path.addCurve(to: CGPoint(x: 8, y: 9.5), control1: CGPoint(x: 3.9, y: 10.9), control2: CGPoint(x: 5.7, y: 9.5))
                path.addCurve(to: CGPoint(x: 12.6, y: 13.2), control1: CGPoint(x: 10.3, y: 9.5), control2: CGPoint(x: 12.1, y: 10.9))
            case .effort:
                line([(8, 3.6), (8, 12.6)])
                path.move(to: CGPoint(x: 8, y: 3.6))
                path.addCurve(to: CGPoint(x: 5.7, y: 2.6), control1: CGPoint(x: 7.6, y: 2.7), control2: CGPoint(x: 6.6, y: 2.3))
                path.addCurve(to: CGPoint(x: 4.3, y: 4.2), control1: CGPoint(x: 4.9, y: 2.8), control2: CGPoint(x: 4.4, y: 3.5))
                path.addCurve(to: CGPoint(x: 2.7, y: 6.2), control1: CGPoint(x: 3.4, y: 4.4), control2: CGPoint(x: 2.7, y: 5.2))
                path.addCurve(to: CGPoint(x: 3, y: 7.3), control1: CGPoint(x: 2.7, y: 6.6), control2: CGPoint(x: 2.8, y: 7))
                path.addCurve(to: CGPoint(x: 2.1, y: 9), control1: CGPoint(x: 2.4, y: 7.7), control2: CGPoint(x: 2.1, y: 8.3))
                path.addCurve(to: CGPoint(x: 3.5, y: 11), control1: CGPoint(x: 2.1, y: 9.9), control2: CGPoint(x: 2.7, y: 10.7))
                path.addCurve(to: CGPoint(x: 5.3, y: 12.9), control1: CGPoint(x: 3.5, y: 12), control2: CGPoint(x: 4.3, y: 12.8))
                path.addCurve(to: CGPoint(x: 7.4, y: 11.8), control1: CGPoint(x: 6.2, y: 13), control2: CGPoint(x: 7, y: 12.6))
                path.move(to: CGPoint(x: 8, y: 3.6))
                path.addCurve(to: CGPoint(x: 10.3, y: 2.6), control1: CGPoint(x: 8.4, y: 2.7), control2: CGPoint(x: 9.4, y: 2.3))
                path.addCurve(to: CGPoint(x: 11.7, y: 4.2), control1: CGPoint(x: 11.1, y: 2.8), control2: CGPoint(x: 11.6, y: 3.5))
                path.addCurve(to: CGPoint(x: 13.3, y: 6.2), control1: CGPoint(x: 12.6, y: 4.4), control2: CGPoint(x: 13.3, y: 5.2))
                path.addCurve(to: CGPoint(x: 13, y: 7.3), control1: CGPoint(x: 13.3, y: 6.6), control2: CGPoint(x: 13.2, y: 7))
                path.addCurve(to: CGPoint(x: 13.9, y: 9), control1: CGPoint(x: 13.6, y: 7.7), control2: CGPoint(x: 13.9, y: 8.3))
                path.addCurve(to: CGPoint(x: 12.5, y: 11), control1: CGPoint(x: 13.9, y: 9.9), control2: CGPoint(x: 13.3, y: 10.7))
                path.addCurve(to: CGPoint(x: 10.7, y: 12.9), control1: CGPoint(x: 12.5, y: 12), control2: CGPoint(x: 11.7, y: 12.8))
                path.addCurve(to: CGPoint(x: 8.6, y: 11.8), control1: CGPoint(x: 9.8, y: 13), control2: CGPoint(x: 9, y: 12.6))
                path.move(to: CGPoint(x: 5.6, y: 6.3))
                path.addCurve(to: CGPoint(x: 7.2, y: 7.6), control1: CGPoint(x: 6.4, y: 6.3), control2: CGPoint(x: 7.1, y: 6.8))
                path.move(to: CGPoint(x: 10.4, y: 6.3))
                path.addCurve(to: CGPoint(x: 8.8, y: 7.6), control1: CGPoint(x: 9.6, y: 6.3), control2: CGPoint(x: 8.9, y: 6.8))
            case .bubble:
                path.move(to: CGPoint(x: 3, y: 4.6))
                path.addCurve(to: CGPoint(x: 4.7, y: 2.9), control1: CGPoint(x: 3, y: 3.6), control2: CGPoint(x: 3.7, y: 2.9))
                path.addLine(to: CGPoint(x: 11.3, y: 2.9))
                path.addCurve(to: CGPoint(x: 13, y: 4.6), control1: CGPoint(x: 12.3, y: 2.9), control2: CGPoint(x: 13, y: 3.6))
                path.addLine(to: CGPoint(x: 13, y: 9))
                path.addCurve(to: CGPoint(x: 11.3, y: 10.7), control1: CGPoint(x: 13, y: 10), control2: CGPoint(x: 12.3, y: 10.7))
                line([(11.3, 10.7), (7.4, 10.7), (4.6, 13), (4.6, 10.7)])
                path.addCurve(to: CGPoint(x: 3, y: 9), control1: CGPoint(x: 3.7, y: 10.6), control2: CGPoint(x: 3, y: 9.9))
                path.addLine(to: CGPoint(x: 3, y: 4.6))
            case .pause: line([(6, 4.2), (6, 11.8)]); line([(10, 4.2), (10, 11.8)])
            case .play: line([(5.6, 3.8), (5.6, 12.2), (12, 8), (5.6, 3.8)])
            case .eye:
                path.move(to: CGPoint(x: 1.9, y: 8))
                path.addCurve(to: CGPoint(x: 8, y: 3.7), control1: CGPoint(x: 1.9, y: 8), control2: CGPoint(x: 4.2, y: 3.7))
                path.addCurve(to: CGPoint(x: 14.1, y: 8), control1: CGPoint(x: 11.8, y: 3.7), control2: CGPoint(x: 14.1, y: 8))
                path.addCurve(to: CGPoint(x: 8, y: 12.3), control1: CGPoint(x: 14.1, y: 8), control2: CGPoint(x: 11.8, y: 12.3))
                path.addCurve(to: CGPoint(x: 1.9, y: 8), control1: CGPoint(x: 4.2, y: 12.3), control2: CGPoint(x: 1.9, y: 8))
                circle(8, 8, 1.9)
            case .info: circle(8, 8, 5.8); line([(8, 7.3), (8, 10.8)]); line([(8, 5.2), (8, 5.25)])
            case .exclamation: circle(8, 8, 5.6); line([(8, 5), (8, 8.4)])
            case .warning:
                path.move(to: CGPoint(x: 7.1, y: 3.1))
                path.addCurve(to: CGPoint(x: 8.9, y: 3.1), control1: CGPoint(x: 7.5, y: 2.4), control2: CGPoint(x: 8.5, y: 2.4))
                path.addLine(to: CGPoint(x: 13.8, y: 11.7))
                path.addCurve(to: CGPoint(x: 12.9, y: 13.2), control1: CGPoint(x: 14.2, y: 12.4), control2: CGPoint(x: 13.7, y: 13.2))
                path.addLine(to: CGPoint(x: 3.1, y: 13.2))
                path.addCurve(to: CGPoint(x: 2.2, y: 11.7), control1: CGPoint(x: 2.3, y: 13.2), control2: CGPoint(x: 1.8, y: 12.4))
                path.addLine(to: CGPoint(x: 7.1, y: 3.1))
                line([(8, 6.4), (8, 9.2)])
            case .refresh:
                path.move(to: CGPoint(x: 12.8, y: 7.5))
                path.addCurve(to: CGPoint(x: 8.001, y: 2.811), control1: CGPoint(x: 12.74, y: 4.893), control2: CGPoint(x: 10.609, y: 2.811))
                path.addCurve(to: CGPoint(x: 3.201, y: 7.611), control1: CGPoint(x: 5.35, y: 2.811), control2: CGPoint(x: 3.201, y: 4.96))
                path.addCurve(to: CGPoint(x: 8.001, y: 12.411), control1: CGPoint(x: 3.201, y: 10.261), control2: CGPoint(x: 5.35, y: 12.411))
                path.addCurve(to: CGPoint(x: 11.4, y: 11), control1: CGPoint(x: 9.277, y: 12.411), control2: CGPoint(x: 10.499, y: 11.903))
                line([(13, 3.7), (13, 7.5), (9.2, 7.5)])
            case .compose:
                path.move(to: CGPoint(x: 12.6, y: 9.4)); path.addLine(to: CGPoint(x: 12.6, y: 12.3))
                path.addCurve(to: CGPoint(x: 11.3, y: 13.6), control1: CGPoint(x: 12.6, y: 13), control2: CGPoint(x: 12, y: 13.6))
                path.addLine(to: CGPoint(x: 3.7, y: 13.6))
                path.addCurve(to: CGPoint(x: 2.4, y: 12.3), control1: CGPoint(x: 3, y: 13.6), control2: CGPoint(x: 2.4, y: 13))
                path.addLine(to: CGPoint(x: 2.4, y: 4.7))
                path.addCurve(to: CGPoint(x: 3.7, y: 3.4), control1: CGPoint(x: 2.4, y: 4), control2: CGPoint(x: 3, y: 3.4))
                path.addLine(to: CGPoint(x: 6.6, y: 3.4))
                path.move(to: CGPoint(x: 11.3, y: 2.5))
                path.addCurve(to: CGPoint(x: 13.3, y: 4.5), control1: CGPoint(x: 12.6, y: 1.2), control2: CGPoint(x: 14.6, y: 3.2))
                line([(13.3, 4.5), (8.1, 9.7), (5.5, 10.4), (6.2, 7.8), (11.3, 2.5)])
            case .book:
                path.move(to: CGPoint(x: 2.4, y: 3.3))
                path.addCurve(to: CGPoint(x: 8, y: 4.2), control1: CGPoint(x: 4.4, y: 2.6), control2: CGPoint(x: 6.3, y: 2.9))
                path.addLine(to: CGPoint(x: 8, y: 13.3))
                path.addCurve(to: CGPoint(x: 2.4, y: 12.4), control1: CGPoint(x: 6.3, y: 12), control2: CGPoint(x: 4.4, y: 11.7))
                path.addLine(to: CGPoint(x: 2.4, y: 3.3))
                path.move(to: CGPoint(x: 13.6, y: 3.3))
                path.addCurve(to: CGPoint(x: 8, y: 4.2), control1: CGPoint(x: 11.6, y: 2.6), control2: CGPoint(x: 9.7, y: 2.9))
                path.addLine(to: CGPoint(x: 8, y: 13.3))
                path.addCurve(to: CGPoint(x: 13.6, y: 12.4), control1: CGPoint(x: 9.7, y: 12), control2: CGPoint(x: 11.6, y: 11.7))
                path.addLine(to: CGPoint(x: 13.6, y: 3.3))
            case .sparkle:
                line([(7, 2.4), (8.1, 5.5), (11.2, 6.6), (8.1, 7.7), (7, 10.8), (5.9, 7.7), (2.8, 6.6), (5.9, 5.5), (7, 2.4)])
                line([(11.8, 9.6), (12.3, 11), (13.7, 11.5), (12.3, 12), (11.8, 13.4), (11.3, 12), (9.9, 11.5), (11.3, 11), (11.8, 9.6)])
            case .slash: line([(10.4, 2.8), (5.6, 13.2)])
            case .bell:
                path.move(to: CGPoint(x: 4.4, y: 10.9)); path.addLine(to: CGPoint(x: 4.4, y: 7.5))
                path.addCurve(to: CGPoint(x: 11.6, y: 7.5), control1: CGPoint(x: 4.4, y: 2.7), control2: CGPoint(x: 11.6, y: 2.7))
                line([(11.6, 7.5), (11.6, 10.9), (12.8, 12.2), (3.2, 12.2), (4.4, 10.9)])
                path.move(to: CGPoint(x: 6.7, y: 13.6))
                path.addCurve(to: CGPoint(x: 9.3, y: 13.6), control1: CGPoint(x: 7.3, y: 14.8), control2: CGPoint(x: 8.7, y: 14.8))
            case .ask:
                path.move(to: CGPoint(x: 3, y: 3.5)); path.addLine(to: CGPoint(x: 13, y: 3.5))
                path.addQuadCurve(to: CGPoint(x: 14, y: 4.5), control: CGPoint(x: 14, y: 3.5))
                path.addLine(to: CGPoint(x: 14, y: 10))
                path.addQuadCurve(to: CGPoint(x: 13, y: 11), control: CGPoint(x: 14, y: 11))
                line([(13, 11), (8.2, 11), (5.4, 13.2), (5.4, 11), (3, 11)])
                path.addQuadCurve(to: CGPoint(x: 2, y: 10), control: CGPoint(x: 2, y: 11))
                path.addLine(to: CGPoint(x: 2, y: 4.5))
                path.addQuadCurve(to: CGPoint(x: 3, y: 3.5), control: CGPoint(x: 2, y: 3.5))
                line([(5, 6.4), (11, 6.4)]); line([(5, 8.5), (8.6, 8.5)])
            case .upDown:
                line([(5.3, 6.3), (8, 3.6), (10.7, 6.3)])
                line([(5.3, 9.7), (8, 12.4), (10.7, 9.7)])
            }
        }
        let scale = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / LoomTheme.Icon.viewport, y: rect.height / LoomTheme.Icon.viewport)
        return path.applying(scale)
    }
}
