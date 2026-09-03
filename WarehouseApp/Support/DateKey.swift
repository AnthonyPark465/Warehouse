import Foundation

/// Local-date keys like "2026-07-20", used as shipment document IDs.
/// Lexicographic order equals chronological order.
/// Uses the device's local calendar day on purpose: the app assumes a
/// single-site warehouse, so all devices share one timezone. Cross-timezone
/// teams would split a day's shipment into two documents.
enum DateKey {
    static func make(from date: Date = .now, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
