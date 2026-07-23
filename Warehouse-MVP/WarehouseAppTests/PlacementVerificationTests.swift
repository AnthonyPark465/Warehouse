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

