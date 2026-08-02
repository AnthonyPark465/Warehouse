import FirebaseFirestore
import Foundation

enum PlacementPersistenceError: LocalizedError {
    case shelfMissing
    case staleShelf(expected: Int, actual: Int)
    case reservationConflict
    case reservationExpired
    case invalidPlacement

    var errorDescription: String? {
        switch self {
        case .shelfMissing: "The shelf no longer exists."
        case .staleShelf(let expected, let actual): "Shelf state changed from version \(expected) to \(actual). Recalculate placement."
        case .reservationConflict: "Another worker reserved this location. Recalculate placement."
        case .reservationExpired: "The location reservation expired. Recalculate placement."
        case .invalidPlacement: "The placement is invalid or incomplete."
        }
    }
}

/// Owns shelf-state persistence. Reserve and confirm both re-read the shelf
/// version in Firestore transactions so concurrent devices cannot commit the
/// same candidate from stale geometry.
enum PlacementRepository {
    static func saveShelf(_ shelf: ShelfState) async throws {
        try FirestoreCollections.shelves.document(shelf.id).setData(from: shelf)
    }

    static func fetchShelf(id: String) async throws -> ShelfState? {
        let document = try await FirestoreCollections.shelves.document(id).getDocument()
        return document.exists ? try document.data(as: ShelfState.self) : nil
    }

    /// Atomically installs an explicitly approved geometry version. Existing
    /// products are revalidated; they are never relocated automatically. The
    /// previous geometry remains available in the shelf's geometryVersions
    /// subcollection and all recommendations become stale via `shelf.version`.
    static func saveApprovedGeometry(
        _ geometry: ShelfGeometryRecord,
        shelfID: String,
        expectedShelfVersion: Int
    ) async throws {
        guard geometry.isApproved else {
            throw PlacementPersistenceError.invalidPlacement
        }
        let shelfRef = FirestoreCollections.shelves.document(shelfID)
        _ = try await FirestoreCollections.db.runTransaction { transaction, errorPointer in
            do {
                let document = try transaction.getDocument(shelfRef)
                guard document.exists else { throw PlacementPersistenceError.shelfMissing }
                var shelf = try document.data(as: ShelfState.self)
                guard shelf.version == expectedShelfVersion else {
                    throw PlacementPersistenceError.staleShelf(
                        expected: expectedShelfVersion,
                        actual: shelf.version
                    )
                }
                if let previous = shelf.geometry {
                    let history = shelfRef.collection("geometryVersions")
                        .document(String(previous.version))
                    try transaction.setData(from: previous, forDocument: history)
                }
                var next = geometry
                next.version = (shelf.geometry?.version ?? 0) + 1
                shelf.geometry = next
                shelf.version += 1
                shelf.updatedAt = .now
                let invalid = ShelfScanValidator.rejectionReasons(for: shelf)
                guard !invalid.contains(.staleShelfState) else {
                    throw PlacementPersistenceError.invalidPlacement
                }
                try transaction.setData(from: shelf, forDocument: shelfRef)
            } catch {
                errorPointer?.pointee = error as NSError
            }
            return nil
        }
    }

    static func reserve(
        result: ProductPlacementResult,
        userID: String,
        ttl: TimeInterval = 120
    ) async throws -> PlacementReservation {
        let reservation = PlacementReservation(
            id: result.id, shelfID: result.shelfID, productID: result.productID,
            shelfVersion: result.shelfVersion,
            volume: AxisAlignedVolume(id: result.id, minimum: result.position,
                                      dimensions: result.orientedDimensions),
            expiresAt: Date().addingTimeInterval(ttl), createdBy: userID
        )
        let shelfRef = FirestoreCollections.shelves.document(result.shelfID)
        let reservationRef = FirestoreCollections.placementReservations.document(result.id)
        _ = try await FirestoreCollections.db.runTransaction { transaction, errorPointer in
            do {
                let shelfDoc = try transaction.getDocument(shelfRef)
                guard shelfDoc.exists else { throw PlacementPersistenceError.shelfMissing }
                let shelf = try shelfDoc.data(as: ShelfState.self)
                guard shelf.version == result.shelfVersion else {
                    throw PlacementPersistenceError.staleShelf(expected: result.shelfVersion, actual: shelf.version)
                }
                let oldReservation = try transaction.getDocument(reservationRef)
                if oldReservation.exists {
                    let existing = try oldReservation.data(as: PlacementReservation.self)
                    guard existing.expiresAt <= Date() || existing.createdBy == userID else {
                        throw PlacementPersistenceError.reservationConflict
                    }
                }
                try transaction.setData(from: reservation, forDocument: reservationRef)
            } catch { errorPointer?.pointee = error as NSError }
            return nil
        }
        return reservation
    }

    static func confirm(
        reservation: PlacementReservation,
        result: ProductPlacementResult,
        package: PackagePlacementProfile
    ) async throws {
        let shelfRef = FirestoreCollections.shelves.document(result.shelfID)
        let reservationRef = FirestoreCollections.placementReservations.document(reservation.id)
        let placementRef = FirestoreCollections.placements.document(result.id)
        _ = try await FirestoreCollections.db.runTransaction { transaction, errorPointer in
            do {
                let shelfDoc = try transaction.getDocument(shelfRef)
                guard shelfDoc.exists else { throw PlacementPersistenceError.shelfMissing }
                var shelf = try shelfDoc.data(as: ShelfState.self)
                guard shelf.version == result.shelfVersion else {
                    throw PlacementPersistenceError.staleShelf(expected: result.shelfVersion, actual: shelf.version)
                }
                let reservationDoc = try transaction.getDocument(reservationRef)
                guard reservationDoc.exists else { throw PlacementPersistenceError.reservationConflict }
                let currentReservation = try reservationDoc.data(as: PlacementReservation.self)
                guard currentReservation.expiresAt > Date() else { throw PlacementPersistenceError.reservationExpired }

                let occupied = StoredProductPlacement(
                    id: result.id, productID: package.productId, productType: package.productType,
                    compartmentID: result.compartmentID,
                    volume: AxisAlignedVolume(id: result.id, minimum: result.position,
                                              dimensions: result.orientedDimensions),
                    weightKG: package.metadata.weightKG,
                    priority: package.metadata.retrievalPriority,
                    retrievalFrequency: package.metadata.expectedRetrievalFrequency,
                    stacking: package.metadata.stacking,
                    supportingProductIDs: result.supportingProductIDs,
                    blockedProductIDs: result.blockedProductIDs
                )
                shelf.products.append(occupied)
                shelf.version += 1
                shelf.updatedAt = .now
                try transaction.setData(from: shelf, forDocument: shelfRef)
                try transaction.setData(from: result, forDocument: placementRef)
                transaction.deleteDocument(reservationRef)
            } catch { errorPointer?.pointee = error as NSError }
            return nil
        }
    }

    static func cancel(_ reservation: PlacementReservation) async throws {
        try await FirestoreCollections.placementReservations.document(reservation.id).delete()
    }
}
