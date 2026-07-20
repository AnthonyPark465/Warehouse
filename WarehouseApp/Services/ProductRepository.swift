import FirebaseFirestore
import Foundation

/// What the Add Product form produces before persistence details are decided.
struct ProductDraft {
    let name: String
    let productCode: String
    let type: String
    let shelfLifeDays: Int?
    let photoJpeg: Data?
}

enum ProductRepository {
    /// Creates the product document (and its photo, if provided) and returns the new product ID.
    /// Barcode assignment happens separately via BarcodeService so its transaction
    /// stays the single owner of registry writes.
    static func create(_ draft: ProductDraft) async throws -> String {
        let id = UUID().uuidString
        let product = Product(
            id: id,
            name: draft.name,
            productCode: draft.productCode,
            type: draft.type,
            barcode: nil,
            shelfLifeDays: draft.shelfLifeDays,
            totalStock: 0,
            createdAt: .now,
            lastReceivedAt: nil
        )
        try FirestoreCollections.products.document(id).setData(from: product)
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
        return snapshot.documents.compactMap { try? $0.data(as: Batch.self) }
    }
}
