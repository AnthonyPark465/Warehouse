import SwiftUI

struct ProductDetailView: View {
    let productId: String

    @Environment(InventoryStore.self) private var store

    @State private var batches: [Batch] = []
    @State private var showsRemoveSheet = false
    @State private var showsScanner = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var product: Product? {
        store.products.first { $0.id == productId }
    }

    var body: some View {
        Group {
            if let product {
                form(product)
            } else {
                ContentUnavailableView("Product Not Found", systemImage: "questionmark.square.dashed")
            }
        }
        .navigationTitle(product?.name ?? "Product")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reloadBatches() }
        .alert("Something Went Wrong", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func form(_ product: Product) -> some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    PhotoThumbnailView(productId: product.id, size: 140)
                    Spacer()
                }
            }

            Section("Details") {
                LabeledContent("Product ID", value: product.productCode)
                LabeledContent("Type", value: product.type)
                if let shelfLifeDays = product.shelfLifeDays {
                    LabeledContent("Shelf Life", value: "\(shelfLifeDays) days")
                }
                LabeledContent("Registered", value: product.createdAt.formatted(date: .abbreviated, time: .omitted))
            }

            dimensionsSection(product)

            barcodeSection(product)

            Section("Stock — \(product.totalStock) units") {
                if batches.filter({ $0.remaining > 0 }).isEmpty {
                    Text("No stock on hand.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(batches.filter { $0.remaining > 0 }) { batch in
                        BatchRowView(batch: batch)
                    }
                }
                Button("Remove Stock…", role: .destructive) {
                    showsRemoveSheet = true
                }
                .disabled(product.totalStock == 0)
            }
        }
        .sheet(isPresented: $showsRemoveSheet) {
            RemoveStockSheet(product: product) {
                await reloadBatches()
            }
        }
        .sheet(isPresented: $showsScanner) {
            ScannerSheet(title: "Assign Barcode") { value in
                assignBarcode(value, to: product)
            }
        }
    }

    @ViewBuilder
    private func dimensionsSection(_ product: Product) -> some View {
        Section("Dimensions") {
            if let scan = product.objectScan {
                LabeledContent(
                    "Length",
                    value: DimensionUnitConverter.formatted(
                        scan.finalLength,
                        unit: scan.displayUnit
                    )
                )
                LabeledContent(
                    "Width",
                    value: DimensionUnitConverter.formatted(
                        scan.finalWidth,
                        unit: scan.displayUnit
                    )
                )
                LabeledContent(
                    "Height",
                    value: DimensionUnitConverter.formatted(
                        scan.finalHeight,
                        unit: scan.displayUnit
                    )
                )
                LabeledContent(
                    "Can be rotated",
                    value: scan.canBeRotated ? "Yes" : "No"
                )
                Text(
                    scan.usesAdjustedDimensions == false
                        ? "Saved dimensions use the raw product measurement."
                        : "Saved dimensions include the configured scan tolerance."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("No product dimensions have been recorded.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func barcodeSection(_ product: Product) -> some View {
        Section("Barcode") {
            if let barcode = product.barcode {
                VStack(spacing: 8) {
                    if let image = BarcodeRenderer.code128Image(from: barcode) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 90)
                    }
                    Text(barcode)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            } else if isWorking {
                ProgressView()
            } else {
                Button("Generate Barcode") {
                    generateBarcode(for: product)
                }
                Button("Assign Scanned Barcode…") {
                    showsScanner = true
                }
            }
        }
    }

    private func generateBarcode(for product: Product) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await BarcodeService.generateAndAssign(to: product.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func assignBarcode(_ value: String, to product: Product) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await BarcodeService.assign(value, to: product.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reloadBatches() async {
        do {
            batches = try await ProductRepository.fetchBatches(productId: productId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct BatchRowView: View {
    let batch: Batch

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(batch.remaining) of \(batch.quantity) units")
                    .font(.subheadline.weight(.medium))
                Spacer()
                ExpiryBadge(status: ExpiryStatus.of(expiryDate: batch.expiryDate))
            }
            Text("Received \(batch.receivedAt.formatted(date: .abbreviated, time: .omitted)) · held \(InventoryMath.daysHeld(receivedAt: batch.receivedAt)) days")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct ExpiryBadge: View {
    let status: ExpiryStatus

    var body: some View {
        switch status {
        case .noExpiry:
            EmptyView()
        case .fresh(let daysLeft):
            badge("Expires in \(daysLeft)d", color: .green)
        case .expiringSoon(let daysLeft):
            badge(daysLeft == 0 ? "Expires today" : "Expires in \(daysLeft)d", color: .orange)
        case .expired(let daysAgo):
            badge("Expired \(daysAgo)d ago", color: .red)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct RemoveStockSheet: View {
    let product: Product
    let onDone: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var quantityText = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Remove from \(product.name) (\(product.totalStock) in stock)") {
                    TextField("Quantity", text: $quantityText)
                        .keyboardType(.numberPad)
                }
                Section {
                    Button(role: .destructive) {
                        remove()
                    } label: {
                        if isWorking {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Remove Stock").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isWorking || (Int(quantityText) ?? 0) <= 0)
                }
                Section {
                    Text("Oldest stock is removed first (FIFO).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Remove Stock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Couldn't Remove Stock", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func remove() {
        guard let quantity = Int(quantityText), quantity > 0 else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await StockService.remove(product: product, quantity: quantity)
                await onDone()
                dismiss()
            } catch {
                errorMessage = (error as? FIFODeduction.DeductionError).map {
                    switch $0 {
                    case .invalidQuantity: "Enter a quantity greater than zero."
                    case .insufficientStock(let available, let requested):
                        "Only \(available) units in stock — can't remove \(requested)."
                    }
                } ?? error.localizedDescription
            }
        }
    }
}
