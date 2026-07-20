import Foundation

struct Product: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    /// The owner's own product ID / SKU, distinct from the barcode.
    let productCode: String
    let type: String
    let barcode: String?
    let shelfLifeDays: Int?
    /// Denormalized sum of batch remainders, maintained transactionally.
    let totalStock: Int
    let createdAt: Date
    let lastReceivedAt: Date?
}
