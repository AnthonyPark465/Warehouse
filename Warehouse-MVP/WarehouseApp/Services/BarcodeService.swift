import FirebaseFirestore
import Foundation

enum BarcodeError: LocalizedError, Equatable {
    case alreadyInUse
    case notFound

    var errorDescription: String? {
        switch self {
        case .alreadyInUse: "That barcode is already assigned to another product."
        case .notFound: "No product is registered with that barcode."
        }
    }
}

/// Owns the barcode registry (`barcodes/{value}` -> productId) and the generation counter.
/// The registry document ID *is* the barcode value, so create-if-absent semantics
/// inside a transaction make duplicates impossible, even across devices.
enum BarcodeService {
    private static let counterDocId = "barcodeCounter"

    /// Atomically reserves the next generated value ("WH…") and assigns it to the product.
    static func generateAndAssign(to productId: String) async throws -> String {
        let counterRef = FirestoreCollections.meta.document(counterDocId)
        let productRef = FirestoreCollections.products.document(productId)

        let value = try await FirestoreCollections.db.runTransaction { transaction, _ in
            let counterDoc = try? transaction.getDocument(counterRef)
            let next = (counterDoc?.data()?["next"] as? Int) ?? 1
            let value = BarcodeValue.generated(counter: next)

            transaction.setData(["next": next + 1], forDocument: counterRef)
            transaction.setData(
                ["productId": productId],
                forDocument: FirestoreCollections.barcodes.document(value)
            )
            transaction.updateData(["barcode": value], forDocument: productRef)
            return value
        }
        guard let value = value as? String else { throw BarcodeError.notFound }
        return value
    }

    /// Atomically reserves an externally scanned barcode for the product.
    /// Throws `.alreadyInUse` if any product already holds it.
    static func assign(_ value: String, to productId: String) async throws {
        let barcodeRef = FirestoreCollections.barcodes.document(value)
        let productRef = FirestoreCollections.products.document(productId)

        _ = try await FirestoreCollections.db.runTransaction { transaction, errorPointer in
            do {
                let existing = try transaction.getDocument(barcodeRef)
                if existing.exists {
                    errorPointer?.pointee = NSError(
                        domain: "BarcodeService", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: BarcodeError.alreadyInUse.errorDescription ?? ""]
                    )
                    return nil
                }
                transaction.setData(["productId": productId], forDocument: barcodeRef)
                transaction.updateData(["barcode": value], forDocument: productRef)
            } catch {
                errorPointer?.pointee = error as NSError
            }
            return nil
        }
    }

    static func lookupProductId(barcode: String) async throws -> String? {
        let doc = try await FirestoreCollections.barcodes.document(barcode).getDocument()
        return doc.data()?["productId"] as? String
    }
}
