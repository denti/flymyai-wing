import Foundation

/// The wing, as data.
///
/// One definition, in the portable module, used by three things: the menu-bar template image,
/// the app icon generated at build time, and the tests that check the shape is drawable. A
/// glyph that exists twice is a glyph that will differ once.
///
/// Coordinates are normalised to the unit square with the origin at the bottom left, so the
/// same path renders at 22 pt in the menu bar and at 1024 px in the icon with no second set of
/// numbers to keep in sync.
public enum WingGeometry {

    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public init(_ x: Double, _ y: Double) {
            self.x = x
            self.y = y
        }
    }

    public enum Segment: Equatable, Sendable {
        case move(Point)
        case line(Point)
        case curve(to: Point, control1: Point, control2: Point)
        case close
    }

    /// The silhouette: a swept leading edge from the shoulder at the right down to the tip at
    /// the left, then a trailing edge with three feather notches walking back.
    ///
    /// Three notches, not five. More does not survive rendering at 22 pt, and each gap has to
    /// stay at least one point wide at 1x or the feathers merge into an unidentifiable smear.
    public static let outline: [Segment] = [
        .move(Point(1.00, 0.92)),
        .curve(to: Point(0.34, 0.58), control1: Point(0.78, 0.98), control2: Point(0.52, 0.82)),
        .curve(to: Point(0.00, 0.20), control1: Point(0.20, 0.44), control2: Point(0.06, 0.30)),
        .line(Point(0.14, 0.10)),
        .line(Point(0.24, 0.30)),      // notch 1
        .line(Point(0.36, 0.06)),
        .line(Point(0.48, 0.34)),      // notch 2
        .line(Point(0.62, 0.10)),
        .line(Point(0.74, 0.42)),      // notch 3
        .line(Point(0.90, 0.24)),
        .curve(to: Point(1.00, 0.92), control1: Point(1.00, 0.46), control2: Point(1.02, 0.72)),
        .close
    ]

    /// Every anchor point in the path, for bounds checking.
    public static var anchors: [Point] {
        outline.compactMap { segment in
            switch segment {
            case .move(let point), .line(let point): return point
            case .curve(let point, _, _): return point
            case .close: return nil
            }
        }
    }
}
