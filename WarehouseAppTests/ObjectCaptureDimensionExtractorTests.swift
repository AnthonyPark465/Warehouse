import XCTest
@testable import WarehouseApp

final class ObjectCaptureDimensionExtractorTests: XCTestCase {
    func testUsesGravityAlignedYAsHeightAndNormalizesHorizontalAxes() {
        let dimensions = ObjectCaptureDimensionExtractor.dimensionsCM(
            extentsInMetres: SIMD3<Float>(0.06, 0.08, 0.061)
        )

        XCTAssertEqual(dimensions.length, 6.1, accuracy: 0.001)
        XCTAssertEqual(dimensions.width, 6.0, accuracy: 0.001)
        XCTAssertEqual(dimensions.height, 8.0, accuracy: 0.001)
    }

    func testAbsoluteExtentsProducePositiveDimensions() {
        let dimensions = ObjectCaptureDimensionExtractor.dimensionsCM(
            extentsInMetres: SIMD3<Float>(-0.12, -0.2, -0.08)
        )

        XCTAssertEqual(dimensions.length, 12, accuracy: 0.001)
        XCTAssertEqual(dimensions.width, 8, accuracy: 0.001)
        XCTAssertEqual(dimensions.height, 20, accuracy: 0.001)
    }
}
