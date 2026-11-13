// Makes the website's images: the app icon at the sizes browsers and AltStore use, the wordmark,
// the card shown when someone shares a link to the site, and the screenshots.
//
//     swift website/tools/images.swift
//     swift website/tools/images.swift --icon path/to/AppIcon.icon
//     swift website/tools/images.swift --screenshot path/to/simulator-screenshot.png welcome
//
// Run it from anywhere on a Mac with Xcode 26 or later, which includes Icon Composer, whenever the
// icon changes. It writes into website/public, and those files are committed: the site's build on
// Cloudflare doesn't run it.
//
// Screenshots come from the iOS simulator (`xcrun simctl io booted screenshot shot.png`), with
// the status bar set to 9:41 and nobody's posts, stories or messages on screen.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let website = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let root = website.deletingLastPathComponent()
let publicDir = website.appending(path: "public")
let imagesDir = publicDir.appending(path: "images")

let ink = CGColor(srgbRed: 0x26 / 255, green: 0x26 / 255, blue: 0x26 / 255, alpha: 1)
let secondary = CGColor(srgbRed: 0x73 / 255, green: 0x73 / 255, blue: 0x73 / 255, alpha: 1)
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let avif = UTType("public.avif")!

// MARK: - Images in and out

func load(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fatalError("Can't read \(url.path)") }
    return image
}

func canvas(_ width: Int, _ height: Int) -> CGContext {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    return context
}

/// Scales down in halves first, which keeps small sizes from looking ragged.
func resized(_ image: CGImage, _ width: Int, _ height: Int, background: CGColor? = nil) -> CGImage {
    var current = image
    while current.width / 2 >= width * 2 {
        let half = canvas(current.width / 2, current.height / 2)
        half.draw(current, in: CGRect(x: 0, y: 0, width: half.width, height: half.height))
        current = half.makeImage()!
    }
    let context = canvas(width, height)
    if let background {
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    context.draw(current, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

func write(_ images: [CGImage], to url: URL, type: UTType = .png, quality: Double? = nil) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil)
    else { fatalError("Can't write \(url.path)") }
    let properties = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
    for image in images { CGImageDestinationAddImage(destination, image, properties) }
    guard CGImageDestinationFinalize(destination) else { fatalError("Can't write \(url.path)") }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("\(url.path.replacingOccurrences(of: root.path + "/", with: "")) (\(size / 1024) KB)")
}

// MARK: - The icon

/// Icon Composer's renderer, which draws the icon as iOS shows it: glass, shadows and the rounded
/// mask included.
func ictool() -> URL {
    let pipe = Pipe()
    let xcodeSelect = Process()
    xcodeSelect.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    xcodeSelect.arguments = ["-p"]
    xcodeSelect.standardOutput = pipe
    try? xcodeSelect.run()
    xcodeSelect.waitUntilExit()
    let developer = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let candidates = [
        URL(fileURLWithPath: developer).deletingLastPathComponent()
            .appending(path: "Applications/Icon Composer.app/Contents/Executables/ictool"),
        URL(fileURLWithPath: "/Applications/Icon Composer.app/Contents/Executables/ictool"),
    ]
    guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    else { fatalError("Icon Composer's ictool not found; install Xcode 26 or later.") }
    return found
}

func renderIcon(_ document: URL, size: Int) -> CGImage {
    let output = FileManager.default.temporaryDirectory.appending(path: "unreeled-icon-\(size).png")
    let process = Process()
    process.executableURL = ictool()
    process.arguments = [
        document.path, "--export-image", "--output-file", output.path, "--platform", "iOS",
        "--rendition", "Default", "--width", "\(size)", "--height", "\(size)", "--scale", "1",
    ]
    process.standardOutput = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("ictool couldn't render \(document.path)") }
    return load(output)
}

