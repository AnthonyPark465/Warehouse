import XCTest
@testable import WarehouseApp

final class InventorySortTests: XCTestCase {
    private let apples = Fixtures.product(
        id: "apples", name: "Apples", type: "Food",
        totalStock: 50, lastReceivedAt: Fixtures.date(2026, 7, 10)
    )
    private let bolts = Fixtures.product(
        id: "bolts", name: "bolts", type: "Hardware",
        totalStock: 200, lastReceivedAt: Fixtures.date(2026, 7, 1)
    )
    private let cables = Fixtures.product(
        id: "cables", name: "Cables", type: "Hardware",
        totalStock: 50, createdAt: Fixtures.date(2026, 7, 15), lastReceivedAt: nil
    )

    func testNewestFirstUsesLastReceivedFallingBackToCreated() {
        let sorted = InventorySort.newestFirst.sorted([apples, bolts, cables])
        XCTAssertEqual(sorted.map(\.id), ["cables", "apples", "bolts"])
    }

    func testStockHighFirstBreaksTiesByName() {
        let sorted = InventorySort.stockHighFirst.sorted([cables, apples, bolts])
        XCTAssertEqual(sorted.map(\.id), ["bolts", "apples", "cables"])
    }

    func testNameSortIsCaseInsensitive() {
        let sorted = InventorySort.name.sorted([cables, bolts, apples])
        XCTAssertEqual(sorted.map(\.id), ["apples", "bolts", "cables"])
    }

    func testGroupByTypeSortsGroupsAlphabetically() {
        let groups = InventoryGrouper.groupByType([bolts, apples, cables])
        XCTAssertEqual(groups.map(\.title), ["Food", "Hardware"])
        XCTAssertEqual(groups[1].products.map(\.id), [bolts.id, cables.id].sorted())
    }

    func testGroupByShipmentNewestDayFirstWithUniqueProducts() {
        let batches = [
            Fixtures.batch(id: "b1", productId: "apples", shipmentId: "2026-07-01"),
            Fixtures.batch(id: "b2", productId: "apples", shipmentId: "2026-07-10"),
            Fixtures.batch(id: "b3", productId: "bolts", shipmentId: "2026-07-10"),
            Fixtures.batch(id: "b4", productId: "bolts", shipmentId: "2026-07-10"),
        ]
        let groups = InventoryGrouper.groupByShipment([apples, bolts], batches: batches)
        XCTAssertEqual(groups.map(\.id), ["2026-07-10", "2026-07-01"])
        XCTAssertEqual(groups[0].products.map(\.id), ["apples", "bolts"])
        XCTAssertEqual(groups[1].products.map(\.id), ["apples"])
    }

    func testDateKeyFormat() {
        let key = DateKey.make(from: Fixtures.date(2026, 7, 5), calendar: Fixtures.calendar)
        XCTAssertEqual(key, "2026-07-05")
    }
}
