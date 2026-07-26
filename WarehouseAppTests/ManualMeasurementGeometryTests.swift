import XCTest
@testable import WarehouseApp

final class ManualMeasurementGeometryTests: XCTestCase {
    func testRotatedRectangleProducesOrientationIndependentDimensions() throws {
        let angle = Float.pi / 6
        let cosine = cos(angle)
        let sine = sin(angle)
        let local: [SIMD2<Float>] = [
            [-0.2, -0.1], [0.2, -0.1], [0.2, 0.1], [-0.2, 0.1]
        ]
        let points = local.map {
            SIMD3<Float>($0.x * cosine - $0.y * sine, 0.7, $0.x * sine + $0.y * cosine)
        }
        let result = try ManualMeasurementGeometry.measureBoundary(points)
        XCTAssertEqual(result.footprint.lengthMetres, 0.4, accuracy: 0.000_01)
        XCTAssertEqual(result.footprint.widthMetres, 0.2, accuracy: 0.000_01)
        XCTAssertEqual(result.footprint.areaSquareMetres, 0.08, accuracy: 0.000_01)
    }

    func testTiltedBaseUsesPerpendicularHeight() throws {
        let points: [SIMD3<Float>] = [
            [0, 0, 0], [0.4, 0.04, 0], [0.4, 0.04, 0.3], [0, 0, 0.3]
        ]
        let boundary = try ManualMeasurementGeometry.measureBoundary(points)
        let base = SIMD3<Float>(0.2, 0.02, 0.15)
        let normal = SIMD3<Float>(boundary.plane.normal)
        let measured = try ManualMeasurementGeometry.height(
            top: base + normal * 0.5,
            bottom: base,
            boundary: boundary
        )
        XCTAssertEqual(measured, 0.5, accuracy: 0.000_01)
    }

    func testFiveCentimetreHeightIsAccepted() throws {
        let points: [SIMD3<Float>] = [
            [0, 0, 0], [0.08, 0, 0], [0.08, 0, 0.06], [0, 0, 0.06]
        ]
        let boundary = try ManualMeasurementGeometry.measureBoundary(points)
        let measured = try ManualMeasurementGeometry.height(
            top: [0.04, 0.05, 0.03],
            bottom: [0.04, 0, 0.03],
            boundary: boundary
        )
        XCTAssertEqual(measured, 0.05, accuracy: 0.000_01)
    }

    func testBoundaryIsNotRejectedByFormerFiveMetreLimit() throws {
        let points: [SIMD3<Float>] = [
            [0, 0, 0], [6, 0, 0], [6, 0, 0.1], [0, 0, 0.1]
        ]
        let boundary = try ManualMeasurementGeometry.measureBoundary(points)
        XCTAssertEqual(boundary.footprint.lengthMetres, 6, accuracy: 0.000_01)
    }

    func testRejectsSelfIntersectingBoundary() {
        let bowTie: [SIMD3<Float>] = [
            [0, 0, 0], [0.3, 0, 0.3], [0, 0, 0.3], [0.3, 0, 0]
        ]
        XCTAssertThrowsError(try ManualMeasurementGeometry.measureBoundary(bowTie)) {
            XCTAssertEqual($0 as? ManualMeasurementGeometryError, .selfIntersection)
        }
    }

    func testRejectsNonCoplanarBoundary() {
        let points: [SIMD3<Float>] = [
            [0, 0, 0], [0.4, 0, 0], [0.4, 0.1, 0.3], [0, 0, 0.3]
        ]
        XCTAssertThrowsError(try ManualMeasurementGeometry.measureBoundary(points))
    }

    func testConcavePolygonTriangulatesWithoutUsingAFanOutsideBoundary() {
        let polygon: [SIMD2<Double>] = [
            [0, 0], [2, 0], [2, 2], [1, 1], [0, 2]
        ]
        let indices = ManualMeasurementGeometry.triangulationIndices(for: polygon)
        XCTAssertEqual(indices.count, (polygon.count - 2) * 3)
        XCTAssertTrue(indices.allSatisfy { Int($0) < polygon.count })
    }
}
