import SwiftUI

struct ProductDetailView: View {
    let productId: String

    @Environment(InventoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var batches: [Batch] = []
    @State private var showsRemoveSheet = false
    @State private var showsScanner = false
    @State private var showsReplaceScanner = false
    @State private var showsEditSheet = false
    @State private var showsDeleteConfirm = false
    @State private var batchToCorrect: Batch?
    @State private var batchToDelete: Batch?
    @State private var photoVersion = 0
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
                        .id(photoVersion)
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

            stockSection(product)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showsEditSheet = true
                    } label: {
                        Label("Edit Product", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showsDeleteConfirm = true
                    } label: {
                        Label("Delete Product", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Product Actions")
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
        .sheet(isPresented: $showsReplaceScanner) {
            ScannerSheet(title: "Replace Barcode") { value in
                replaceBarcode(.scanned(value), for: product)
            }
        }
        .sheet(isPresented: $showsEditSheet) {
            EditProductSheet(product: product) { photoChanged in
                if photoChanged { photoVersion += 1 }
            }
        }
        .sheet(item: $batchToCorrect) { batch in
            CorrectBatchSheet(product: product, batch: batch) {
                await reloadBatches()
            }
        }
        .confirmationDialog(
            "Delete this batch?",
            isPresented: .init(
                get: { batchToDelete != nil },
                set: { if !$0 { batchToDelete = nil } }
            ),
            presenting: batchToDelete
        ) { batch in
            Button("Delete Batch", role: .destructive) {
                deleteBatch(batch)
            }
        } message: { batch in
            Text("\(batch.remaining) units leave stock and the \(batch.shipmentId) report drops by \(batch.quantity). This can't be undone.")
        }
        .confirmationDialog(
            "Delete \(product.name)?",
            isPresented: $showsDeleteConfirm
        ) {
            Button("Delete Product and All Stock", role: .destructive) {
                deleteProduct(product)
            }
        } message: {
            Text("Deletes the product, its \(product.totalStock) units of stock, its photo, and frees its barcode for reuse. This can't be undone.")
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

                if isWorking {
                    ProgressView()
                } else {
                    Menu("Change Barcode…") {
                        Button("Replace with Generated") {
                            replaceBarcode(.generate, for: product)
                        }
                        Button("Replace with Scanned…") {
                            showsReplaceScanner = true
                        }
                        Button("Remove Barcode", role: .destructive) {
                            clearBarcode(for: product)
                        }
                    }
                }
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

    private func stockSection(_ product: Product) -> some View {
        Section("Stock — \(product.totalStock) units") {
            if batches.isEmpty {
                Text("No stock received yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(batches) { batch in
                    BatchRowView(batch: batch)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                batchToDelete = batch
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                batchToCorrect = batch
                            } label: {
                                Label("Correct", systemImage: "pencil")
                            }
                        }
                }
            }
            Button("Remove Stock…", role: .destructive) {
                showsRemoveSheet = true
            }
            .disabled(product.totalStock == 0)
        }
    }

    private func generateBarcode(for product: Product) {
        isWorking = true
        Task { @MainActor in
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
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await BarcodeService.assign(value, to: product.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func replaceBarcode(_ choice: ProductBarcodeChoice, for product: Product) {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                _ = try await BarcodeService.replace(for: product, with: choice)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func clearBarcode(for product: Product) {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await BarcodeService.clear(for: product)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteBatch(_ batch: Batch) {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await StockService.deleteBatch(productId: productId, batchId: batch.id)
                await reloadBatches()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteProduct(_ product: Product) {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await ProductRepository.delete(product)
                dismiss()
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
        Task { @MainActor in
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
