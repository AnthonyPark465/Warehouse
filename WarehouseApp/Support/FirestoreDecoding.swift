import FirebaseFirestore
import os

/// Decodes snapshot documents, logging any that fail instead of letting
/// malformed records vanish indistinguishably from "no data".
enum FirestoreDecoding {
    private static let logger = Logger(
        subsystem: "com.tetris.warehouse",
        category: "FirestoreDecoding"
    )

    static func decode<T: Decodable>(
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
