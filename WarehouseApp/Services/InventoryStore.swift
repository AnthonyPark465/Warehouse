import FirebaseFirestore
import Foundation
import Observation
import os

/// Live view of the products collection via a Firestore snapshot listener.
@Observable
final class InventoryStore {
    private(set) var products: [Product] = []
    /// All batches across products (collection-group listener), used for
    /// shipment grouping and daily reports. Filtered client-side; volumes
    /// for a small business stay well within free-tier limits.
    private(set) var batches: [Batch] = []
    private(set) var isLoading = true
    private(set) var loadError: String?

    private var productListener: ListenerRegistration?
    private var batchListener: ListenerRegistration?
    private static let logger = Logger(
        subsystem: "com.tetris.warehouse",
        category: "InventoryStore"
    )

    // Listeners must be removed when the store is torn down (sign-out swaps
    // the tab shell out), otherwise they accumulate for the process lifetime.
    deinit {
        stop()
    }

    func start() {
        guard productListener == nil else { return }
        productListener = FirestoreCollections.products.addSnapshotListener { [weak self] snapshot, error in
            guard let self else { return }
            self.isLoading = false
            if let error {
                self.loadError = error.localizedDescription
                return
            }
            self.loadError = nil
            self.products = Self.decode(snapshot?.documents, as: Product.self)
        }
        batchListener = FirestoreCollections.db.collectionGroup("batches")
            .addSnapshotListener { [weak self] snapshot, _ in
                self?.batches = Self.decode(snapshot?.documents, as: Batch.self)
            }
    }

    func stop() {
        productListener?.remove()
        productListener = nil
        batchListener?.remove()
        batchListener = nil
    }

    /// Decodes snapshot documents, logging any that fail instead of letting
    /// malformed records vanish indistinguishably from "no data".
    private static func decode<T: Decodable>(
        _ documents: [QueryDocumentSnapshot]?,
        as type: T.Type
    ) -> [T] {
        (documents ?? []).compactMap { document in
            do {
                return try document.data(as: type)
            } catch {
                logger.error(
                    "Dropping undecodable \(String(describing: type), privacy: .public) \(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
    }
}
