import FirebaseFirestore
import UIKit

/// Product photos live as compressed JPEG thumbnails in Firestore
/// (`productPhotos/{productId}`), keeping the whole app on the free plan.
/// Kept out of the product document so list queries never download image bytes.
enum PhotoService {
    static let maxDimension: CGFloat = 800
    static let jpegQuality: CGFloat = 0.6

    private static let cache = NSCache<NSString, NSData>()

    static func thumbnailJpeg(from image: UIImage) -> Data? {
        let size = image.size
        let ratio = min(maxDimension / max(size.width, 1), maxDimension / max(size.height, 1), 1)
        let target = CGSize(width: size.width * ratio, height: size.height * ratio)
        let resized = UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: jpegQuality)
    }

    static func save(_ jpeg: Data, productId: String) async throws {
        try await FirestoreCollections.productPhotos.document(productId).setData(["jpeg": jpeg])
        cache.setObject(jpeg as NSData, forKey: productId as NSString)
    }

    static func load(productId: String) async throws -> Data? {
        if let cached = cache.object(forKey: productId as NSString) {
            return cached as Data
        }
        let doc = try await FirestoreCollections.productPhotos.document(productId).getDocument()
        guard let jpeg = doc.data()?["jpeg"] as? Data else { return nil }
        cache.setObject(jpeg as NSData, forKey: productId as NSString)
        return jpeg
    }
}
