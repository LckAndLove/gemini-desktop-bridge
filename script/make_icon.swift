import AppKit
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                       bytesPerRow: 0, space: space,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rounded = CGPath(roundedRect: CGRect(x: 75, y: 75, width: 874, height: 874),
                     cornerWidth: 207, cornerHeight: 207, transform: nil)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: -14), blur: 38, color: color(0.12, 0.10, 0.34, 0.44))
canvas.addPath(rounded)
canvas.setFillColor(color(0.18, 0.24, 0.66))
canvas.fillPath()
canvas.restoreGState()

canvas.saveGState()
canvas.addPath(rounded)
canvas.clip()
let gradient = CGGradient(colorsSpace: space, colors: [
    color(0.20, 0.17, 0.52), color(0.30, 0.31, 0.79), color(0.23, 0.52, 0.94)
] as CFArray, locations: [0, 0.53, 1])!
canvas.drawLinearGradient(gradient, start: CGPoint(x: 860, y: 95), end: CGPoint(x: 220, y: 900),
                          options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
canvas.restoreGState()

canvas.addPath(rounded)
canvas.setStrokeColor(color(0.77, 0.87, 1, 0.24))
canvas.setLineWidth(3)
canvas.strokePath()

let lower = CGPoint(x: 316, y: 345)
let upper = CGPoint(x: 708, y: 681)
canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0.13, 0.13, 0.45, 0.35))
canvas.setStrokeColor(color(0.88, 0.94, 1))
canvas.setLineWidth(54)
canvas.setLineCap(.round)
canvas.move(to: lower)
canvas.addCurve(to: CGPoint(x: 660, y: upper.y), control1: CGPoint(x: 586, y: lower.y),
                control2: CGPoint(x: 440, y: upper.y))
canvas.strokePath()
canvas.setFillColor(color(0.75, 0.89, 1))
canvas.fillEllipse(in: CGRect(x: lower.x - 62, y: lower.y - 62, width: 124, height: 124))
canvas.setFillColor(color(0.25, 0.44, 0.83))
canvas.fillEllipse(in: CGRect(x: lower.x - 27, y: lower.y - 27, width: 54, height: 54))

// A single four-point terminal keeps the silhouette readable at small sizes.
let sparkle = CGMutablePath()
let x = upper.x, y = upper.y, r: CGFloat = 111, d: CGFloat = 23
sparkle.move(to: CGPoint(x: x, y: y + r))
sparkle.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x + d, y: y + d))
sparkle.addQuadCurve(to: CGPoint(x: x, y: y - r), control: CGPoint(x: x + d, y: y - d))
sparkle.addQuadCurve(to: CGPoint(x: x - r, y: y), control: CGPoint(x: x - d, y: y - d))
sparkle.addQuadCurve(to: CGPoint(x: x, y: y + r), control: CGPoint(x: x - d, y: y + d))
sparkle.closeSubpath()
canvas.addPath(sparkle)
canvas.setFillColor(color(0.96, 0.98, 1))
canvas.fillPath()
canvas.restoreGState()

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let png = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(png, canvas.makeImage()!, nil)
guard CGImageDestinationFinalize(png) else { exit(1) }
