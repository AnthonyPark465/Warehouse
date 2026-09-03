import XCTest
import simd
@testable import WarehouseApp

final class ShelfClearanceEstimationTests: XCTestCase {
    // MARK: - estimate(hitHeightsM:)

    func testUniformCeilingAtFortyCentimetresMeasuresForty() {
        // Arrange
        let hits: [Float?] = Array(repeating: 0.40, count: 16)

        // Act
        let estimate = ShelfClearanceEstimator.estimate(hitHeightsM: hits)

        // Assert
        XCTAssertNotNil(estimate)
        XCTAssertEqual(estimate?.freeHeightCM ?? 0, 40, accuracy: 0.5)
        XCTAssertEqual(estimate?.hitFraction ?? 0, 1, accuracy: 0.001)
    }

    func testLowestObstructionGovernsClearance() {
        // Arrange: open ceiling at 60 cm but a crossbar at 35 cm over half the shelf
        let hits: [Float?] = Array(repeating: 0.60, count: 8) + Array(repeating: 0.35, count: 8)

        // Act
        let estimate = ShelfClearanceEstimator.estimate(hitHeightsM: hits)

        // Assert
        XCTAssertEqual(estimate?.freeHeightCM ?? 0, 35, accuracy: 0.5)
    }

    func testOpenTopReturnsNilWhenTooFewRaysHit() {
        // Arrange: only 2 of 16 rays find anything above
        let hits: [Float?] = [0.5, 0.5] + Array(repeating: nil, count: 14)

        // Act
        let estimate = ShelfClearanceEstimator.estimate(hitHeightsM: hits)

        // Assert
        XCTAssertNil(estimate)
    }

    func testNoiseBelowMinimumClearanceIsIgnored() {
        // Arrange: one hit inside the 5 cm contact-noise band, rest at 40 cm
        let hits: [Float?] = [0.01] + Array(repeating: 0.40, count: 15)

        // Act
        let estimate = ShelfClearanceEstimator.estimate(hitHeightsM: hits)

        // Assert
        XCTAssertEqual(estimate?.freeHeightCM ?? 0, 40, accuracy: 0.5)
    }

    func testEmptyAndAllMissInputsReturnNil() {
        // Act / Assert
        XCTAssertNil(ShelfClearanceEstimator.estimate(hitHeightsM: []))
        XCTAssertNil(ShelfClearanceEstimator.estimate(hitHeightsM: Array(repeating: nil, count: 16)))
    }

    // MARK: - samplePoints(insidePolygon:)

    func testSamplePointsLieInsideInsetRectangle() {
        // Arrange: 60 × 40 cm rectangle in plane-local metres
        let rectangle: [SIMD2<Float>] = [
            SIMD2(-0.30, -0.20), SIMD2(0.30, -0.20),
            SIMD2(0.30, 0.20), SIMD2(-0.30, 0.20)
        ]
        let inset = ShelfClearanceConfiguration.shelf.footprintInsetM

        // Act
        let points = ShelfClearanceEstimator.samplePoints(insidePolygon: rectangle)

        // Assert
        XCTAssertFalse(points.isEmpty)
        for point in points {
            XCTAssertLessThanOrEqual(abs(point.x), 0.30 - inset + 0.0001)
            XCTAssertLessThanOrEqual(abs(point.y), 0.20 - inset + 0.0001)
        }
    }

    func testSamplePointsLieInsideTriangle() {
        // Arrange
        let triangle: [SIMD2<Float>] = [
            SIMD2(-0.25, -0.15), SIMD2(0.25, -0.15), SIMD2(0, 0.25)
        ]

        // Act
        let points = ShelfClearanceEstimator.samplePoints(insidePolygon: triangle)

        // Assert
        XCTAssertFalse(points.isEmpty)
        for point in points {
            XCTAssertTrue(
                ShelfClearanceEstimator.contains(polygon: triangle, point: point),
                "Sample \(point) fell outside the triangle"
            )
        }
    }

    func testDegeneratePolygonsProduceNoSamples() {
        // Arrange
        let twoPoints: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0.3, 0)]
        let zeroArea: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0.3, 0), SIMD2(0.6, 0)]

        // Act / Assert
        XCTAssertTrue(ShelfClearanceEstimator.samplePoints(insidePolygon: []).isEmpty)
        XCTAssertTrue(ShelfClearanceEstimator.samplePoints(insidePolygon: twoPoints).isEmpty)
        XCTAssertTrue(ShelfClearanceEstimator.samplePoints(insidePolygon: zeroArea).isEmpty)
    }
}
