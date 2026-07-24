import Foundation
@testable import WarehouseApp

enum Fixtures {
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: year, month: month, day: day, hour: hour
        ))!
    }

    static func product(
        id: String = "p1",
        name: String = "Widget",
        type: String = "General",
        totalStock: Int = 0,
        createdAt: Date = Fixtures.date(2026, 1, 1),
        lastReceivedAt: Date? = nil
    ) -> Product {
        Product(
            id: id, name: name, productCode: "SKU-\(id)", type: type,
            barcode: nil, shelfLifeDays: nil, totalStock: totalStock,
            createdAt: createdAt, lastReceivedAt: lastReceivedAt,
            objectScan: nil
        )
    }

    static func batch(
        id: String,
        productId: String = "p1",
        quantity: Int = 10,
        remaining: Int? = nil,
        receivedAt: Date = Fixtures.date(2026, 7, 1),
        shipmentId: String = "2026-07-01"
    ) -> Batch {
        Batch(
            id: id, productId: productId, quantity: quantity,
            remaining: remaining ?? quantity, receivedAt: receivedAt,
            expiryDate: nil, shipmentId: shipmentId
        )
    }
}
