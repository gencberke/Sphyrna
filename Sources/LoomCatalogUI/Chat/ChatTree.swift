import SwiftUI

/// Where a row hangs on its branch of the stream's tree: the last row of an open group or turn fold ends the line.
enum ChatTreePosition: Equatable, Sendable {
    case middle
    case last
}

/// The strokes a row draws for the stream's trees (DESIGN §7), as plain geometry. `x` is a line's left edge from the column's
/// edge; `y` counts from the row's top. The group's steps branch from its icon as the sidebar's subagents branch from a
/// session's status mark (`SubagentBranches`): a 1 pt line, a turn of radius 6 into the row's middle and an arm to the next
/// icon. A row carries only its own part, so the line scrolls with it, and it runs through an opened body.
enum ChatTree {
    typealias Metrics = LoomTheme.Chat.Tree

    enum Stroke: Equatable {
        /// A step of an open group.
        case step(ChatTreePosition)
        /// An open group's own row: the line leaves the icon and runs to the row's foot.
        case head
        /// A row inside an open turn fold: the guide.
        case fold(ChatTreePosition)
    }

    enum Segment: Equatable {
        case line(x: CGFloat, from: CGFloat, to: CGFloat)
        /// Down from `top`, the curve into the row's middle, the arm.
        case turn(x: CGFloat, top: CGFloat)
    }

    /// The segments of a row `height` high whose work row is `lineHeight` high.
    static func segments(_ stroke: Stroke, height: CGFloat, lineHeight: CGFloat = LoomTheme.Chat.workRowHeight) -> [Segment] {
        switch stroke {
        case let .step(position):
            var result: [Segment] = [.turn(x: Metrics.groupLine, top: 0)]
            if position == .middle { result.append(.line(x: Metrics.groupLine, from: 0, to: height)) }
            return result
        case .head:
            return [.line(x: Metrics.groupLine, from: lineHeight - Metrics.overhang, to: height)]
        case let .fold(position):
            return [.line(x: Metrics.foldGuide, from: 0, to: position == .last ? max(0, height - Metrics.foldGuideEnd) : height)]
        }
    }

    /// The segments as one path in `rect`; `lineHeight` is the work row's, whose middle the turn enters.
    static func path(_ segments: [Segment], in rect: CGRect, lineHeight: CGFloat = LoomTheme.Chat.workRowHeight) -> Path {
        var path = Path()
        let half = Metrics.lineWidth / 2
        for segment in segments {
            switch segment {
            case let .line(x, from, to):
                path.move(to: CGPoint(x: rect.minX + x + half, y: rect.minY + from))
                path.addLine(to: CGPoint(x: rect.minX + x + half, y: rect.minY + to))
            case let .turn(x, top):
                let line = rect.minX + x + half
                let middle = rect.minY + top + lineHeight / 2 - half
                let radius = Metrics.curveRadius - half
                path.move(to: CGPoint(x: line, y: rect.minY + top))
                path.addLine(to: CGPoint(x: line, y: middle - radius))
                path.addArc(tangent1End: CGPoint(x: line, y: middle), tangent2End: CGPoint(x: line + radius, y: middle), radius: radius)
                path.addLine(to: CGPoint(x: rect.minX + x + Metrics.arm, y: middle))
            }
        }
        return path
    }
}

/// A row's tree strokes in the opaque tree colour, so crossing lines never brighten.
struct ChatTreeShape: Shape {
    let stroke: ChatTree.Stroke

    func path(in rect: CGRect) -> Path {
        ChatTree.path(ChatTree.segments(stroke, height: rect.height), in: rect)
    }
}

extension View {
    /// Draws `stroke` over this row's whole frame.
    func chatTree(_ stroke: ChatTree.Stroke?) -> some View {
        overlay(alignment: .topLeading) {
            if let stroke {
                ChatTreeShape(stroke: stroke)
                    .stroke(LoomTheme.Surface.tree, style: StrokeStyle(lineWidth: LoomTheme.Chat.Tree.lineWidth))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
