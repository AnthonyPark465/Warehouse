import SwiftUI

struct ProductRow: View {
    let product: Product

    var body: some View {
        HStack(spacing: 12) {
            PhotoThumbnailView(productId: product.id)
            VStack(alignment: .leading, spacing: 2) {
                Text(product.name)
                    .font(.body.weight(.medium))
                Text("\(product.type) · \(product.productCode)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(product.totalStock)")
                    .font(.body.monospacedDigit().weight(.semibold))
                Text("in stock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PhotoThumbnailView: View {
    let productId: String
    var size: CGFloat = 44

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: productId) {
            if let data = try? await PhotoService.load(productId: productId) {
                image = UIImage(data: data)
            }
        }
    }
}
