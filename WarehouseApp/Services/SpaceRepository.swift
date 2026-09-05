import FirebaseFirestore
import Foundation

enum SpacePersistenceError: LocalizedError {
    case unapproved
    case staleVersion
    var errorDescription: String? {
        switch self {
        case .unapproved: "Only an approved Space Scan can be saved for automatic placement."
        case .staleVersion: "This space changed on another device. Reload it before saving."
        }
    }
}

enum SpaceRepository {
    static func fetch(id: UUID) async throws -> ScannedSpaceGeometry? {
        let snapshot = try await FirestoreCollections.spaces.document(id.uuidString).getDocument()
        return snapshot.exists ? try snapshot.data(as: ScannedSpaceGeometry.self) : nil
    }

    @discardableResult
    static func save(_ space: ScannedSpaceGeometry, expectedVersion: Int?) async throws -> ScannedSpaceGeometry {
        try SpaceGeometryValidator.validate(space)
        let reference = FirestoreCollections.spaces.document(space.id.uuidString)
        var saved = space
        _ = try await FirestoreCollections.db.runTransaction { transaction, pointer in
            do {
                let existing = try transaction.getDocument(reference)
                if existing.exists, let expectedVersion {
                    let current = try existing.data(as: ScannedSpaceGeometry.self)
                    guard current.geometryVersion == expectedVersion else {
                        throw SpacePersistenceError.staleVersion
                    }
                    try transaction.setData(from: current,
                        forDocument: reference.collection("geometryVersions")
                            .document(String(current.geometryVersion)))
                }
                var next = space
                next.geometryVersion = (expectedVersion ?? 0) + 1
                next.updatedAt = .now
                saved = next
                try transaction.setData(from: next, forDocument: reference)
            } catch { pointer?.pointee = error as NSError }
            return nil
        }
        return saved
    }
}
