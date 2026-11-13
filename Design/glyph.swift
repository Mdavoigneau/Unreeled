// Writes the icon's glyph: the "U" of the Unreeled wordmark (Snell Roundhand Bold) as an SVG path
// on a 1024-point canvas, for Icon Composer.
//
//     swift Design/glyph.swift > Design/AppIcon.icon/Assets/U.svg
//
// Optional arguments: the glyph's height in points (default 600), and a horizontal and vertical
// nudge in points for optical centring (default -14 and 6).

import CoreText
import Foundation

let arguments = CommandLine.arguments.dropFirst().compactMap(Double.init)
let height = arguments.count > 0 ? arguments[0] : 600
let nudgeX = arguments.count > 1 ? arguments[1] : -14
let nudgeY = arguments.count > 2 ? arguments[2] : 6
let canvas = 1024.0

let font = CTFontCreateWithName("SnellRoundhand-Bold" as CFString, 1000, nil)
var characters = Array("U".utf16)
var glyphs = [CGGlyph](repeating: 0, count: characters.count)
guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count),
      let path = CTFontCreatePathForGlyph(font, glyphs[0], nil)
else { fatalError("No U in Snell Roundhand Bold") }

let box = path.boundingBoxOfPath
let scale = height / box.height
let offsetX = (canvas - box.width * scale) / 2 - box.minX * scale + nudgeX
let offsetY = (canvas - box.height * scale) / 2 + box.maxY * scale + nudgeY

var data = ""
path.applyWithBlock { element in
    let element = element.pointee
    func point(_ index: Int) -> String {
        let p = element.points[index]
        return String(format: "%.2f %.2f", p.x * scale + offsetX, offsetY - p.y * scale)
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

print("""
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <path fill="#FFFFFF" fill-rule="nonzero" d="\(data)"/>
</svg>
""")