/// The colour along the icon's middle column, at a fraction of its height, for filling the corners
/// where a square, opaque icon is needed.
func edgeColor(_ icon: CGImage, at fraction: Double) -> CGColor {
    let context = canvas(1, 1)
    let y = Double(icon.height) * fraction
    context.draw(icon, in: CGRect(x: -Double(icon.width) / 2, y: -y, width: Double(icon.width), height: Double(icon.height)))
    let pixel = context.data!.assumingMemoryBound(to: UInt8.self)
    return CGColor(srgbRed: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255, alpha: 1)
}

/// Opaque and square, for iOS's home screen, which rounds the corners itself and shows black
/// where an icon is transparent.
func opaqueIcon(_ icon: CGImage, size: Int) -> CGImage {
    let context = canvas(size, size)
    let gradient = CGGradient(
        colorsSpace: sRGB, colors: [edgeColor(icon, at: 0.05), edgeColor(icon, at: 0.95)] as CFArray, locations: [0, 1]
    )!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size), options: [])
    context.draw(resized(icon, size, size), in: CGRect(x: 0, y: 0, width: size, height: size))
    return context.makeImage()!
}

// MARK: - Type

/// Text as one outline, laid out by Core Text the way the app draws it (with the font's own
/// kerning and substitutions).
func outline(_ text: String, font name: String, size: Double) -> CGPath {
    let font = CTFontCreateWithName(name as CFString, size, nil)
    let attributes = [kCTFontAttributeName: font] as CFDictionary
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes))
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(), &glyphs)
        CTRunGetPositions(run, CFRange(), &positions)
        let runAttributes = CTRunGetAttributes(run) as NSDictionary
        let runFont = runAttributes[kCTFontAttributeName] as! CTFont
        for (glyph, position) in zip(glyphs, positions) {
            if let glyphPath = CTFontCreatePathForGlyph(runFont, glyph, nil) {
                path.addPath(glyphPath, transform: CGAffineTransform(translationX: position.x, y: position.y))
            }
        }
    }
    guard !path.isEmpty else { fatalError("\(name) isn't installed") }
    return path
}

