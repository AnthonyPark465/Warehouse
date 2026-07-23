import Foundation

enum InventoryMath {
    /// Whole calendar days from `from` to `to` (negative if `to` is earlier).
    static func daysBetween(_ from: Date, _ to: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    static func daysHeld(receivedAt: Date, now: Date = .now, calendar: Calendar = .current) -> Int {
        daysBetween(receivedAt, now, calendar: calendar)
    }

    static func expiryDate(receivedAt: Date, shelfLifeDays: Int?, calendar: Calendar = .current) -> Date? {
        guard let shelfLifeDays else { return nil }
        return calendar.date(byAdding: .day, value: shelfLifeDays, to: receivedAt)
    }
}

enum ExpiryStatus: Equatable {
    case noExpiry
    case fresh(daysLeft: Int)
    case expiringSoon(daysLeft: Int)
    case expired(daysAgo: Int)

    static let soonThresholdDays = 7

    static func of(expiryDate: Date?, now: Date = .now, calendar: Calendar = .current) -> ExpiryStatus {
        guard let expiryDate else { return .noExpiry }
        let daysLeft = InventoryMath.daysBetween(now, expiryDate, calendar: calendar)
        if daysLeft < 0 { return .expired(daysAgo: -daysLeft) }
        if daysLeft <= soonThresholdDays { return .expiringSoon(daysLeft: daysLeft) }
        return .fresh(daysLeft: daysLeft)
    }
}
