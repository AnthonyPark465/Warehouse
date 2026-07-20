import FirebaseFirestore
import Foundation
import Observation

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
            self.products = snapshot?.documents.compactMap { try? $0.data(as: Product.self) } ?? []
        }
        batchListener = FirestoreCollections.db.collectionGroup("batches")
            .addSnapshotListener { [weak self] snapshot, _ in
                self?.batches = snapshot?.documents.compactMap { try? $0.data(as: Batch.self) } ?? []
            }
    }

    func stop() {
        productListener?.remove()
        productListener = nil
        batchListener?.remove()
        batchListener = nil
    }
}
