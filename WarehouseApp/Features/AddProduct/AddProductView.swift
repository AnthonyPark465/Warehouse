import PhotosUI
import SwiftUI

struct AddProductView: View {
    @Environment(\.dismiss) private var dismiss

    private enum BarcodeMode: String, CaseIterable, Identifiable {
        case none = "None"
        case generate = "Generate"
        case scanned = "Scan / Enter"
        var id: String { rawValue }
    }

    @State private var name = ""
    @State private var productCode = ""
    @State private var type = ""
    @State private var shelfLifeText = ""
    @State private var photo: UIImage?
    @State private var pickedItem: PhotosPickerItem?
    @State private var showsCamera = false
    @State private var barcodeMode: BarcodeMode
    @State private var scannedBarcode: String
    @State private var showsScanner = false
    @State private var showsObjectScanner = false
    @State private var objectScanCapture: ObjectScanCapture?
    @State private var displayUnit: DimensionDisplayUnit = .centimetres
    @State private var canBeRotated = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    /// Pass a barcode (e.g. from the Scan tab) to pre-fill registration.
    init(initialBarcode: String? = nil) {
        _barcodeMode = State(initialValue: initialBarcode == nil ? .none : .scanned)
        _scannedBarcode = State(initialValue: initialBarcode ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                photoSection
                detailsSection
                objectScanSection
                barcodeSection
            }
            .navigationTitle("New Product")
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
            .sheet(isPresented: $showsScanner) {
                ScannerSheet(title: "Scan Barcode") { scannedBarcode = $0 }
            }
            .fullScreenCover(isPresented: $showsObjectScanner) {
                ObjectScanCaptureView { capture in
                    objectScanCapture = capture
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

    @ViewBuilder
    private var objectScanSection: some View {
        if let objectScanCapture {
            ObjectScanSummaryView(
                capture: objectScanCapture,
                displayUnit: $displayUnit,
                canBeRotated: $canBeRotated,
                onRescan: { showsObjectScanner = true }
            )
        } else {
            Section("Storage Dimensions") {
                Button {
                    showsObjectScanner = true
                } label: {
                    Label("Start Object Scan", systemImage: "arkit")
                }
                Text("Choose multi-frame LiDAR Fusion or Apple Object Capture, then review the measured storage bounding box.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !ObjectScannerCapabilities.hasLiDAR {
                    Label(
                        "This device will use standard ARKit without LiDAR. Measurements may be less reliable.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private var photoSection: some View {
        Section("Photo") {
            HStack(spacing: 16) {
                Group {
                    if let photo {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(.secondarySystemBackground))
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 8) {
                    PhotosPicker("Choose Photo", selection: $pickedItem, matching: .images)
                    if CameraPicker.isAvailable {
                        Button("Take Photo") { showsCamera = true }
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .onChange(of: pickedItem) {
            Task {
                if let data = try? await pickedItem?.loadTransferable(type: Data.self) {
                    photo = UIImage(data: data)
                }
            }
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            TextField("Name", text: $name)
            TextField("Product ID / SKU", text: $productCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            TextField("Type (e.g. Food, Hardware)", text: $type)
            TextField("Shelf life in days (optional)", text: $shelfLifeText)
                .keyboardType(.numberPad)
        }
    }

    private var barcodeSection: some View {
        Section("Barcode") {
            Picker("Barcode", selection: $barcodeMode) {
                ForEach(BarcodeMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if barcodeMode == .scanned {
                HStack {
                    TextField("Barcode value", text: $scannedBarcode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button {
                        showsScanner = true
                    } label: {
                        Image(systemName: "barcode.viewfinder")
                    }
                    .accessibilityLabel("Scan Barcode")
                }
            } else if barcodeMode == .generate {
                Text("A unique Code 128 barcode will be created for this product.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isValid: Bool {
        let shelfLifeOk = shelfLifeText.isEmpty || (Int(shelfLifeText).map { $0 > 0 } ?? false)
        let barcodeOk = barcodeMode != .scanned || !trimmedBarcode.isEmpty
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !productCode.trimmingCharacters(in: .whitespaces).isEmpty
            && !type.trimmingCharacters(in: .whitespaces).isEmpty
            && shelfLifeOk
            && barcodeOk
    }

    private var trimmedBarcode: String {
        scannedBarcode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        isSaving = true
        Task {
            do {
                let draft = ProductDraft(
                    name: name.trimmingCharacters(in: .whitespaces),
                    productCode: productCode.trimmingCharacters(in: .whitespaces),
                    type: type.trimmingCharacters(in: .whitespaces),
                    shelfLifeDays: shelfLifeText.isEmpty ? nil : Int(shelfLifeText),
                    photoJpeg: photo.flatMap(PhotoService.thumbnailJpeg),
                    objectScan: objectScanCapture.map {
                        ObjectDimensionCalculator.makeRecord(
                            capture: $0,
                            displayUnit: displayUnit,
                            canBeRotated: canBeRotated
                        )
                    }
                )
                let productId = try await ProductRepository.create(draft)

                switch barcodeMode {
                case .none:
                    break
                case .generate:
                    _ = try await BarcodeService.generateAndAssign(to: productId)
                case .scanned:
                    try await BarcodeService.assign(trimmedBarcode, to: productId)
                }
                dismiss()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
