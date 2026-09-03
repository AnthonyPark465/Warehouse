import FirebaseFirestore
import Foundation

/// Stock movements: receiving batches into a day's shipment and FIFO removals.
enum StockService {
    enum StockError: LocalizedError {
        case batchMissing

        var errorDescription: String? {
            switch self {
            case .batchMissing: "That batch no longer exists."
            }
        }
    }

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

    /// Corrects a mis-received batch's original quantity. Consumed units stay
    /// consumed (see BatchCorrection); the product total and the day-shipment
    /// count move by the same delta, all in one transaction.
    static func correctBatch(productId: String, batchId: String, newQuantity: Int) async throws {
        let batchRef = FirestoreCollections.batches(productId: productId).document(batchId)
        _ = try await FirestoreCollections.db.runTransaction { transaction, errorPointer in
            do {
                let document = try transaction.getDocument(batchRef)
                guard document.exists else { throw StockError.batchMissing }
                let batch = try document.data(as: Batch.self)
                let outcome = try BatchCorrection.plan(
                    quantity: batch.quantity,
                    remaining: batch.remaining,
                    newQuantity: newQuantity
                )
                transaction.updateData(
                    ["quantity": newQuantity, "remaining": outcome.newRemaining],
                    forDocument: batchRef
                )
                transaction.updateData(
                    ["totalStock": FieldValue.increment(Int64(outcome.stockDelta))],
                    forDocument: FirestoreCollections.products.document(productId)
                )
                transaction.setData(
                    ["itemCount": FieldValue.increment(Int64(outcome.shipmentDelta))],
                    forDocument: FirestoreCollections.shipments.document(batch.shipmentId),
                    merge: true
                )
            } catch { errorPointer?.pointee = error as NSError }
            return nil
        }
    }

    /// Deletes a batch record entirely: its remaining units leave stock and
    /// the day's received count drops by the batch's full quantity.
    static func deleteBatch(productId: String, batchId: String) async throws {
        let batchRef = FirestoreCollections.batches(productId: productId).document(batchId)
        _ = try await FirestoreCollections.db.runTransaction { transaction, errorPointer in
            do {
                let document = try transaction.getDocument(batchRef)
                guard document.exists else { return nil } // already gone
                let batch = try document.data(as: Batch.self)
                transaction.deleteDocument(batchRef)
                transaction.updateData(
                    ["totalStock": FieldValue.increment(Int64(-batch.remaining))],
                    forDocument: FirestoreCollections.products.document(productId)
                )
                transaction.setData(
                    ["itemCount": FieldValue.increment(Int64(-batch.quantity))],
                    forDocument: FirestoreCollections.shipments.document(batch.shipmentId),
                    merge: true
                )
            } catch { errorPointer?.pointee = error as NSError }
            return nil
        }
    }

    /// Removes stock FIFO across the product's batches.
    ///
    /// Runs inside a Firestore transaction: `remaining` is re-read per batch
    /// before the plan is computed, so two concurrent removals cannot both
    /// deduct from the same stale snapshot and drive stock negative.
    static func remove(product: Product, quantity: Int) async throws {
        let batchIds = try await ProductRepository.fetchBatches(productId: product.id).map(\.id)
        _ = try await FirestoreCollections.db.runTransaction { transaction, errorPointer in
            do {
                var batches: [Batch] = []
                for batchId in batchIds {
                    let document = try transaction.getDocument(
                        FirestoreCollections.batches(productId: product.id).document(batchId)
                    )
                    guard document.exists else { continue }
                    batches.append(try document.data(as: Batch.self))
                }
                batches.sort { $0.receivedAt < $1.receivedAt }
                let draws = try FIFODeduction.plan(batches: batches, quantity: quantity)
                for draw in draws {
                    transaction.updateData(
                        ["remaining": FieldValue.increment(Int64(-draw.quantity))],
                        forDocument: FirestoreCollections.batches(productId: product.id).document(draw.batchId)
                    )
                }
                transaction.updateData(
                    ["totalStock": FieldValue.increment(Int64(-quantity))],
                    forDocument: FirestoreCollections.products.document(product.id)
                )
            } catch {
                errorPointer?.pointee = error as NSError
            }
            return nil
        }
    }
}
