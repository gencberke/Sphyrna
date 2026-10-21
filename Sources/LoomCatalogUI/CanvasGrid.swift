import SwiftUI

/// The faint grid of an empty canvas (DESIGN §3 Colour's Grid row; the reference's `.artbg`): 1 pt lines every 28 pt in
/// `Surface.grid`, the pattern centred in the box, under the radial mask of the new-session page or the linear mask of Home's
/// band (`LoomTheme.Canvas`). It fills the space it is given, never takes a click and is hidden from accessibility. The
/// band is `LoomTheme.Canvas.bandHeight` high and sits at the top of its box.
struct CanvasGrid: View {
    var mask: LoomTheme.Canvas.Mask = .radial

    private typealias C = LoomTheme.Canvas

    var body: some View {
        Canvas { context, size in
            context.drawLayer { layer in
                // Two layers of lines, as the reference's two gradients: a crossing is a little brighter than a line.
                var vertical = Path()
                for x in C.lineOffsets(length: size.width) {
                    vertical.addRect(CGRect(x: x, y: 0, width: C.line, height: size.height))
                }
                var horizontal = Path()
                for y in C.lineOffsets(length: size.height) {
                    horizontal.addRect(CGRect(x: 0, y: y, width: size.width, height: C.line))
                }
                layer.fill(vertical, with: .color(LoomTheme.Surface.grid))
                layer.fill(horizontal, with: .color(LoomTheme.Surface.grid))
                // The mask keeps what it covers (destination-in): its alpha scales the lines drawn above.
                layer.blendMode = .destinationIn
                switch mask {
                case .radial:
                    // A unit circle stretched to the ellipse: radii are shares of the box's width and height.
                    layer.translateBy(x: size.width * C.radialCentre.x, y: size.height * C.radialCentre.y)
                    layer.scaleBy(x: size.width * C.radialRadii.width, y: size.height * C.radialRadii.height)
                    let gradient = Gradient(stops: [
                        .init(color: C.maskKeeps, location: 0),
                        .init(color: C.maskKeeps, location: C.radialOpaque),
                        .init(color: C.maskDrops, location: 1)])
                    layer.fill(Path(CGRect(x: -10, y: -10, width: 20, height: 20)),
                               with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: 1))
                case .band:
                    let gradient = Gradient(stops: [
                        .init(color: C.maskKeeps, location: 0),
                        .init(color: C.maskKeeps, location: C.bandOpaque),
                        .init(color: C.maskDrops, location: 1)])
                    layer.fill(Path(CGRect(origin: .zero, size: size)),
                               with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: mask == .band ? LoomTheme.Canvas.bandHeight : .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
