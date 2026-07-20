import SwiftUI

struct ReceiveView: View {
    @Environment(InventoryStore.self) private var store

    @State private var showsScanner = false
    @State private var receivingProduct: Product?
    @State private var unknownBarcode: UnknownBarcode?

    private var todayKey: String { DateKey.make() }

    private var todaysBatches: [Batch] {
        store.batches
            .filter { $0.shipmentId == todayKey }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showsScanner = true
                    } label: {
                        Label("Scan to Receive", systemImage: "barcode.viewfinder")
                    }
                    Menu {
                        ForEach(InventorySort.name.sorted(store.products)) { product in
                            Button(product.name) { receivingProduct = product }
                        }
                    } label: {
                        Label("Pick Product", systemImage: "shippingbox")
                    }
                    .disabled(store.products.isEmpty)
                }

                Section("Received Today (\(todaysBatches.reduce(0) { $0 + $1.quantity }) units)") {
                    if todaysBatches.isEmpty {
                        Text("Nothing received yet today.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(todaysBatches) { batch in
                            HStack {
                                Text(productName(for: batch))
                                Spacer()
                                Text("+\(batch.quantity)")
                                    .font(.body.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Receive")
            .sheet(isPresented: $showsScanner) {
                ScannerSheet(title: "Scan to Receive") { handleScan($0) }
            }
            .sheet(item: $receivingProduct) { product in
                ReceiveQuantitySheet(product: product)
            }
            .sheet(item: $unknownBarcode) { unknown in
                AddProductView(initialBarcode: unknown.value)
            }
        }
    }

    private func productName(for batch: Batch) -> String {
        store.products.first { $0.id == batch.productId }?.name ?? "Unknown product"
    }

    private func handleScan(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let product = store.products.first(where: { $0.barcode == trimmed }) {
            receivingProduct = product
        } else {
            unknownBarcode = UnknownBarcode(value: trimmed)
        }
    }
}

struct ReceiveQuantitySheet: View {
    let product: Product

    @Environment(\.dismiss) private var dismiss
    @State private var quantityText = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Receiving \(product.name)") {
                    TextField("Quantity", text: $quantityText)
                        .keyboardType(.numberPad)
                    if let shelfLifeDays = product.shelfLifeDays {
                        Text("Expiry will be set \(shelfLifeDays) days from today.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                        receive()
                    } label: {
                        if isWorking {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Add to Today's Shipment").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isWorking || (Int(quantityText) ?? 0) <= 0)
                }
            }
            .navigationTitle("Receive Stock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Couldn't Receive Stock", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func receive() {
        guard let quantity = Int(quantityText), quantity > 0 else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await StockService.receive(product: product, quantity: quantity)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
