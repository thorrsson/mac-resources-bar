import CoreGraphics
import Foundation
import ImageIO

let outputPath = CommandLine.arguments.dropFirst().first ?? "build/ResourcesBar.iconset"
let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
let fileManager = FileManager.default
try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])!
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawStar(_ context: CGContext, center: CGPoint, radius: CGFloat) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x, y: center.y + radius))
    path.addLine(to: CGPoint(x: center.x + radius * 0.2, y: center.y + radius * 0.2))
    path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
    path.addLine(to: CGPoint(x: center.x + radius * 0.2, y: center.y - radius * 0.2))
    path.addLine(to: CGPoint(x: center.x, y: center.y - radius))
    path.addLine(to: CGPoint(x: center.x - radius * 0.2, y: center.y - radius * 0.2))
    path.addLine(to: CGPoint(x: center.x - radius, y: center.y))
    path.addLine(to: CGPoint(x: center.x - radius * 0.2, y: center.y + radius * 0.2))
    path.closeSubpath()
    context.addPath(path)
    context.fillPath()
}

func drawIcon(size: Int) -> CGImage? {
    let dimension = CGFloat(size)
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }
    context.scaleBy(x: dimension / 1024, y: dimension / 1024)

    let background = roundedRect(CGRect(x: 36, y: 36, width: 952, height: 952), radius: 228)
    context.addPath(background)
    context.clip()
    let backgroundGradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [
            color(0.07, 0.11, 0.27),
            color(0.16, 0.18, 0.43),
            color(0.23, 0.12, 0.38)
        ] as CFArray,
        locations: [0, 0.56, 1]
    )!
    context.drawLinearGradient(backgroundGradient, start: CGPoint(x: 120, y: 950), end: CGPoint(x: 900, y: 70), options: [])

    context.setFillColor(color(0.28, 0.77, 0.96, 0.22))
    context.fillEllipse(in: CGRect(x: 660, y: 720, width: 330, height: 330))
    context.setFillColor(color(0.97, 0.38, 0.62, 0.18))
    context.fillEllipse(in: CGRect(x: -130, y: 40, width: 400, height: 400))

    let panel = roundedRect(CGRect(x: 145, y: 245, width: 734, height: 536), radius: 122)
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 38, color: color(0.02, 0.03, 0.12, 0.4))
    context.addPath(panel)
    context.setFillColor(color(0.96, 0.98, 1, 0.16))
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0)
    context.addPath(panel)
    context.setStrokeColor(color(1, 1, 1, 0.5))
    context.setLineWidth(6)
    context.strokePath()

    let baseline: CGFloat = 335
    let barWidth: CGFloat = 92
    let positions: [CGFloat] = [248, 397, 546, 695]
    let heights: [CGFloat] = [225, 330, 275, 390]
    let gradients: [[CGColor]] = [
        [color(0.23, 0.82, 1), color(0.1, 0.49, 0.98)],
        [color(0.27, 0.95, 0.76), color(0.08, 0.68, 0.7)],
        [color(1, 0.85, 0.35), color(1, 0.57, 0.2)],
        [color(1, 0.54, 0.69), color(0.9, 0.31, 0.62)]
    ]

    for index in positions.indices {
        let x = positions[index]
        let track = roundedRect(CGRect(x: x, y: baseline, width: barWidth, height: 360), radius: barWidth / 2)
        context.addPath(track)
        context.setFillColor(color(1, 1, 1, 0.12))
        context.fillPath()

        let bar = roundedRect(CGRect(x: x, y: baseline, width: barWidth, height: heights[index]), radius: barWidth / 2)
        context.saveGState()
        context.addPath(bar)
        context.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: gradients[index] as CFArray, locations: nil)!
        context.drawLinearGradient(gradient, start: CGPoint(x: x, y: baseline), end: CGPoint(x: x + barWidth, y: baseline + heights[index]), options: [])
        context.restoreGState()
    }

    context.setFillColor(color(1, 1, 1, 0.94))
    drawStar(context, center: CGPoint(x: 778, y: 830), radius: 37)
    context.setFillColor(color(0.63, 0.88, 1, 0.9))
    drawStar(context, center: CGPoint(x: 234, y: 866), radius: 22)
    context.setFillColor(color(1, 0.79, 0.46, 0.95))
    context.fillEllipse(in: CGRect(x: 735, y: 184, width: 22, height: 22))

    return context.makeImage()
}

let iconFiles: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in iconFiles {
    guard
        let image = drawIcon(size: size),
        let destination = CGImageDestinationCreateWithURL(
            outputURL.appendingPathComponent(name) as CFURL,
            "public.png" as CFString,
            1,
            nil
        )
    else {
        fatalError("Could not create app icon at \(size)x\(size)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not write \(name)")
    }
}
