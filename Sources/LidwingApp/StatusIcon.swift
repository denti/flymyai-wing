import AppKit
import LidwingCore

/// The wing, drawn.
///
/// Drawn in code rather than shipped as an asset catalog, for three reasons: SwiftPM does not
/// compile asset catalogs, a vector drawn at the exact status-bar thickness is crisp at every
/// scale factor without shipping a single raster, and there is no `@3x` file to leak in (macOS
/// has no `@3x` displays, and shipping one is the loudest "ported from iOS" tell there is).
///
/// Everything is a **template image**: `isTemplate = true` hands the dark menu bar, menu-bar
/// tinting, the pressed state and selection inversion to AppKit. Never two colour variants,
/// and never `NSApp.effectiveAppearance` to pick between them — the status bar window's
/// appearance is set independently of the app's.
enum StatusIcon {

    /// Every state is distinguishable in pure greyscale, because a template image literally
    /// cannot carry colour and because the user may be running Differentiate Without Colour.
    enum Shape {
        case idle          // outline wing
        case armed         // solid wing
        case degraded      // solid wing + warning dot
        case failed        // solid wing + cross
        case unsupported   // outline wing, dimmed by appearsDisabled
    }

    static func image(for shape: Shape, thickness: CGFloat) -> NSImage {
        // The canvas is the status item's own box. Never a hardcoded 22 or 24: the drawable
        // thickness, the menu-bar band and the notch safe area are three different numbers on
        // one machine.
        let side = max(thickness, 16)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            draw(shape, in: side)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(_ shape: Shape, in side: CGFloat) {
        // Live area, optically matched to Apple's own menu extras: 18 x 13 pt on a 22 pt box.
        let liveWidth = side * (18.0 / 22.0)
        let liveHeight = side * (13.0 / 22.0)
        let originX = (side - liveWidth) / 2
        // A wing is bottom-heavy, so geometric centring reads as sagging. Nudge it up.
        let originY = (side - liveHeight) / 2 + side * (0.5 / 22.0)
        let box = NSRect(x: originX, y: originY, width: liveWidth, height: liveHeight)

        let wing = wingPath(in: box)
        NSColor.black.setFill()
        NSColor.black.setStroke()

        switch shape {
        case .idle, .unsupported:
            // Same silhouette as the armed state; only the fill differs. A slashed glyph is
            // never used: across SF Symbols a slash means blocked or failing, and users read
            // a slashed wing as "this is broken".
            wing.lineWidth = max(1.0, side / 22.0)
            wing.stroke()
        case .armed:
            wing.fill()
        case .degraded:
            wing.fill()
            badgeDot(in: side, filled: true).fill()
        case .failed:
            wing.fill()
            let cross = crossPath(in: side)
            cross.lineWidth = max(1.2, side / 18.0)
            cross.stroke()
        }
    }

    /// A swept wing with three feather notches. Three, because more does not survive 22 pt,
    /// and every gap is at least 1 pt or the feathers merge into an unidentifiable smear.
    private static func wingPath(in box: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let width = box.width
        let height = box.height
        func point(_ across: CGFloat, _ up: CGFloat) -> NSPoint {
            NSPoint(x: box.minX + across * width, y: box.minY + up * height)
        }

        // Leading edge: a long sweep from the shoulder at the right down to the tip at the left.
        path.move(to: point(1.00, 0.92))
        path.curve(to: point(0.34, 0.58),
                   controlPoint1: point(0.78, 0.98),
                   controlPoint2: point(0.52, 0.82))
        path.curve(to: point(0.00, 0.20),
                   controlPoint1: point(0.20, 0.44),
                   controlPoint2: point(0.06, 0.30))

        // Trailing edge with three notches, walking back towards the shoulder.
        path.line(to: point(0.14, 0.10))
        path.line(to: point(0.24, 0.30))     // notch 1
        path.line(to: point(0.36, 0.06))
        path.line(to: point(0.48, 0.34))     // notch 2
        path.line(to: point(0.62, 0.10))
        path.line(to: point(0.74, 0.42))     // notch 3
        path.line(to: point(0.90, 0.24))
        path.curve(to: point(1.00, 0.92),
                   controlPoint1: point(1.00, 0.46),
                   controlPoint2: point(1.02, 0.72))
        path.close()
        return path
    }

    /// A dot at the upper right of the box. Small, and never the only cue: the menu header and
    /// a user notification carry the same state in words.
    private static func badgeDot(in side: CGFloat, filled: Bool) -> NSBezierPath {
        let diameter = max(3.0, side * (3.0 / 22.0))
        let rect = NSRect(x: side - diameter - 1, y: side - diameter - 1,
                          width: diameter, height: diameter)
        let path = NSBezierPath(ovalIn: rect)
        if !filled { path.lineWidth = 1.0 }
        return path
    }

    private static func crossPath(in side: CGFloat) -> NSBezierPath {
        let arm = max(3.0, side * (4.0 / 22.0))
        let originX = side - arm - 1
        let originY = side - arm - 1
        let path = NSBezierPath()
        path.move(to: NSPoint(x: originX, y: originY))
        path.line(to: NSPoint(x: originX + arm, y: originY + arm))
        path.move(to: NSPoint(x: originX + arm, y: originY))
        path.line(to: NSPoint(x: originX, y: originY + arm))
        return path
    }

    static func shape(for state: LidwingState) -> Shape {
        switch state {
        case .idle, .disarming: return .idle
        case .arming, .armed: return .armed
        case .degraded: return .degraded
        case .failed, .repair: return .failed
        case .unsupported: return .unsupported
        }
    }
}
