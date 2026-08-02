import XCTest
@testable import WarehouseApp

final class PlacementVerificationTests: XCTestCase {
    func testRequiresProductThenLocation() {
        var verification = PlacementVerification(
            expectedProductBarcode: "PRODUCT-1",
            expectedLocationBarcode: "LOCATION-1"
        )
        verification.accept("PRODUCT-1")
        XCTAssertEqual(verification.stage, .scanLocation)
        verification.accept("LOCATION-1")
        XCTAssertEqual(verification.stage, .complete)
    }

    func testWrongProductFails() {
        var verification = PlacementVerification(
            expectedProductBarcode: "PRODUCT-1",
            expectedLocationBarcode: "LOCATION-1"
        )
        verification.accept("OTHER")
        XCTAssertEqual(
            verification.stage,
            .failed(message: "Wrong product. Scan PRODUCT-1.")
        )
    }

    func testWrongLocationFails() {
        var verification = PlacementVerification(
            expectedProductBarcode: "PRODUCT-1",
            expectedLocationBarcode: "LOCATION-1"
        )
        verification.accept("PRODUCT-1")
        verification.accept("LOCATION-2")
        XCTAssertEqual(
            verification.stage,
            .failed(message: "Wrong location. Scan LOCATION-1.")
        )
    }
}

final class ARPlacementVerifierTests: XCTestCase {
    func testPlacementWithinToleranceVerifies() {
        let result = ARPlacementVerifier.verify(
            expectedPosition: Vector3D(10, 20, 30), expectedQuarterTurns: 1,
            actualPosition: Vector3D(12, 20, 31), actualYawDegrees: 87,
            trackingAvailable: true
        )
        guard case .verified = result else { return XCTFail("Expected verified, got \(result)") }
    }

    func testPlacementOutsideToleranceReturnsActionableCorrection() {
        let result = ARPlacementVerifier.verify(
            expectedPosition: Vector3D(10, 20, 30), expectedQuarterTurns: 1,
            actualPosition: Vector3D(4, 20, 25), actualYawDegrees: 60,
            trackingAvailable: true
        )
        guard case .correction(let message, _, _) = result else {
            return XCTFail("Expected correction, got \(result)")
        }
        XCTAssertTrue(message.contains("Move"))
        XCTAssertTrue(message.contains("rotate"))
    }

    func testUnavailableTrackingDoesNotClaimVerification() {
        let result = ARPlacementVerifier.verify(
            expectedPosition: Vector3D(0, 0, 0), expectedQuarterTurns: 0,
            actualPosition: nil, actualYawDegrees: nil, trackingAvailable: false
        )
        guard case .unavailable = result else { return XCTFail("Expected unavailable") }
    }
}
