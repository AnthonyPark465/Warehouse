import FirebaseFirestore
import Foundation

/// Stock movements: receiving batches into a day's shipment and FIFO removals.
enum StockService {
    /// Records an arrival: creates a batch under the product, upserts today's
    /// shipment, and bumps the product's denormalized stock fields.
    static func receive(product: Product, quantity: Int, date: Date = .now) async throws {
        guard quantity > 0 else { throw FIFODeduction.DeductionError.invalidQuantity }

        let shipmentId = DateKey.make(from: date)
        let batchId = UUID().uuidString
        let batch = Batch(
            id: batchId,
            productId: product.id,
            quantity: quantity,
            remaining: quantity,
            receivedAt: date,
            expiryDate: InventoryMath.expiryDate(receivedAt: date, shelfLifeDays: product.shelfLifeDays),
            shipmentId: shipmentId
        )

        let writes = FirestoreCollections.db.batch()
        try writes.setData(
            from: batch,
            forDocument: FirestoreCollections.batches(productId: product.id).document(batchId)
        )
        writes.setData(
            ["id": shipmentId, "createdAt": Timestamp(date: date), "itemCount": FieldValue.increment(Int64(quantity))],
            forDocument: FirestoreCollections.shipments.document(shipmentId),
            merge: true
        )
        writes.updateData(
            [
                "totalStock": FieldValue.increment(Int64(quantity)),
                "lastReceivedAt": Timestamp(date: date),
            ],
            forDocument: FirestoreCollections.products.document(product.id)
        )
        try await writes.commit()
    }

    /// Removes stock FIFO across the product's batches.
    static func remove(product: Product, quantity: Int) async throws {
        let batches = try await ProductRepository.fetchBatches(productId: product.id)
        let draws = try FIFODeduction.plan(batches: batches, quantity: quantity)

        let writes = FirestoreCollections.db.batch()
        for draw in draws {
            writes.updateData(
                ["remaining": FieldValue.increment(Int64(-draw.quantity))],
                forDocument: FirestoreCollections.batches(productId: product.id).document(draw.batchId)
            )
        }
        writes.updateData(
            ["totalStock": FieldValue.increment(Int64(-quantity))],
            forDocument: FirestoreCollections.products.document(product.id)
        )
        try await writes.commit()
    }
}
