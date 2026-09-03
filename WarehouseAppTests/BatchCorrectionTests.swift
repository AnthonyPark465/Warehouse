import XCTest
@testable import WarehouseApp

final class BatchCorrectionTests: XCTestCase {
    func testIncreasingQuantityRaisesRemainingAndStock() throws {
        let outcome = try BatchCorrection.plan(quantity: 50, remaining: 50, newQuantity: 80)
        XCTAssertEqual(outcome, .init(newRemaining: 80, stockDelta: 30, shipmentDelta: 30))
    }

    func testDecreasingQuantityLowersRemainingAndStock() throws {
        let outcome = try BatchCorrection.plan(quantity: 500, remaining: 500, newQuantity: 50)
        XCTAssertEqual(outcome, .init(newRemaining: 50, stockDelta: -450, shipmentDelta: -450))
    }

    func testConsumedUnitsStayConsumed() throws {
        // Received 50, 20 already removed (remaining 30), corrected to 40:
        // the 20 consumed stay consumed, so 20 remain.
        let outcome = try BatchCorrection.plan(quantity: 50, remaining: 30, newQuantity: 40)
        XCTAssertEqual(outcome, .init(newRemaining: 20, stockDelta: -10, shipmentDelta: -10))
    }

    func testCorrectionBelowConsumedThrows() {
        XCTAssertThrowsError(try BatchCorrection.plan(quantity: 50, remaining: 10, newQuantity: 30)) { error in
            XCTAssertEqual(error as? BatchCorrection.CorrectionError, .belowConsumed(consumed: 40))
        }
    }

    func testExactlyConsumedIsAllowed() throws {
        let outcome = try BatchCorrection.plan(quantity: 50, remaining: 10, newQuantity: 40)
        XCTAssertEqual(outcome.newRemaining, 0)
    }

    func testNonPositiveQuantityThrows() {
        XCTAssertThrowsError(try BatchCorrection.plan(quantity: 10, remaining: 10, newQuantity: 0)) { error in
            XCTAssertEqual(error as? BatchCorrection.CorrectionError, .invalidQuantity)
        }
    }
}
