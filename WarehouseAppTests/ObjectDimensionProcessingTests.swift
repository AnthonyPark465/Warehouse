import XCTest
@testable import WarehouseApp

final class ObjectDimensionProcessingTests: XCTestCase {
    func testToleranceUsesTwoPercentWhenLargerThanMinimum() {
        XCTAssertEqual(ObjectDimensionCalculator.tolerance(for: 120), 2.4, accuracy: 0.000_001)
    }

    func testToleranceUsesTwoCentimetreMinimum() {
        XCTAssertEqual(ObjectDimensionCalculator.tolerance(for: 50), 2, accuracy: 0.000_001)
    }

    func testRecordKeepsRawToleranceClearanceAndFinalValuesSeparate() {
        let capture = makeCapture(dimensions: .init(length: 120, width: 50, height: 10))
        let record = ObjectDimensionCalculator.makeRecord(
            capture: capture,
            displayUnit: .centimetres,
            canBeRotated: true
        )

        XCTAssertEqual(record.rawLength, 120)
        XCTAssertEqual(record.scanToleranceLength, 2.4, accuracy: 0.000_001)
        XCTAssertEqual(record.storageClearanceLength, 1)
        XCTAssertEqual(record.finalLength, 123.4, accuracy: 0.000_001)
        XCTAssertEqual(record.scanToleranceWidth, 2)
        XCTAssertEqual(record.finalWidth, 53)
        XCTAssertEqual(record.finalHeight, 13)
        XCTAssertTrue(record.canBeRotated)
        XCTAssertEqual(record.internalUnit, "cm")
    }

    func testChangingDisplayUnitDoesNotChangeStoredDimensions() {
        let capture = makeCapture(dimensions: .init(length: 120.346, width: 50, height: 10))
        let centimetres = ObjectDimensionCalculator.makeRecord(
            capture: capture,
            displayUnit: .centimetres,
            canBeRotated: false
        )
        let metres = ObjectDimensionCalculator.makeRecord(
            capture: capture,
            displayUnit: .metres,
            canBeRotated: false
        )

        XCTAssertEqual(centimetres.rawLength, metres.rawLength)
        XCTAssertEqual(centimetres.finalLength, metres.finalLength)
        XCTAssertEqual(DimensionUnitConverter.displayValue(120.346, unit: .metres), 1.20346)
    }

    func testValidationRejectsLowConfidenceAndIncompleteScans() {
        let dimensions = ObjectDimensions(length: 30, width: 20, height: 10)
        XCTAssertNotNil(ObjectScanValidation.message(
            dimensions: dimensions,
            confidence: 0.4,
            pointCount: 1_000
        ))
        XCTAssertNotNil(ObjectScanValidation.message(
            dimensions: .init(length: 30, width: 20, height: 0),
            confidence: 0.9,
            pointCount: 1_000
        ))
    }

    func testValidScanPassesValidation() {
        XCTAssertNil(ObjectScanValidation.message(
            dimensions: .init(length: 30, width: 20, height: 10),
            confidence: 0.9,
            pointCount: 1_000
        ))
    }

    private func makeCapture(dimensions: ObjectDimensions) -> ObjectScanCapture {
        ObjectScanCapture(
            id: UUID(),
            rawDimensionsCM: dimensions,
            pointsInMetres: [],
            scanMethod: .lidar,
            deviceModel: "TestDevice",
            hasLiDAR: true,
            confidence: 0.9,
            timestamp: Fixtures.date(2026, 7, 25)
        )
    }
}
