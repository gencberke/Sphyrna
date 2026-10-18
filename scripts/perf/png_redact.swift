// Evidence helper: png_redact <png> <bottomCut> [x y w h]...  Cuts bottomCut pixels off the bottom (the sidebar footer
// shows usage figures) and paints each rectangle (pixel coordinates, origin top-left) with the colour of the pixel just
// to its left (the terminal banner shows the plan). Rewrites the file in place.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3, let cut = Int(args[2]) else { print("usage"); exit(2) }
let url = URL(fileURLWithPath: args[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { exit(1) }
let width = image.width, height = image.height - cut
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
context.draw(image, in: CGRect(x: 0, y: -cut, width: width, height: image.height))
var rects: [[Int]] = []
var index = 3
while index + 3 < args.count { rects.append((0..<4).map { Int(args[index + $0])! }); index += 4 }
if let data = context.data {
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    let stride = context.bytesPerRow
    for r in rects {
        // CGContext memory is top-down when drawn this way: row 0 is the top row.
        let sx = max(0, r[0] - 6), sy = r[1] + r[3] / 2
        let p = sy * stride + sx * 4
        let color = (bytes[p], bytes[p + 1], bytes[p + 2], bytes[p + 3])
        for y in max(0, r[1])..<min(height, r[1] + r[3]) {
            for x in max(0, r[0])..<min(width, r[0] + r[2]) {
                let q = y * stride + x * 4
                bytes[q] = color.0; bytes[q + 1] = color.1; bytes[q + 2] = color.2; bytes[q + 3] = color.3
            }
        }
    }
}
guard let out = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, out, nil)
exit(CGImageDestinationFinalize(destination) ? 0 : 1)
