import XCTest
@testable import WarehouseApp

final class InventoryMathTests: XCTestCase {
    private let cal = Fixtures.calendar

    func testDaysBetweenSameDayIsZero() {
        let days = InventoryMath.daysBetween(
            Fixtures.date(2026, 7, 20, hour: 1),
            Fixtures.date(2026, 7, 20, hour: 23),
            calendar: cal
        )
        XCTAssertEqual(days, 0)
    }

    func testDaysBetweenCountsCalendarDaysNotFullDays() {
        // 11pm to 1am next day is 2 hours but crosses one calendar day boundary
        let days = InventoryMath.daysBetween(
            Fixtures.date(2026, 7, 19, hour: 23),
            Fixtures.date(2026, 7, 20, hour: 1),
            calendar: cal
        )
        XCTAssertEqual(days, 1)
    }

    func testDaysHeldAcrossMonths() {
        let days = InventoryMath.daysHeld(
            receivedAt: Fixtures.date(2026, 6, 20),
            now: Fixtures.date(2026, 7, 20),
            calendar: cal
        )
        XCTAssertEqual(days, 30)
    }

    func testExpiryDateAddsShelfLife() {
        let expiry = InventoryMath.expiryDate(
            receivedAt: Fixtures.date(2026, 7, 20),
            shelfLifeDays: 14,
            calendar: cal
        )
        XCTAssertEqual(expiry, Fixtures.date(2026, 8, 3))
    }

    func testExpiryDateNilWithoutShelfLife() {
        XCTAssertNil(InventoryMath.expiryDate(receivedAt: .now, shelfLifeDays: nil, calendar: cal))
    }

    func testExpiryStatusNoExpiry() {
        XCTAssertEqual(ExpiryStatus.of(expiryDate: nil, calendar: cal), .noExpiry)
    }

    func testExpiryStatusExpiredYesterday() {
        let status = ExpiryStatus.of(
            expiryDate: Fixtures.date(2026, 7, 19),
            now: Fixtures.date(2026, 7, 20),
            calendar: cal
        )
        XCTAssertEqual(status, .expired(daysAgo: 1))
    }

    func testExpiryStatusExpiringToday() {
        let status = ExpiryStatus.of(
            expiryDate: Fixtures.date(2026, 7, 20, hour: 8),
            now: Fixtures.date(2026, 7, 20, hour: 15),
            calendar: cal
        )
        XCTAssertEqual(status, .expiringSoon(daysLeft: 0))
    }

    func testExpiryStatusThresholdBoundary() {
        let atThreshold = ExpiryStatus.of(
            expiryDate: Fixtures.date(2026, 7, 27),
            now: Fixtures.date(2026, 7, 20),
            calendar: cal
        )
        XCTAssertEqual(atThreshold, .expiringSoon(daysLeft: 7))

        let pastThreshold = ExpiryStatus.of(
            expiryDate: Fixtures.date(2026, 7, 28),
            now: Fixtures.date(2026, 7, 20),
            calendar: cal
        )
        XCTAssertEqual(pastThreshold, .fresh(daysLeft: 8))
    }
}
