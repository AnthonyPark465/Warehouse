import FirebaseFirestore
import Foundation

/// What the Add Product form produces before persistence details are decided.
struct ProductDraft {
    let name: String
    let productCode: String
    let type: String
    let shelfLifeDays: Int?
    let photoJpeg: Data?
    let objectScan: ProductObjectScan?
    let placementMetadata: ProductPlacementMetadata?
}

/// How a new product gets its barcode, decided atomically with creation.
enum ProductBarcodeChoice {
    case none
    case generate
    case scanned(String)
}

enum ProductRepository {
    /// Creates the product document and reserves its barcode in ONE transaction,
    /// so a barcode failure (already in use, counter unavailable) leaves nothing
    /// behind — retrying Save can't orphan or duplicate products.
    /// The photo is written afterwards: it lives in its own document and a
    /// failed photo write must not fail (or duplicate) the product itself.
    static func create(_ draft: ProductDraft, barcode: ProductBarcodeChoice) async throws -> String {
        if case .scanned(let value) = barcode, !BarcodeValue.isValidExternal(value) {
            throw BarcodeError.invalidValue
        }

        let id = UUID().uuidString
        let productRef = FirestoreCollections.products.document(id)

        _ = try await FirestoreCollections.db.runTransaction { transaction, errorPointer in
            do {
                let barcodeValue: String?
                switch barcode {
                case .none:
                    barcodeValue = nil
                case .generate:
                    barcodeValue = try BarcodeService.reserveGenerated(in: transaction, for: id)
                case .scanned(let value):
                    try BarcodeService.reserve(value, in: transaction, for: id)
                    barcodeValue = value
                }
                let product = Product(
                    id: id,
                    name: draft.name,
                    productCode: draft.productCode,
                    type: draft.type,
                    barcode: barcodeValue,
                    shelfLifeDays: draft.shelfLifeDays,
                    totalStock: 0,
                    createdAt: .now,
                    lastReceivedAt: nil,
                    objectScan: draft.objectScan,
                    placementMetadata: draft.placementMetadata
                )
                try transaction.setData(from: product, forDocument: productRef)
            } catch {
                errorPointer?.pointee = error as NSError
            }
            return nil
        }

        if let jpeg = draft.photoJpeg {
            try await PhotoService.save(jpeg, productId: id)
        }
        return id
    }

    static func fetch(id: String) async throws -> Product? {
        let doc = try await FirestoreCollections.products.document(id).getDocument()
        guard doc.exists else { return nil }
        return try doc.data(as: Product.self)
    }

    static func fetchBatches(productId: String) async throws -> [Batch] {
        let snapshot = try await FirestoreCollections.batches(productId: productId)
            .order(by: "receivedAt")
            .getDocuments()
        return FirestoreDecoding.decode(snapshot.documents, as: Batch.self)
    }
}
