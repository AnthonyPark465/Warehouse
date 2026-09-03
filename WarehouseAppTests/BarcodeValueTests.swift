import XCTest
@testable import WarehouseApp

final class BarcodeValueTests: XCTestCase {
    func testGeneratedValueIsZeroPadded() {
        XCTAssertEqual(BarcodeValue.generated(counter: 42), "WH0000000042")
    }

    func testGeneratedValueLargeCounter() {
        XCTAssertEqual(BarcodeValue.generated(counter: 9_876_543_210), "WH9876543210")
    }

    func testRoundTripIsRecognized() {
        XCTAssertTrue(BarcodeValue.isGenerated(BarcodeValue.generated(counter: 1)))
    }

    func testExternalValidationAcceptsCommonBarcodes() {
        XCTAssertTrue(BarcodeValue.isValidExternal("4006381333931"))      // EAN-13
        XCTAssertTrue(BarcodeValue.isValidExternal("WH0000000042"))
        XCTAssertTrue(BarcodeValue.isValidExternal("ABC-123_x.y:z@w+q~"))
    }

    func testExternalValidationRejectsFirestoreUnsafeValues() {
        XCTAssertFalse(BarcodeValue.isValidExternal(""))
        XCTAssertFalse(BarcodeValue.isValidExternal("AB/CD"))             // "/" breaks doc paths
        XCTAssertFalse(BarcodeValue.isValidExternal("."))
        XCTAssertFalse(BarcodeValue.isValidExternal(".."))
        XCTAssertFalse(BarcodeValue.isValidExternal("has space"))
        XCTAssertFalse(BarcodeValue.isValidExternal(String(repeating: "9", count: 101)))
    }

    func testForeignBarcodesAreNotRecognized() {
        XCTAssertFalse(BarcodeValue.isGenerated("4006381333931"))   // EAN-13
        XCTAssertFalse(BarcodeValue.isGenerated("WH123"))           // too short
        XCTAssertFalse(BarcodeValue.isGenerated("WH00000000AB"))    // non-numeric
        XCTAssertFalse(BarcodeValue.isGenerated(""))
    }
}
