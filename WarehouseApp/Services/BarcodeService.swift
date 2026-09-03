import FirebaseFirestore
import Foundation

enum BarcodeError: LocalizedError, Equatable {
    case alreadyInUse
    case invalidValue
    case notFound

    var errorDescription: String? {
        switch self {
        case .alreadyInUse: "That barcode is already assigned to another product."
        case .invalidValue: "That barcode can't be stored. Use letters, digits, and . _ ~ : @ + - (no slashes), up to 100 characters."
        case .notFound: "No product is registered with that barcode."
        }
    }
}

/// Owns the barcode registry (`barcodes/{value}` -> productId) and the generation counter.
/// The registry document ID *is* the barcode value; every reservation checks
/// create-if-absent inside a transaction, so duplicates are impossible even across devices.
enum BarcodeService {
    private static let counterDocId = "barcodeCounter"

    /// Reserves the next generated value ("WH…") inside `transaction` and returns it.
    /// The counter read must not fail silently: a swallowed read error would restart
    /// numbering at 1 and hand an existing product's barcode to a new one.
    static func reserveGenerated(in transaction: Transaction, for productId: String) throws -> String {
        let counterRef = FirestoreCollections.meta.document(counterDocId)
        let counterDoc = try transaction.getDocument(counterRef)
        let next = (counterDoc.data()?["next"] as? Int) ?? 1
        let value = BarcodeValue.generated(counter: next)

        let registryRef = FirestoreCollections.barcodes.document(value)
        if try transaction.getDocument(registryRef).exists {
            // Counter and registry disagree (e.g. manual data edits); never overwrite.
            throw BarcodeError.alreadyInUse
        }
        transaction.setData(["next": next + 1], forDocument: counterRef)
        transaction.setData(["productId": productId], forDocument: registryRef)
        return value
    }

    /// Reserves an externally scanned/typed value inside `transaction`.
    static func reserve(_ value: String, in transaction: Transaction, for productId: String) throws {
        guard BarcodeValue.isValidExternal(value) else { throw BarcodeError.invalidValue }
        let registryRef = FirestoreCollections.barcodes.document(value)
        if try transaction.getDocument(registryRef).exists {
            throw BarcodeError.alreadyInUse
        }
        transaction.setData(["productId": productId], forDocument: registryRef)
    }

    /// Atomically reserves the next generated value and assigns it to an existing product.
    static func generateAndAssign(to productId: String) async throws -> String {
        let productRef = FirestoreCollections.products.document(productId)
        let value = try await FirestoreCollections.db.runTransaction { transaction, errorPointer in
            do {
                let value = try reserveGenerated(in: transaction, for: productId)
                transaction.updateData(["barcode": value], forDocument: productRef)
                return value
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        }
        guard let value = value as? String else { throw BarcodeError.notFound }
        return value
    }

    /// Atomically reserves an externally scanned barcode for an existing product.
    /// Throws `.alreadyInUse` if any product already holds it.
    static func assign(_ value: String, to productId: String) async throws {
        let productRef = FirestoreCollections.products.document(productId)
        _ = try await FirestoreCollections.db.runTransaction { transaction, errorPointer in
            do {
                try reserve(value, in: transaction, for: productId)
                transaction.updateData(["barcode": value], forDocument: productRef)
            } catch {
                errorPointer?.pointee = error as NSError
            }
            return nil
        }
    }

    /// Atomically swaps a product's barcode: reserves the new value and frees
    /// the old registry entry in one transaction. Use `clear(for:)` to remove
    /// a barcode without assigning a new one.
    static func replace(for product: Product, with choice: ProductBarcodeChoice) async throws -> String {
        if case .scanned(let value) = choice, !BarcodeValue.isValidExternal(value) {
            throw BarcodeError.invalidValue
        }
        let productRef = FirestoreCollections.products.document(product.id)
        let counterRef = FirestoreCollections.meta.document(counterDocId)
        let oldBarcode = product.barcode

        let result = try await FirestoreCollections.db.runTransaction { transaction, errorPointer -> Any? in
            do {
                // Transactions require every read to precede the first write,
                // so the old entry's delete happens after the availability reads.
                let newValue: String
                var counterBump: Int?
                switch choice {
                case .none:
                    throw BarcodeError.invalidValue
                case .generate:
                    let counterDoc = try transaction.getDocument(counterRef)
                    let next = (counterDoc.data()?["next"] as? Int) ?? 1
                    newValue = BarcodeValue.generated(counter: next)
                    counterBump = next + 1
                    if try transaction.getDocument(FirestoreCollections.barcodes.document(newValue)).exists {
                        throw BarcodeError.alreadyInUse
                    }
                case .scanned(let value):
                    newValue = value
                    if value != oldBarcode,
                       try transaction.getDocument(FirestoreCollections.barcodes.document(value)).exists {
                        throw BarcodeError.alreadyInUse
                    }
                }

                if let oldBarcode, oldBarcode != newValue {
                    transaction.deleteDocument(FirestoreCollections.barcodes.document(oldBarcode))
                }
                if let counterBump {
                    transaction.setData(["next": counterBump], forDocument: counterRef)
                }
                transaction.setData(
                    ["productId": product.id],
                    forDocument: FirestoreCollections.barcodes.document(newValue)
                )
                transaction.updateData(["barcode": newValue], forDocument: productRef)
                return newValue
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        }
        guard let newValue = result as? String else { throw BarcodeError.notFound }
        return newValue
    }

    /// Removes a product's barcode and frees its registry entry for reuse.
    static func clear(for product: Product) async throws {
        guard let oldBarcode = product.barcode else { return }
        let writes = FirestoreCollections.db.batch()
        writes.deleteDocument(FirestoreCollections.barcodes.document(oldBarcode))
        writes.updateData(
            ["barcode": FieldValue.delete()],
            forDocument: FirestoreCollections.products.document(product.id)
        )
        try await writes.commit()
    }

    static func lookupProductId(barcode: String) async throws -> String? {
        let doc = try await FirestoreCollections.barcodes.document(barcode).getDocument()
        return doc.data()?["productId"] as? String
    }
}
