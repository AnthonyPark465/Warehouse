import CoreImage.CIFilterBuiltins
import UIKit

enum BarcodeRenderer {
    /// Renders a Code 128 barcode, scaled up without smoothing so bars stay crisp.
    static func code128Image(from value: String, scale: CGFloat = 4) -> UIImage? {
        guard let message = value.data(using: .ascii) else { return nil }

        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = message
        filter.quietSpace = 7

        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
