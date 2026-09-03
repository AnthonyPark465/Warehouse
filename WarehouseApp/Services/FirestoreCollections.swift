import FirebaseFirestore

/// Single source of truth for collection paths.
enum FirestoreCollections {
    static var db: Firestore { Firestore.firestore() }

    static var products: CollectionReference { db.collection("products") }
    static var productPhotos: CollectionReference { db.collection("productPhotos") }
    static var shipments: CollectionReference { db.collection("shipments") }
    static var barcodes: CollectionReference { db.collection("barcodes") }
    static var meta: CollectionReference { db.collection("meta") }
    static var shelves: CollectionReference { db.collection("shelves") }
    static var spaces: CollectionReference { db.collection("spaces") }
    static var placements: CollectionReference { db.collection("placements") }
    static var placementReservations: CollectionReference { db.collection("placementReservations") }

    static func batches(productId: String) -> CollectionReference {
        products.document(productId).collection("batches")
    }
}
