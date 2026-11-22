// Prepares one image for LP's website: crops it (in source pixels), scales it to a width,
// optionally rounds its corners (transparent outside), converts it to sRGB and writes AVIF, JPEG
// or PNG — with no metadata. Used by Scripts/make-site-shots.sh.
//
//   swift Scripts/site-image.swift <in> <out.avif|.jpg|.png> [crop=x,y,w,h] [width=W]
//                                  [quality=0.0-1.0] [radius=R]   (R in output pixels)

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("site-image: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { fail("usage: site-image <in> <out> [crop=x,y,w,h] [width=W] [quality=Q] [radius=R]") }
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
var options: [String: String] = [:]
for argument in arguments.dropFirst(3) {
    let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { fail("not key=value: \(argument)") }
    options[parts[0]] = parts[1]
}

guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("can't read \(input.path)") }

if let crop = options["crop"] {
    let numbers = crop.split(separator: ",").compactMap { Double($0) }
    guard numbers.count == 4 else { fail("crop needs x,y,w,h") }
    let rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    guard rect.maxX <= Double(image.width), rect.maxY <= Double(image.height),
          let cropped = image.cropping(to: rect) else { fail("crop \(crop) is outside the \(image.width)×\(image.height) image") }
    image = cropped
}

let width = options["width"].flatMap(Int.init) ?? image.width
let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
let radius = options["radius"].flatMap(Double.init) ?? 0
let quality = options["quality"].flatMap(Double.init) ?? 0.8

let type: UTType
switch output.pathExtension.lowercased() {
case "avif":
    guard let avif = UTType("public.avif") else { fail("this Mac can't write AVIF") }
    type = avif
case "jpg", "jpeg": type = .jpeg
case "png": type = .png
default: fail("unknown output type .\(output.pathExtension)")
}
if radius > 0 && type == .jpeg { fail("JPEG has no transparency; round corners only for AVIF or PNG") }

guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no drawing context") }
context.interpolationQuality = .high
let bounds = CGRect(x: 0, y: 0, width: width, height: height)
if type == .jpeg {
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(bounds)
}
if radius > 0 {
    context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
}
context.draw(image, in: bounds)
guard let result = context.makeImage() else { fail("drawing failed") }

guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
    fail("can't write \(type.identifier) to \(output.path)")
}
CGImageDestinationAddImage(destination, result, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { fail("couldn't finish \(output.path)") }
let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
print("\(output.lastPathComponent): \(width)×\(height), \(bytes / 1024) KB")
