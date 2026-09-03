import SwiftUI

/// Fixes a mis-received batch (e.g. 500 entered instead of 50). The corrected
/// quantity flows through remaining stock, the product total, and reports.
struct CorrectBatchSheet: View {
    let product: Product
    let batch: Batch
    let onDone: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var quantityText: String
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(product: Product, batch: Batch, onDone: @escaping () async -> Void) {
        self.product = product
        self.batch = batch
        self.onDone = onDone
        _quantityText = State(initialValue: String(batch.quantity))
    }

    private var consumed: Int { batch.quantity - batch.remaining }

    var body: some View {
        NavigationStack {
            Form {
                Section("Batch received \(batch.receivedAt.formatted(date: .abbreviated, time: .omitted))") {
                    LabeledContent("Recorded quantity", value: "\(batch.quantity)")
                    LabeledContent("Still in stock", value: "\(batch.remaining)")
                    if consumed > 0 {
                        LabeledContent("Already removed", value: "\(consumed)")
                    }
                    TextField("Corrected quantity", text: $quantityText)
                        .keyboardType(.numberPad)
                }
                Section {
                    Button {
                        correct()
                    } label: {
                        if isWorking {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Correct Quantity").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isWorking || Int(quantityText) == nil || Int(quantityText) == batch.quantity)
                }
            }
            .navigationTitle("Correct Batch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Couldn't Correct Batch", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func correct() {
        guard let newQuantity = Int(quantityText) else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await StockService.correctBatch(
                    productId: product.id,
                    batchId: batch.id,
                    newQuantity: newQuantity
                )
                await onDone()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
