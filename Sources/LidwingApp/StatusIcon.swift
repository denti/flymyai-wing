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

    /// Rendered images, keyed by shape and thickness.
    ///
    /// The status item is refreshed on every reconcile tick, and re-rasterising a bezier path
    /// five times a minute for a picture that has not changed is exactly the kind of idle work
    /// that shows up in Activity Monitor's Energy tab. There are five shapes and one
    /// thickness, so the cache is bounded by construction.
    private static var cache: [String: NSImage] = [:]

    static func image(for shape: Shape, thickness: CGFloat) -> NSImage {
        let key = "\(shape)-\(Int(thickness * 2))"
        if let cached = cache[key] { return cached }
        let rendered = render(shape, thickness: thickness)
        cache[key] = rendered
        return rendered
    }

    private static func render(_ shape: Shape, thickness: CGFloat) -> NSImage {
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

    /// Renders the shared geometry from `LidwingCore.WingGeometry`. The menu-bar glyph and
    /// the app icon are the same path scaled differently; a glyph that exists twice is a glyph
    /// that will differ once.
    private static func wingPath(in box: NSRect) -> NSBezierPath {
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
                path.curve(to: place(point),
                           controlPoint1: place(control1),
                           controlPoint2: place(control2))
            case .close:
                path.close()
            }
        }
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

    /// Takes the whole snapshot for symmetry with the menu, though only the state decides.
    ///
    /// There was briefly a distinct glyph for "another app is in control", with an attention dot.
    /// It went with decision 0014: the only genuine conflict is the clamshell bit being set by
    /// somebody else, and that is the repair state, which has a glyph already. A
    /// `DenySystemSleep` holder is worth one quiet line and no badge at all - a dot in the menu
    /// bar is a warning, and warning a user about Internet Sharing being on is noise.
    static func shape(for snapshot: MenuPresenter.Snapshot) -> Shape {
        shape(for: snapshot.state)
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
