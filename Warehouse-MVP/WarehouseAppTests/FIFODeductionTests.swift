import XCTest
@testable import WarehouseApp

final class FIFODeductionTests: XCTestCase {
    func testSingleBatchExactDraw() throws {
        let batches = [Fixtures.batch(id: "b1", quantity: 10)]
        let draws = try FIFODeduction.plan(batches: batches, quantity: 10)
        XCTAssertEqual(draws, [.init(batchId: "b1", quantity: 10)])
    }

    func testDrawsFromOldestBatchFirst() throws {
        let batches = [
            Fixtures.batch(id: "newer", quantity: 10, receivedAt: Fixtures.date(2026, 7, 10)),
            Fixtures.batch(id: "older", quantity: 10, receivedAt: Fixtures.date(2026, 7, 1)),
        ]
        let draws = try FIFODeduction.plan(batches: batches, quantity: 4)
        XCTAssertEqual(draws, [.init(batchId: "older", quantity: 4)])
    }

    func testDrawSpansMultipleBatches() throws {
        let batches = [
            Fixtures.batch(id: "b1", quantity: 5, receivedAt: Fixtures.date(2026, 7, 1)),
            Fixtures.batch(id: "b2", quantity: 5, receivedAt: Fixtures.date(2026, 7, 2)),
            Fixtures.batch(id: "b3", quantity: 5, receivedAt: Fixtures.date(2026, 7, 3)),
        ]
        let draws = try FIFODeduction.plan(batches: batches, quantity: 12)
        XCTAssertEqual(draws, [
            .init(batchId: "b1", quantity: 5),
            .init(batchId: "b2", quantity: 5),
            .init(batchId: "b3", quantity: 2),
        ])
    }

    func testSkipsEmptiedBatches() throws {
        let batches = [
            Fixtures.batch(id: "empty", quantity: 10, remaining: 0, receivedAt: Fixtures.date(2026, 7, 1)),
            Fixtures.batch(id: "live", quantity: 10, receivedAt: Fixtures.date(2026, 7, 2)),
        ]
        let draws = try FIFODeduction.plan(batches: batches, quantity: 3)
        XCTAssertEqual(draws, [.init(batchId: "live", quantity: 3)])
    }

    func testInsufficientStockThrowsWithAvailableCount() {
        let batches = [Fixtures.batch(id: "b1", quantity: 5, remaining: 3)]
        XCTAssertThrowsError(try FIFODeduction.plan(batches: batches, quantity: 4)) { error in
            XCTAssertEqual(
                error as? FIFODeduction.DeductionError,
                .insufficientStock(available: 3, requested: 4)
            )
        }
    }

    func testNonPositiveQuantityThrows() {
        let batches = [Fixtures.batch(id: "b1")]
        XCTAssertThrowsError(try FIFODeduction.plan(batches: batches, quantity: 0)) { error in
            XCTAssertEqual(error as? FIFODeduction.DeductionError, .invalidQuantity)
        }
    }
}
