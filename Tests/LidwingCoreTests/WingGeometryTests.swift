import XCTest
@testable import LidwingCore

/// The glyph is the entire visible surface of this product, and it is drawn from data. These
/// tests hold the shape to the constraints that make it legible at 22 pt, where a mistake is
/// not a rendering artefact but an unidentifiable smear in somebody's menu bar.
final class WingGeometryTests: XCTestCase {

    func testThePathIsClosedAndStartsWithAMove() {
        guard case .move = WingGeometry.outline.first else {
            return XCTFail("a path that does not begin with a move draws from wherever the last one ended")
        }
        XCTAssertEqual(WingGeometry.outline.last, .close)
    }

    func testEveryAnchorIsInsideTheUnitSquare() {
        // Control points may overshoot slightly to shape a curve; anchors may not, or the
        // glyph is clipped by the status item's own box.
        for point in WingGeometry.anchors {
            XCTAssertTrue((0.0...1.0).contains(point.x), "x out of range: \(point)")
            XCTAssertTrue((0.0...1.0).contains(point.y), "y out of range: \(point)")
        }
    }

    func testTheShapeUsesTheWholeBox() {
        let xs = WingGeometry.anchors.map(\.x)
        let ys = WingGeometry.anchors.map(\.y)
        XCTAssertEqual(xs.min() ?? 1, 0.0, accuracy: 0.02, "the wing should reach the left edge")
        XCTAssertEqual(xs.max() ?? 0, 1.0, accuracy: 0.02, "the wing should reach the right edge")
        XCTAssertLessThan(ys.min() ?? 1, 0.15)
        XCTAssertGreaterThan(ys.max() ?? 0, 0.85)
    }

    /// Three notches, not five: more does not survive 22 pt. A notch is a local maximum in the
    /// trailing edge, so counting the direction changes counts the feathers.
    func testThereAreExactlyThreeFeatherNotches() {
        let trailing = WingGeometry.outline.compactMap { segment -> WingGeometry.Point? in
            if case .line(let point) = segment { return point }
            return nil
        }
        XCTAssertGreaterThanOrEqual(trailing.count, 7, "the trailing edge lost its notches")

        var peaks = 0
        for index in 1..<(trailing.count - 1) where
            trailing[index].y > trailing[index - 1].y && trailing[index].y > trailing[index + 1].y {
            peaks += 1
        }
        XCTAssertEqual(peaks, 3)
    }

    /// At 22 pt one design point is one physical pixel at 1x. A gap narrower than that merges
    /// into a solid blob, and the wing stops being a wing.
    func testFeatherGapsSurviveAtTwentyTwoPoints() {
        let trailing = WingGeometry.outline.compactMap { segment -> WingGeometry.Point? in
            if case .line(let point) = segment { return point }
            return nil
        }
        let liveWidth = 18.0     // points, on a 22 pt canvas
        for index in 1..<trailing.count {
            let gap = abs(trailing[index].x - trailing[index - 1].x) * liveWidth
            let between = "between \(trailing[index - 1]) and \(trailing[index])"
            XCTAssertGreaterThanOrEqual(gap, 1.0, "gap of \(gap) pt \(between)")
        }
    }
}
