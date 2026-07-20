import Foundation

/// One receiving day. The document ID is the local-date key ("2026-07-20"),
/// which gives exactly one shipment per day and makes "today's shipment" deterministic.
struct Shipment: Identifiable, Codable, Equatable {
    let id: String
    let createdAt: Date
    /// Denormalized total units received that day, maintained transactionally.
    let itemCount: Int
}
