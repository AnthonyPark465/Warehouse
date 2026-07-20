import Foundation

/// Plans how a stock removal is spread across batches, oldest arrival first.
enum FIFODeduction {
    struct Draw: Equatable {
        let batchId: String
        let quantity: Int
    }

    enum DeductionError: Error, Equatable {
        case invalidQuantity
        case insufficientStock(available: Int, requested: Int)
    }

    static func plan(batches: [Batch], quantity: Int) throws -> [Draw] {
        guard quantity > 0 else { throw DeductionError.invalidQuantity }

        let available = batches.reduce(0) { $0 + $1.remaining }
        guard available >= quantity else {
            throw DeductionError.insufficientStock(available: available, requested: quantity)
        }

        var left = quantity
        var draws: [Draw] = []
        for batch in batches.sorted(by: { $0.receivedAt < $1.receivedAt }) where batch.remaining > 0 {
            let take = min(batch.remaining, left)
            draws.append(Draw(batchId: batch.id, quantity: take))
            left -= take
            if left == 0 { break }
        }
        return draws
    }
}
