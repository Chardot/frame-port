// Draws the app icon and writes every size the asset catalog needs.
//
//   swift Tools/make-icon.swift
//
// Run it from the project root; it overwrites FramePort/Assets.xcassets/AppIcon.appiconset.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255,
        alpha,
    ])!
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// A rectangle with only its left or only its right corners rounded.
func handlePath(_ rect: CGRect, radius: CGFloat, roundsLeft: Bool) -> CGPath {
    let path = CGMutablePath()
    if roundsLeft {
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radius)
    } else {
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radius)
    }
    path.closeSubpath()
    return path
}

func fillGradient(_ context: CGContext, in rect: CGRect, top: CGColor, bottom: CGColor) {
    let gradient = CGGradient(colorsSpace: sRGB, colors: [top, bottom] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
}

func renderIcon(pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    // Work on a 1024-point canvas with the origin at the top-left.
    let scale = CGFloat(pixels) / 1024
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)

    // The standard macOS icon body: an 824-point rounded square with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = roundedRect(body, radius: 186)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: color(0x000000, alpha: 0.38))
    context.addPath(bodyPath)
    context.setFillColor(color(0x1B1B1F))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    fillGradient(context, in: body, top: color(0x3A3A42), bottom: color(0x141417))

    // A strip of three frames; the outer two run off the edges.
    let frameSize = CGSize(width: 320, height: 248)
    let handleWidth: CGFloat = 52
    let gap: CGFloat = 22
    let center = CGRect(x: 512 - frameSize.width / 2, y: 512 - frameSize.height / 2, width: frameSize.width, height: frameSize.height)
    let left = center.offsetBy(dx: -(frameSize.width + handleWidth + gap), dy: 0)
    let right = center.offsetBy(dx: frameSize.width + handleWidth + gap, dy: 0)
    for side in [left, right] {
        context.addPath(roundedRect(side, radius: 16))
        context.setFillColor(color(0xFFFFFF, alpha: 0.14))
        context.fillPath()
    }

    // The selected frame: a small picture.
    context.saveGState()
    context.addPath(roundedRect(center, radius: 10))
    context.clip()
    fillGradient(context, in: center, top: color(0x7CC4FF), bottom: color(0x3A7FF0))
    context.setFillColor(color(0xFFFFFF, alpha: 0.95))
    context.fillEllipse(in: CGRect(x: center.maxX - 112, y: center.minY + 40, width: 62, height: 62))
    let farHill = CGMutablePath()
    farHill.move(to: CGPoint(x: center.minX + 70, y: center.maxY))
    farHill.addLine(to: CGPoint(x: center.minX + 206, y: center.minY + 104))
    farHill.addLine(to: CGPoint(x: center.maxX + 30, y: center.maxY))
    farHill.closeSubpath()
    context.addPath(farHill)
    context.setFillColor(color(0x2B5FC4))
    context.fillPath()
    let nearHill = CGMutablePath()
    nearHill.move(to: CGPoint(x: center.minX - 30, y: center.maxY))
    nearHill.addLine(to: CGPoint(x: center.minX + 96, y: center.minY + 136))
    nearHill.addLine(to: CGPoint(x: center.minX + 222, y: center.maxY))
    nearHill.closeSubpath()
    context.addPath(nearHill)
    context.setFillColor(color(0x1D4496))
    context.fillPath()
    context.restoreGState()

    // The yellow trim frame around it: a bar above and below, a handle on each side.
    let banana = color(0xFFCC1A)
    let bar: CGFloat = 24
    let frameTop = center.minY - bar
    let frameHeight = center.height + 2 * bar
    context.setFillColor(banana)
    context.fill(CGRect(x: center.minX - 1, y: frameTop, width: center.width + 2, height: bar))
    context.fill(CGRect(x: center.minX - 1, y: center.maxY, width: center.width + 2, height: bar))
    let leftHandle = CGRect(x: center.minX - handleWidth, y: frameTop, width: handleWidth, height: frameHeight)
    let rightHandle = CGRect(x: center.maxX, y: frameTop, width: handleWidth, height: frameHeight)
    context.addPath(handlePath(leftHandle, radius: 26, roundsLeft: true))
    context.addPath(handlePath(rightHandle, radius: 26, roundsLeft: false))
    context.fillPath()
    for handle in [leftHandle, rightHandle] {
        let grip = CGRect(x: handle.midX - 5, y: handle.midY - 38, width: 10, height: 76)
        context.addPath(roundedRect(grip, radius: 5))
        context.setFillColor(color(0x3A2A00, alpha: 0.72))
        context.fillPath()
    }
    context.restoreGState()

    // A faint rim of light along the top edge of the body.
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    context.addPath(roundedRect(body.insetBy(dx: 2, dy: 2), radius: 184))
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.10))
    context.setLineWidth(4)
    context.strokePath()
    context.restoreGState()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

let iconSet = URL(fileURLWithPath: "FramePort/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
guard FileManager.default.fileExists(atPath: iconSet.path) else {
    FileHandle.standardError.write(Data("Run this from the project root: \(iconSet.path) not found.\n".utf8))
    exit(1)
}

for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    try writePNG(renderIcon(pixels: pixels), to: iconSet.appendingPathComponent("icon_\(pixels).png"))
}

// (points, scale) pairs macOS expects, mapped to the pixel sizes above.
let slots: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
let images = slots.map { slot in
    ["idiom": "mac", "size": "\(slot.points)x\(slot.points)", "scale": "\(slot.scale)x", "filename": "icon_\(slot.points * slot.scale).png"]
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSet.appendingPathComponent("Contents.json"))
print("Wrote \(slots.count) icon slots to \(iconSet.path)")
