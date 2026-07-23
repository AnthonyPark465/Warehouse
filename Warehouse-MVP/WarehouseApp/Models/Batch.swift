import Foundation

/// One arrival of stock for a product. Stock is deducted FIFO across batches,
/// so `remaining` shrinks while `quantity` keeps the original arrival size.
struct Batch: Identifiable, Codable, Equatable {
    let id: String
    let productId: String
    let quantity: Int
    let remaining: Int
    let receivedAt: Date
    let expiryDate: Date?
    /// The day's shipment this batch arrived in (a local-date key, e.g. "2026-07-20").
    let shipmentId: String
}
