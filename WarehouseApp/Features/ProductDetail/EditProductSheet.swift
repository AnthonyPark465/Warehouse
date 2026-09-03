import PhotosUI
import SwiftUI

/// Edits a product's basic fields and photo. Barcode changes have their own
/// flow in the detail view; stock is corrected per batch.
struct EditProductSheet: View {
    let product: Product
    let onSaved: (_ photoChanged: Bool) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var productCode: String
    @State private var type: String
    @State private var shelfLifeText: String
    @State private var photo: UIImage?
    @State private var pickedItem: PhotosPickerItem?
    @State private var showsCamera = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(product: Product, onSaved: @escaping (_ photoChanged: Bool) async -> Void) {
        self.product = product
        self.onSaved = onSaved
        _name = State(initialValue: product.name)
        _productCode = State(initialValue: product.productCode)
        _type = State(initialValue: product.type)
        _shelfLifeText = State(initialValue: product.shelfLifeDays.map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    HStack(spacing: 16) {
                        Group {
                            if let photo {
                                Image(uiImage: photo)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            } else {
                                PhotoThumbnailView(productId: product.id, size: 72)
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            PhotosPicker("Choose Photo", selection: $pickedItem, matching: .images)
                            if CameraPicker.isAvailable {
                                Button("Take Photo") { showsCamera = true }
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Section("Details") {
                    TextField("Name", text: $name)
                    TextField("Product ID / SKU", text: $productCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Type (e.g. Food, Hardware)", text: $type)
                    TextField("Shelf life in days (optional)", text: $shelfLifeText)
                        .keyboardType(.numberPad)
                }

                Section {
                    Text("A changed shelf life applies to stock received from now on; existing batches keep their expiry dates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(!isValid)
                    }
                }
            }
            .sheet(isPresented: $showsCamera) {
                CameraPicker { photo = $0 }
            }
            .onChange(of: pickedItem) {
                Task { @MainActor in
                    if let data = try? await pickedItem?.loadTransferable(type: Data.self) {
                        photo = UIImage(data: data)
                    }
                }
            }
            .alert("Couldn't Save", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var isValid: Bool {
        let shelfLifeOk = shelfLifeText.isEmpty || (Int(shelfLifeText).map { $0 > 0 } ?? false)
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !productCode.trimmingCharacters(in: .whitespaces).isEmpty
            && !type.trimmingCharacters(in: .whitespaces).isEmpty
            && shelfLifeOk
    }

    private func save() {
        isSaving = true
        Task { @MainActor in
            do {
                try await ProductRepository.update(
                    id: product.id,
                    edits: .init(
                        name: name.trimmingCharacters(in: .whitespaces),
                        productCode: productCode.trimmingCharacters(in: .whitespaces),
                        type: type.trimmingCharacters(in: .whitespaces),
                        shelfLifeDays: shelfLifeText.isEmpty ? nil : Int(shelfLifeText)
                    )
                )
                var photoChanged = false
                if let photo, let jpeg = PhotoService.thumbnailJpeg(from: photo) {
                    try await PhotoService.save(jpeg, productId: product.id)
                    photoChanged = true
                }
                await onSaved(photoChanged)
                dismiss()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
