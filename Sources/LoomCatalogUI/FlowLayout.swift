import SwiftUI

/// Items that wrap onto the next line as whole items: an item is never split across two lines. Centred
/// (the draft's presets) or leading (the project page's stats line).
struct FlowLayout: Layout {
    var spacing: CGFloat
    /// Between lines; `spacing` when nil.
    var lineSpacing: CGFloat?
    var centered = true

    /// Which items share a line, as indices in order: an item goes on the current line while it fits, else
    /// it starts the next one (an item wider than the line is alone on one). Pure, so a test reads it.
    static func lines(widths: [CGFloat], spacing: CGFloat, available: CGFloat) -> [[Int]] {
        var lines: [[Int]] = [[]]
        var used: CGFloat = 0
        for (index, width) in widths.enumerated() {
            let needed = (lines[lines.count - 1].isEmpty ? 0 : spacing) + width
            if used + needed > available, !lines[lines.count - 1].isEmpty {
                lines.append([index])
                used = width
            } else {
                lines[lines.count - 1].append(index)
                used += needed
            }
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + (lineSpacing ?? spacing) * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (centered ? (bounds.width - row.width) / 2 : 0)
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + (lineSpacing ?? spacing)
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return Self.lines(widths: sizes.map(\.width), spacing: spacing, available: width).map { line in
            Row(indices: line,
                width: line.reduce(0) { $0 + sizes[$1].width } + spacing * CGFloat(max(line.count - 1, 0)),
                height: line.map { sizes[$0].height }.max() ?? 0)
        }
    }
}
