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

    private enum RestingSurfaceAnswer: String, CaseIterable, Identifiable {
        case yes = "Yes"
        case no = "No"
        case selected = "Only selected orientations"
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
    @State private var showsManualMeasurement = false
    @State private var showsManualEntry = false
    @State private var objectScanCapture: ObjectScanCapture?
    @State private var displayUnit: DimensionDisplayUnit = .centimetres
    @State private var canBeRotated = false
    @State private var percentageTolerance = ObjectDimensionPolicy.default.percentageTolerance
    @State private var fixedToleranceCM = ObjectDimensionPolicy.default.fixedToleranceCM
    @State private var useAdjustedDimensions = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var placementWeight = ""
    @State private var retrievalPriority: RetrievalPriority = .normal
    @State private var retrievalFrequency = 0.5
    @State private var fragilityKnown = false
    @State private var isFragile = false
    @State private var restingSurface: RestingSurfaceAnswer = .yes
    @State private var mustRemainUpright = true
    @State private var canSupportAbove = false
    @State private var canRestOnProduct = false
    @State private var maximumSupportedWeight = ""
    @State private var fragileTopSurface = true
    @State private var requiredSupportPercentage = "95"
    @State private var maximumItemsAbove = ""
    @State private var maximumTotalStackHeight = ""
    @State private var requiredClearance = "2"
    @State private var selectedRestingFaces: Set<RestingFace> = [.bottom]
    @State private var quantityArrangement: QuantityArrangement = .singleUnit

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
                placementRulesSection
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
            .fullScreenCover(isPresented: $showsManualMeasurement) {
                ManualARMeasurementView { capture, percentage, fixed, rotationAllowed, useAdjusted in
                    objectScanCapture = capture
                    percentageTolerance = percentage
                    fixedToleranceCM = fixed
                    canBeRotated = rotationAllowed
                    useAdjustedDimensions = useAdjusted
                }
            }
            .sheet(isPresented: $showsManualEntry) {
                ManualDimensionEntryView(
                    canBeRotated: $canBeRotated,
                    onSave: { capture in objectScanCapture = capture }
                )
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
                percentageTolerance: $percentageTolerance,
                fixedToleranceCM: $fixedToleranceCM,
                useAdjustedDimensions: $useAdjustedDimensions,
                onRescan: { showsObjectScanner = true }
            )
            Button("Measure with AR") { showsManualMeasurement = true }
            Button("Enter Dimensions Manually") { showsManualEntry = true }
        } else {
            Section("Storage Dimensions") {
                Button {
                    showsManualMeasurement = true
                } label: {
                    Label("Measure with AR", systemImage: "ruler")
                }
                Button {
                    showsObjectScanner = true
                } label: {
                    Label("Start Object Scan", systemImage: "arkit")
                }
                Button {
                    showsManualEntry = true
                } label: {
                    Label("Enter Dimensions Manually", systemImage: "square.and.pencil")
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

    private var placementRulesSection: some View {
        Section("Placement & Handling") {
            TextField("Product weight in kg (required for automatic placement)", text: $placementWeight)
                .keyboardType(.decimalPad)
            Picker("Retrieval priority", selection: $retrievalPriority) {
                ForEach(RetrievalPriority.allCases) { priority in
                    Text(String(describing: priority).capitalized).tag(priority)
                }
            }
            VStack(alignment: .leading) {
                Text("Expected retrieval frequency")
                Slider(value: $retrievalFrequency, in: 0...1)
            }
            Toggle("Fragility information is known", isOn: $fragilityKnown)
            if fragilityKnown { Toggle("Fragile", isOn: $isFragile) }
            Picker("Allowed resting faces", selection: $restingSurface) {
                ForEach(RestingSurfaceAnswer.allCases) { Text($0.rawValue).tag($0) }
            }
            if restingSurface == .selected {
                ForEach(RestingFace.allCases) { face in
                    Toggle(face.rawValue.capitalized, isOn: Binding(
                        get: { selectedRestingFaces.contains(face) },
                        set: { enabled in
                            if enabled { selectedRestingFaces.insert(face) }
                            else { selectedRestingFaces.remove(face) }
                        }
                    ))
                }
            }
            Toggle("Must remain upright", isOn: $mustRemainUpright)
            Toggle("May rotate automatically", isOn: $canBeRotated)
            Toggle("May support products above", isOn: $canSupportAbove)
            Toggle("May be placed on another product", isOn: $canRestOnProduct)
            if canSupportAbove {
                TextField("Maximum supported weight (kg)", text: $maximumSupportedWeight)
                    .keyboardType(.decimalPad)
                Toggle("Fragile top surface", isOn: $fragileTopSurface)
                TextField("Required support ratio (%)", text: $requiredSupportPercentage)
                    .keyboardType(.decimalPad)
                TextField("Maximum items above (optional)", text: $maximumItemsAbove)
                    .keyboardType(.numberPad)
                TextField("Maximum total stack height in cm (optional)", text: $maximumTotalStackHeight)
                    .keyboardType(.decimalPad)
            }
            TextField("Required handling clearance (cm)", text: $requiredClearance)
                .keyboardType(.decimalPad)
            Picker("Quantity represents", selection: $quantityArrangement) {
                Text("One physical unit").tag(QuantityArrangement.singleUnit)
                Text("One grouped case").tag(QuantityArrangement.groupedCase)
                Text("Separate units").tag(QuantityArrangement.separateUnits)
            }
            Text("Missing weight disables automatic placement. Invalid or incomplete support data is treated as direct-surface-only.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        let weightOk = placementWeight.isEmpty || (Double(placementWeight).map { $0.isFinite && $0 > 0 } ?? false)
        let supportCapacityOk = !canSupportAbove || (Double(maximumSupportedWeight).map { $0.isFinite && $0 > 0 } ?? false)
        let supportRatioOk = !canSupportAbove || (Double(requiredSupportPercentage).map { (95...100).contains($0) } ?? false)
        let itemLimitOk = maximumItemsAbove.isEmpty || (Int(maximumItemsAbove).map { $0 > 0 } ?? false)
        let heightLimitOk = maximumTotalStackHeight.isEmpty
            || (Double(maximumTotalStackHeight).map { $0.isFinite && $0 > 0 } ?? false)
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !productCode.trimmingCharacters(in: .whitespaces).isEmpty
            && !type.trimmingCharacters(in: .whitespaces).isEmpty
            && shelfLifeOk
            && barcodeOk
            && weightOk
            && supportCapacityOk
            && supportRatioOk
            && itemLimitOk
            && heightLimitOk
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
                            canBeRotated: canBeRotated,
                            useAdjustedDimensions: useAdjustedDimensions,
                            policy: .init(
                                fixedToleranceCM: max(fixedToleranceCM, 0),
                                percentageTolerance: max(percentageTolerance, 0),
                                storageClearanceCM: 0
                            )
                        )
                    },
                    placementMetadata: ProductPlacementMetadata(
                        weightKG: Double(placementWeight),
                        retrievalPriority: retrievalPriority,
                        expectedRetrievalFrequency: retrievalFrequency,
                        expirationUrgency: 0,
                        isFragile: fragilityKnown ? isFragile : nil,
                        permittedRestingFaces: restingSurface == .no ? [] :
                            (restingSurface == .selected ? selectedRestingFaces : [.bottom]),
                        mustRemainUpright: mustRemainUpright,
                        mayRotateAutomatically: canBeRotated,
                        requiredClearanceCM: max(Double(requiredClearance) ?? 2, 0),
                        stacking: StackingRules(
                            canSupportProductsAbove: canSupportAbove,
                            canBePlacedOnAnotherProduct: canRestOnProduct,
                            maximumSupportedWeight: Double(maximumSupportedWeight),
                            maximumTotalStackHeight: Double(maximumTotalStackHeight),
                            maximumItemsAbove: Int(maximumItemsAbove),
                            maximumIdenticalStackCount: nil,
                            allowedProductTypesAbove: nil,
                            prohibitedProductTypesAbove: nil,
                            requiresFullBaseSupport: (Double(requiredSupportPercentage) ?? 100) >= 100,
                            minimumSupportRatio: (Double(requiredSupportPercentage) ?? 100) / 100,
                            fragileTopSurface: fragileTopSurface,
                            notes: nil
                        ),
                        quantityArrangement: quantityArrangement
                    )
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
