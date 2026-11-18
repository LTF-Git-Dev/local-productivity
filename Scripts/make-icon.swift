// Draws the app icon and writes every size the asset catalog needs.
//
//   swift Scripts/make-icon.swift
//
// The icon is drawn in code so it can be adjusted and regenerated without a design tool:
// a sheet of paper with a heading, a couple of lines and two to-dos, on a calm blue field.

import AppKit
import SwiftUI

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("Local Productivity/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A rounded rectangle with the continuous corners used across Apple's platforms.
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

func drawIcon(in context: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // macOS icon grid: an 824pt shape centred in a 1024pt canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body, radius: 186)

    // Soft shadow under the whole icon.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0x000000, 0.28))
    context.addPath(shape)
    context.setFillColor(color(0x4A5BEA))
    context.fillPath()
    context.restoreGState()

    // The field: a blue that deepens towards the bottom.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let field = CGGradient(colorsSpace: space, colors: [color(0x7C9BFF), color(0x5672F5), color(0x3E4FD8)] as CFArray,
                           locations: [0, 0.5, 1])!
    context.drawLinearGradient(field, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
    // A wash of light from the top-left corner.
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.34), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: body.minX + 180, y: body.maxY - 110), startRadius: 0,
                               endCenter: CGPoint(x: body.minX + 180, y: body.maxY - 110), endRadius: 620, options: [])
    context.restoreGState()

    // The sheet of paper.
    let page = CGRect(x: 282, y: 214, width: 460, height: 596)
    let pageShape = squircle(page, radius: 58)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -22), blur: 46, color: color(0x101A66, 0.42))
    context.addPath(pageShape)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(pageShape)
    context.clip()
    let paper = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xF3F4F8)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(paper, start: CGPoint(x: page.midX, y: page.maxY), end: CGPoint(x: page.midX, y: page.minY), options: [])
    context.restoreGState()

    func bar(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat, _ fill: CGColor) {
        let rect = CGRect(x: page.minX + x, y: page.maxY - top - height, width: width, height: height)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        context.setFillColor(fill)
        context.fillPath()
    }

    let ink = color(0x1D1D1F)
    let line = color(0xD3D6DF)
    let margin: CGFloat = 62

    // Heading and two lines of text.
    bar(x: margin, top: 76, width: 214, height: 44, ink)
    bar(x: margin, top: 164, width: 336, height: 26, line)
    bar(x: margin, top: 216, width: 272, height: 26, line)

    // A finished to-do…
    let box: CGFloat = 56
    let doneBox = CGRect(x: page.minX + margin, y: page.maxY - 322 - box, width: box, height: box)
    context.addPath(squircle(doneBox, radius: 17))
    context.setFillColor(color(0x4C63F2))
    context.fillPath()
    context.setStrokeColor(color(0xFFFFFF))
    context.setLineWidth(8.5)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: doneBox.minX + 15, y: doneBox.midY - 1))
    context.addLine(to: CGPoint(x: doneBox.minX + 24.5, y: doneBox.midY - 10.5))
    context.addLine(to: CGPoint(x: doneBox.minX + 41, y: doneBox.midY + 10))
    context.strokePath()
    bar(x: margin + box + 26, top: 337, width: 218, height: 26, line)

    // …and one still to do.
    let openBox = CGRect(x: page.minX + margin, y: page.maxY - 414 - box, width: box, height: box).insetBy(dx: 4, dy: 4)
    context.addPath(squircle(openBox, radius: 14))
    context.setStrokeColor(color(0xC3C7D3))
    context.setLineWidth(8)
    context.strokePath()
    bar(x: margin + box + 26, top: 429, width: 164, height: 26, line)

    // A thin highlight along the top edge of the icon.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.addPath(squircle(body.insetBy(dx: 2, dy: 2), radius: 184))
    context.setStrokeColor(color(0xFFFFFF, 0.26))
    context.setLineWidth(4)
    context.strokePath()
    context.restoreGState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    let context = graphics.cgContext
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: context)
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for size in sizes {
    let name = size.scale == 1 ? "icon_\(size.points)x\(size.points).png" : "icon_\(size.points)x\(size.points)@2x.png"
    try render(pixels: size.points * size.scale).write(to: iconset.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(size.scale)x", "size": "\(size.points)x\(size.points)"])
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconset.appendingPathComponent("Contents.json"))
print("Wrote \(sizes.count) icon images to \(iconset.path)")
