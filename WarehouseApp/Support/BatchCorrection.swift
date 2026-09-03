import Foundation

/// Pure math for correcting a mis-received batch's original quantity.
/// `remaining` moves by the same delta as `quantity`, so already-consumed
/// units stay consumed; a correction below what's been consumed is invalid.
enum BatchCorrection {
    struct Outcome: Equatable {
        let newRemaining: Int
        /// Applied to the product's denormalized totalStock.
        let stockDelta: Int
        /// Applied to the day-shipment's itemCount (tracks received quantity).
        let shipmentDelta: Int
    }

    enum CorrectionError: LocalizedError, Equatable {
        case invalidQuantity
        case belowConsumed(consumed: Int)

        var errorDescription: String? {
            switch self {
            case .invalidQuantity:
                "Enter a quantity greater than zero."
            case .belowConsumed(let consumed):
                "\(consumed) units from this batch were already removed — the corrected quantity can't be lower than that."
            }
        }
    }

    static func plan(quantity: Int, remaining: Int, newQuantity: Int) throws -> Outcome {
        guard newQuantity > 0 else { throw CorrectionError.invalidQuantity }
        let delta = newQuantity - quantity
        let newRemaining = remaining + delta
        guard newRemaining >= 0 else {
            throw CorrectionError.belowConsumed(consumed: quantity - remaining)
        }
        return Outcome(
            newRemaining: newRemaining,
            stockDelta: newRemaining - remaining,
            shipmentDelta: delta
        )
    }
}