/// The wordmark as an SVG: "Unreeled" in Snell Roundhand Bold, like the app's top bar.
func wordmarkSVG() -> String {
    let path = outline("Unreeled", font: "SnellRoundhand-Bold", size: 100)
    let box = path.boundingBoxOfPath.insetBy(dx: -2, dy: -2)
    var data = ""
    path.applyWithBlock { element in
        let element = element.pointee
        func point(_ index: Int) -> String {
            let p = element.points[index]
            return String(format: "%.1f %.1f", p.x - box.minX, box.maxY - p.y)
        }
        switch element.type {
        case .moveToPoint: data += "M\(point(0))"
        case .addLineToPoint: data += "L\(point(0))"
        case .addQuadCurveToPoint: data += "Q\(point(0)) \(point(1))"
        case .addCurveToPoint: data += "C\(point(0)) \(point(1)) \(point(2))"
        case .closeSubpath: data += "Z"
        @unknown default: break
        }
    }
    let width = String(format: "%.0f", box.width.rounded(.up))
    let height = String(format: "%.0f", box.height.rounded(.up))
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(width) \(height)" width="\(width)" height="\(height)">
      <title>Unreeled</title>
      <path fill="#262626" d="\(data)"/>
    </svg>

    """
}

// MARK: - The card for shared links

/// 1200 × 630, as Open Graph and X want it: the icon, the wordmark and the tagline on white.
func socialCard(icon: CGImage) -> CGImage {
    let (width, height) = (1200, 630)
    let context = canvas(width, height)
    context.setFillColor(white)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let iconSize = 272.0
    let wordmark = outline("Unreeled", font: "SnellRoundhand-Bold", size: 150)
    let lines = ["Your friends on Instagram,", "without the rabbit hole."].map {
        outline($0, font: "HelveticaNeue-Light", size: 46)
    }
    let wordmarkBox = wordmark.boundingBoxOfPath
    let lineHeight = 58.0
    let textWidth = max(wordmarkBox.width, lines.map(\.boundingBoxOfPath.maxX).max()!)
    let gap = 64.0
    let left = (Double(width) - iconSize - gap - textWidth) / 2

    // The icon, centred vertically, with room for its own shadow.
    context.draw(icon, in: CGRect(x: left, y: (Double(height) - iconSize) / 2, width: iconSize, height: iconSize))

    // The wordmark above two lines of tagline, the block centred on the icon.
    let textLeft = left + iconSize + gap
    let blockHeight = wordmarkBox.height + 28 + lineHeight * Double(lines.count)
    let top = (Double(height) + blockHeight) / 2
    context.saveGState()
    context.translateBy(x: textLeft - wordmarkBox.minX, y: top - wordmarkBox.maxY)
    context.addPath(wordmark)
    context.setFillColor(ink)
    context.fillPath()
    context.restoreGState()
    var baseline = top - wordmarkBox.height - 28 - 44
    for line in lines {
        context.saveGState()
        context.translateBy(x: textLeft, y: baseline)
        context.addPath(line)
        context.setFillColor(secondary)
        context.fillPath()
        context.restoreGState()
        baseline -= lineHeight
    }
    return context.makeImage()!
}

// MARK: - Screenshots

/// A simulator screenshot at 600 pixels wide: sharp at the 300 points the page shows it at.
func screenshot(_ input: URL, name: String) {
    let image = load(input)
    let context = canvas(image.width, image.height)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    // The app keeps its hidden web view, one point square, in the top-left corner. A phone's
    // rounded screen corner hides it; paint it out here.
    let point = Double(image.width) / 402
    context.setFillColor(white)
    context.fill(CGRect(x: 0, y: Double(image.height) - point * 2, width: point * 2, height: point * 2))
    let cleaned = context.makeImage()!
    let width = 600
    let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
    let small = resized(cleaned, width, height, background: white)
    write([small], to: imagesDir.appending(path: "\(name).png"))
    write([small], to: imagesDir.appending(path: "\(name).avif"), type: avif, quality: 0.8)
}

// MARK: - Main

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--screenshot", arguments.count == 3 {
    screenshot(URL(fileURLWithPath: arguments[1]), name: arguments[2])
    exit(0)
}
var document = root.appending(path: "Design/AppIcon.icon")
if arguments.first == "--icon", arguments.count == 2 {
    document = URL(fileURLWithPath: arguments[1])
}
guard FileManager.default.fileExists(atPath: document.path) else { fatalError("No icon at \(document.path)") }
try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

let icon = renderIcon(document, size: 1024)
// For AltStore's source and anyone who needs the icon: as iOS draws it, corners and all. (Redrawn
// at 512 pixels and 8 bits a channel: ictool's own file has 16.)
write([resized(icon, 512, 512)], to: publicDir.appending(path: "icon.png"))
// The page's own copy, for the header and the top of the home page (up to 128 points), in AVIF
// with a PNG for browsers without it.
let pageIcon = resized(icon, 384, 384)
write([pageIcon], to: imagesDir.appending(path: "icon-384.png"))
write([pageIcon], to: imagesDir.appending(path: "icon-384.avif"), type: avif, quality: 0.85)
// Browsers' tabs and search results.
write([resized(icon, 192, 192)], to: imagesDir.appending(path: "icon-192.png"))
write([16, 32, 48].map { resized(icon, $0, $0) }, to: publicDir.appending(path: "favicon.ico"), type: UTType("com.microsoft.ico")!)
// iOS's home screen, when someone adds the site to it.
write([opaqueIcon(icon, size: 180)], to: publicDir.appending(path: "apple-touch-icon.png"))
// The wordmark, as a vector.
let svgURL = imagesDir.appending(path: "wordmark.svg")
try! wordmarkSVG().write(to: svgURL, atomically: true, encoding: .utf8)
print(svgURL.path.replacingOccurrences(of: root.path + "/", with: ""))
// What a shared link to the site shows.
write([socialCard(icon: renderIcon(document, size: 544))], to: imagesDir.appending(path: "og.png"))
