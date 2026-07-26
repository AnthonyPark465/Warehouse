import XCTest
@testable import WarehouseApp

final class ObjectDimensionProcessingTests: XCTestCase {
    func testToleranceCombinesPercentageAndFixedAmount() {
        XCTAssertEqual(ObjectDimensionCalculator.tolerance(for: 120), 2.9, accuracy: 0.000_001)
    }

    func testToleranceMatchesDocumentedExample() {
        XCTAssertEqual(ObjectDimensionCalculator.tolerance(for: 40), 1.3, accuracy: 0.000_001)
    }

    func testRecordKeepsRawToleranceClearanceAndFinalValuesSeparate() {
        let capture = makeCapture(dimensions: .init(length: 120, width: 50, height: 10))
        let record = ObjectDimensionCalculator.makeRecord(
            capture: capture,
            displayUnit: .centimetres,
            canBeRotated: true
        )

        XCTAssertEqual(record.rawLength, 120)
        XCTAssertEqual(record.scanToleranceLength, 2.9, accuracy: 0.000_001)
        XCTAssertEqual(record.storageClearanceLength, 0)
        XCTAssertEqual(record.finalLength, 122.9, accuracy: 0.000_001)
        XCTAssertEqual(record.scanToleranceWidth, 1.5)
        XCTAssertEqual(record.finalWidth, 51.5)
        XCTAssertEqual(record.finalHeight, 10.7)
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

    func testUserCanKeepToleranceButSaveRawWarehouseDimensions() {
        let record = ObjectDimensionCalculator.makeRecord(
            capture: makeCapture(dimensions: .init(length: 40, width: 20, height: 10)),
            displayUnit: .centimetres,
            canBeRotated: false,
            useAdjustedDimensions: false
        )

        XCTAssertEqual(record.scanToleranceLength, 1.3, accuracy: 0.000_001)
        XCTAssertEqual(record.finalLength, 40)
        XCTAssertEqual(record.finalWidth, 20)
        XCTAssertEqual(record.finalHeight, 10)
        XCTAssertEqual(record.usesAdjustedDimensions, false)
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
