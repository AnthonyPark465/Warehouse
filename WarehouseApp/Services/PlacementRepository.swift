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

    static func fetchShelves() async throws -> [ShelfState] {
        let snapshot = try await FirestoreCollections.shelves.getDocuments()
        return try snapshot.documents.map { try $0.data(as: ShelfState.self) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    static func fetchActiveReservation(shelfID: String, now: Date = .now) async throws -> PlacementReservation? {
        let document = try await FirestoreCollections.placementReservations.document(shelfID).getDocument()
        guard document.exists else { return nil }
        let reservation = try document.data(as: PlacementReservation.self)
        return reservation.expiresAt > now ? reservation : nil
    }

    /// Creates the canonical operational shelf record for a newly approved
    /// geometry. Re-saving a scan never replaces occupancy or obstacles.
    static func initializeOperationalShelf(from space: ScannedSpaceGeometry) async throws -> ShelfState {
        let proposed = try OpenSpacePlacementAdapter.shelfState(from: space)
        let reference = FirestoreCollections.shelves.document(proposed.id)
        var stored = proposed
        _ = try await FirestoreCollections.db.runTransaction { transaction, errorPointer in
            do {
                let document = try transaction.getDocument(reference)
                if document.exists {
                    stored = try document.data(as: ShelfState.self)
                    if let previous = stored.geometry {
                        try transaction.setData(
                            from: previous,
                            forDocument: reference.collection("geometryVersions")
                                .document(String(previous.version))
                        )
                    }
                    var nextGeometry = proposed.geometry
                    nextGeometry?.version = (stored.geometry?.version ?? 0) + 1
                    // Geometry is replaceable; operational facts are not. In
                    // particular, products and obstacles are preserved exactly.
                    stored.boundary = proposed.boundary
                    stored.coordinateSystem = proposed.coordinateSystem
                    stored.primaryFrontDirection = proposed.primaryFrontDirection
                    stored.secondaryAccessDirections = proposed.secondaryAccessDirections
                    stored.compartments = proposed.compartments.enumerated().map { index, proposedCompartment in
                        var compartment = proposedCompartment
                        compartment.ratedWeightKG = stored.compartments.indices.contains(index)
                            ? stored.compartments[index].ratedWeightKG : proposedCompartment.ratedWeightKG
                        return compartment
                    }
                    stored.scanQuality = proposed.scanQuality
                    stored.geometry = nextGeometry
                    stored.version += 1
                    stored.updatedAt = .now
                    let invalid = ShelfScanValidator.rejectionReasons(for: stored)
                    guard !invalid.contains(.staleShelfState) else {
                        // Do not delete or relocate occupancy when a new scan
                        // would place it outside the boundary; reject the scan.
                        throw PlacementPersistenceError.invalidPlacement
                    }
                    try transaction.setData(from: stored, forDocument: reference)
                } else {
                    try transaction.setData(from: proposed, forDocument: reference)
                }
            } catch { errorPointer?.pointee = error as NSError }
            return nil
        }
        return stored
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
            id: UUID().uuidString, shelfID: result.shelfID, productID: result.productID,
            shelfVersion: result.shelfVersion,
            volume: AxisAlignedVolume(id: result.id, minimum: result.position,
                                      dimensions: result.orientedDimensions),
            expiresAt: Date().addingTimeInterval(ttl), createdBy: userID
        )
        let shelfRef = FirestoreCollections.shelves.document(result.shelfID)
        // One document per shelf is the small-business MVP lock. It prevents
        // disjoint-looking candidates from racing against stale occupancy.
        let reservationRef = FirestoreCollections.placementReservations.document(result.shelfID)
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
                    guard existing.expiresAt <= Date() else {
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
        let reservationRef = FirestoreCollections.placementReservations.document(result.shelfID)
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
                guard currentReservation == reservation,
                      reservation.productID == result.productID,
                      reservation.volume.minimum == result.position,
                      reservation.volume.dimensions == result.orientedDimensions else {
                    throw PlacementPersistenceError.reservationConflict
                }
                do {
                    shelf = try ShelfStateOperations.confirming(result: result, package: package, in: shelf)
                } catch {
                    throw PlacementPersistenceError.invalidPlacement
                }
                try transaction.setData(from: shelf, forDocument: shelfRef)
                try transaction.setData(from: result, forDocument: placementRef)
                transaction.deleteDocument(reservationRef)
            } catch { errorPointer?.pointee = error as NSError }
            return nil
        }
    }

    static func cancel(_ reservation: PlacementReservation) async throws {
        let reference = FirestoreCollections.placementReservations.document(reservation.shelfID)
        _ = try await FirestoreCollections.db.runTransaction { transaction, errorPointer in
            do {
                let document = try transaction.getDocument(reference)
                guard document.exists else { return nil }
                let current = try document.data(as: PlacementReservation.self)
                guard current.id == reservation.id else {
                    throw PlacementPersistenceError.reservationConflict
                }
                transaction.deleteDocument(reference)
            } catch { errorPointer?.pointee = error as NSError }
            return nil
        }
    }

    static func removePlacement(id: String, shelfID: String, expectedShelfVersion: Int) async throws {
        let shelfRef = FirestoreCollections.shelves.document(shelfID)
        let placementRef = FirestoreCollections.placements.document(id)
        _ = try await FirestoreCollections.db.runTransaction { transaction, errorPointer in
            do {
                let document = try transaction.getDocument(shelfRef)
                guard document.exists else { throw PlacementPersistenceError.shelfMissing }
                var shelf = try document.data(as: ShelfState.self)
                guard shelf.version == expectedShelfVersion else {
                    throw PlacementPersistenceError.staleShelf(expected: expectedShelfVersion, actual: shelf.version)
                }
                do {
                    shelf = try ShelfStateOperations.removing(
                        id: id, from: shelf, expectedVersion: expectedShelfVersion
                    )
                } catch {
                    throw PlacementPersistenceError.invalidPlacement
                }
                try transaction.setData(from: shelf, forDocument: shelfRef)
                transaction.deleteDocument(placementRef)
            } catch { errorPointer?.pointee = error as NSError }
            return nil
        }
    }
}
