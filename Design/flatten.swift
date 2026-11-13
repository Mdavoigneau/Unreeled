// Writes the build's icon from Design/AppIcon.png, without transparency.
//
//     swift Design/flatten.swift
//
// Design/AppIcon.png is the icon as Icon Composer exports it: the rounded shape on a transparent
// square. App Store Connect refuses an icon that has transparency, and iOS cuts the corners off
// by itself, so the build's copy has the icon's blue where the picture is transparent. On the
// phone the two look the same.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appending(path: "Design/AppIcon.png")
let destination = root.appending(path: "Unreeled/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

guard let image = CGImageSourceCreateWithURL(source as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else {
    fatalError("Can't read \(source.path): run this from the repository's folder")
}
let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
// No alpha in the picture at all, rather than alpha that happens to be full.
guard let context = CGContext(
    data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("Can't draw in \(space)") }

let all = CGRect(x: 0, y: 0, width: image.width, height: image.height)
// The icon's blue, as in Design/AppIcon.icon/icon.json.
context.setFillColor(CGColor(srgbRed: 0.24706, green: 0.44706, blue: 0.60784, alpha: 1))
context.fill(all)
context.draw(image, in: all)

guard let flat = context.makeImage(),
      let file = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("Can't write \(destination.path)") }
CGImageDestinationAddImage(file, flat, nil)
guard CGImageDestinationFinalize(file) else { fatalError("Can't write \(destination.path)") }
print("Wrote \(destination.path): \(flat.width) x \(flat.height), no transparency")
