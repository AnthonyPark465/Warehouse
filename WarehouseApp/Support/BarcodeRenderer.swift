import CoreImage.CIFilterBuiltins
import UIKit

enum BarcodeRenderer {
    /// Renders a Code 128 barcode, scaled up without smoothing so bars stay crisp.
    static func code128Image(from value: String, scale: CGFloat = 4) -> UIImage? {
        let key = "\(scale)|\(value)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let message = value.data(using: .ascii) else { return nil }

        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = message
        filter.quietSpace = 7

        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key)
        return image
    }

    // Views call this while rendering. Creating a Core Image context is
    // costly, and the same barcode is asked for on every redraw.
    private static let context = CIContext()
    private static let cache = NSCache<NSString, UIImage>()
}
