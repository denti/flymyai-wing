// Generates the 1024 px app icon from the same wing geometry the menu bar uses.
//
// Run at build time rather than committed as a binary asset, so there is exactly one
// definition of the shape and no chance of the icon and the menu-bar glyph drifting apart.
//
//   swiftc -O -o /tmp/make-icon Scripts/icon/main.swift Sources/LidwingCore/WingGeometry.swift
//   /tmp/make-icon Resources/icon_1024.png
//
// The file is called main.swift because Swift allows top-level code only there when more than
// one file is being compiled.
//
// Full-bleed and square, with **no pre-rounded corners and no exported canvas mask**: macOS
// applies its own mask, and providing one degrades the specular highlight and leaves jagged
// edges.

import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/icon_1024.png"
let side: CGFloat = 1024

guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                    pixelsWide: Int(side), pixelsHigh: Int(side),
                                    bitsPerSample: 8, samplesPerPixel: 4,
                                    hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0) else {
    FileHandle.standardError.write(Data("cannot allocate the bitmap\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

let canvas = NSRect(x: 0, y: 0, width: side, height: side)

// A calm, dark ground. The icon appears in the Login Items row and in the Privacy & Security
// panel — the two moments a user decides whether to trust an app — so it reads as a utility,
// not as a toy.
let background = NSGradient(colors: [
    NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.16, alpha: 1.0),
    NSColor(calibratedRed: 0.16, green: 0.21, blue: 0.32, alpha: 1.0)
])
background?.draw(in: canvas, angle: 90)

// The wing, in the same proportions as the menu-bar glyph: an 18 x 13 live area on a 22 pt
// box, centred and nudged up because a wing is bottom-heavy.
let liveWidth = side * (18.0 / 22.0) * 0.78
let liveHeight = side * (13.0 / 22.0) * 0.78
let box = NSRect(x: (side - liveWidth) / 2,
                 y: (side - liveHeight) / 2 + side * 0.02,
                 width: liveWidth, height: liveHeight)

let path = NSBezierPath()
func place(_ point: WingGeometry.Point) -> NSPoint {
    NSPoint(x: box.minX + CGFloat(point.x) * box.width,
            y: box.minY + CGFloat(point.y) * box.height)
}
for segment in WingGeometry.outline {
    switch segment {
    case .move(let point):
        path.move(to: place(point))
    case .line(let point):
        path.line(to: place(point))
    case .curve(let point, let control1, let control2):
        path.curve(to: place(point), controlPoint1: place(control1), controlPoint2: place(control2))
    case .close:
        path.close()
    }
}

NSColor.white.setFill()
path.fill()

NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("cannot encode the PNG\n".utf8))
    exit(1)
}
do {
    try data.write(to: URL(fileURLWithPath: outputPath))
    print("wrote \(outputPath) (\(Int(side))x\(Int(side)))")
} catch {
    FileHandle.standardError.write(Data("cannot write \(outputPath): \(error)\n".utf8))
    exit(1)
}
