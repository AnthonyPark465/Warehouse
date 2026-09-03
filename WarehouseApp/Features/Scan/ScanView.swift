import SwiftUI

/// A barcode that isn't registered yet; drives the "register this?" flow.
struct UnknownBarcode: Identifiable {
    let value: String
    var id: String { value }
}

struct ScanView: View {
    @Environment(InventoryStore.self) private var store

    @State private var foundProduct: Product?
    @State private var unknownBarcode: UnknownBarcode?
    @State private var manualValue = ""

    var body: some View {
        NavigationStack {
            Group {
                if BarcodeScannerView.isSupported {
                    ZStack(alignment: .bottom) {
                        BarcodeScannerView { handleScan($0) }
                            .ignoresSafeArea(edges: .bottom)
                        if let foundProduct {
                            ScanResultCard(product: foundProduct, batches: store.batches) {
                                self.foundProduct = nil
                            }
                            .padding()
                        }
                    }
                } else {
                    simulatorFallback
                }
            }
            .navigationTitle("Scan")
            .navigationDestination(for: String.self) { productId in
                ProductDetailView(productId: productId)
            }
            .sheet(item: $unknownBarcode) { unknown in
                AddProductView(initialBarcode: unknown.value)
            }
        }
    }

    private var simulatorFallback: some View {
        Form {
            Section("Camera unavailable — enter a barcode to look up") {
                TextField("Barcode value", text: $manualValue)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Look Up") { handleScan(manualValue) }
                    .disabled(manualValue.isEmpty)
            }
            if let foundProduct {
                Section("Result") {
                    ScanResultCard(product: foundProduct, batches: store.batches) {
                        self.foundProduct = nil
                    }
                    .listRowInsets(EdgeInsets())
                }
            }
        }
    }

    private func handleScan(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The live scanner keeps running behind the registration sheet;
        // swapping the sheet's item while presented breaks the presentation.
        guard unknownBarcode == nil else { return }
        if let product = store.products.first(where: { $0.barcode == trimmed }) {
            foundProduct = product
        } else {
            foundProduct = nil
            unknownBarcode = UnknownBarcode(value: trimmed)
        }
    }
}

/// What a scan tells you: identity, stock, how long it's been held, expiry.
struct ScanResultCard: View {
    let product: Product
    let batches: [Batch]
    let onDismiss: () -> Void

    private var productBatches: [Batch] {
        batches.filter { $0.productId == product.id && $0.remaining > 0 }
    }

    private var oldestHeldDays: Int? {
        productBatches.map(\.receivedAt).min().map { InventoryMath.daysHeld(receivedAt: $0) }
    }

    private var soonestExpiry: ExpiryStatus {
        let dates = productBatches.compactMap(\.expiryDate)
        return ExpiryStatus.of(expiryDate: dates.min())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                PhotoThumbnailView(productId: product.id, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.name)
                        .font(.headline)
                    Text("\(product.type) · \(product.productCode)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss")
            }

            HStack(spacing: 16) {
                stat("In stock", "\(product.totalStock)")
                if let oldestHeldDays {
                    stat("Held", "\(oldestHeldDays)d")
                }
                if let shelfLifeDays = product.shelfLifeDays {
                    stat("Shelf life", "\(shelfLifeDays)d")
                }
                Spacer()
                ExpiryBadge(status: soonestExpiry)
            }

            NavigationLink("View Details", value: product.id)
                .font(.subheadline.weight(.medium))
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
