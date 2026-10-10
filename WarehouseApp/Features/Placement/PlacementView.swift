import SwiftUI
import simd

struct PlacementView: View {
    @Environment(InventoryStore.self) private var store
    @Environment(AuthService.self) private var auth
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedProduct: Product?
    @State private var width = "30"
    @State private var height = "20"
    @State private var depth = "25"
    @State private var weight = ""
    @State private var velocity = 0.5
    @State private var showProductScanner = false
    @State private var showSurfaceScanner = false
    @State private var spaceSurfaceType: SpaceSurfaceType = .unknown
    @State private var scannedOpenSpace: ScannedSpaceGeometry?
    @State private var spaceName = ""
    @State private var spaceSaveMessage: String?
    @State private var isSavingSpace = false
    @State private var assumedHeight = "40"
    @State private var verification: PlacementVerification?
    @State private var showVerificationScanner = false
    @State private var preciseCalculation: PlacementCalculation?
    @State private var selectedPrecisePlacement: ProductPlacementResult?
    @State private var isCalculating = false
    @State private var markerStage: StorageMarkerStage = .selectSurface
    @State private var markerDraft: StorageMarkerDraft?
    @State private var markerCount = 0
    @State private var markerCanPlace = false
    @State private var markerGuidance = "Stand at the front of the storage area, facing in, and aim at the surface where products will sit."
    @State private var markerError: String?
    @State private var markerPlacementRequestID = 0
    @State private var markerUndoRequestID = 0
    @State private var markerResetRequestID = 0
    @State private var markerPreviewRequestID = 0
    @State private var markerUseCorrectedFootprint = true
    @State private var operationalShelves: [ShelfState] = []
    @State private var selectedShelfID = ""
    @State private var searchAllAreas = true
    @State private var placementReservation: PlacementReservation?
    @State private var reservedPackageProfile: PackagePlacementProfile?
    @State private var placementStatusMessage: String?
    @State private var isPersistingPlacement = false

    var body: some View {
        NavigationStack {
            Form {
                productSection
                packageSection
                scanSection
                recommendationsSection
                preciseGuidanceSection
                verificationSection
                storedPlacementsSection
            }
            .navigationTitle("Place")
            .sheet(isPresented: $showProductScanner) {
                ScannerSheet(title: "Scan Product") { selectProduct(barcode: $0) }
            }
            .sheet(isPresented: $showVerificationScanner) {
                ScannerSheet(title: verificationTitle) { acceptVerificationScan($0) }
            }
            .fullScreenCover(isPresented: $showSurfaceScanner) {
                surfaceScanner
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background, showSurfaceScanner else { return }
                markerError = "The AR session was interrupted. Restart the measurement so markers do not mix coordinate systems."
                markerDraft = nil
                markerStage = .selectSurface
                markerCount = 0
                showSurfaceScanner = false
            }
            .task { await loadOperationalShelves() }
        }
    }

    private var productSection: some View {
        Section("1 · Product") {
            if let selectedProduct {
                LabeledContent("Product", value: selectedProduct.name)
                LabeledContent("SKU", value: selectedProduct.productCode)
            } else {
                Text("Scan a registered product before calculating placement.")
                    .foregroundStyle(.secondary)
            }
            Button {
                showProductScanner = true
            } label: {
                Label("Scan product barcode", systemImage: "barcode.viewfinder")
            }
            .disabled(placementReservation != nil)
        }
    }

    private var packageSection: some View {
        Section("2 · Package") {
            HStack {
                dimensionField("W", text: $width)
                dimensionField("H", text: $height)
                dimensionField("D", text: $depth)
            }
            TextField("Weight (kg)", text: $weight)
                .keyboardType(.decimalPad)
            if parsedWeight == nil {
                Text("A finite positive weight is required for automatic placement.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let packageProfile {
                LabeledContent("Raw dimensions", value: dimensionText(packageProfile.dimensions))
                if let shelf = activePlacementState {
                    let effective = PlacementEngine.effectiveDimensions(
                        package: packageProfile, shelf: shelf, configuration: .warehouse
                    )
                    LabeledContent("Effective dimensions", value: dimensionText(effective))
                }
            }
            VStack(alignment: .leading) {
                Text("Pick frequency")
                Slider(value: $velocity, in: 0...1)
            }
        }
    }

    private var scanSection: some View {
        Section("3 · Storage geometry") {
            if operationalShelves.isEmpty {
                Text("No saved storage areas are available. Measure and save one before requesting an operational recommendation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if operationalShelves.count > 1 {
                    Toggle("Choose the best storage area automatically", isOn: $searchAllAreas)
                        .disabled(placementReservation != nil || isCalculating)
                }
                Picker("Saved storage area", selection: $selectedShelfID) {
                    ForEach(operationalShelves) { shelf in
                        Text(shelfSelectionLabel(shelf)).tag(shelf.id)
                    }
                }
                .disabled(placementReservation != nil || scannedOpenSpace != nil || isSavingSpace
                          || isCalculating || usesAreaSearch)
                if usesAreaSearch, placementReservation == nil {
                    LabeledContent("Calculation uses", value: "Best of \(operationalShelves.count) saved areas")
                } else if let shelf = activePlacementState {
                    LabeledContent("Calculation uses", value: shelfSelectionLabel(shelf))
                    LabeledContent("Selected usable space", value: dimensionText(PlacementEngine.usableDimensions(of: shelf)))
                }
            }
            Button {
                prepareNewMarkerScan()
                showSurfaceScanner = true
            } label: {
                Label("Measure storage space", systemImage: "scope")
            }
            .disabled(placementReservation != nil || isCalculating || isSavingSpace)
            Picker("Storage surface", selection: $spaceSurfaceType) {
                ForEach(SpaceSurfaceType.allCases) { Text($0.title).tag($0) }
            }
            .disabled(isSavingSpace)
            .onChange(of: spaceSurfaceType) { _, surface in
                // The unsaved scan copied the surface when it was finalized.
                scannedOpenSpace?.surfaceType = surface
            }
            if let space = scannedOpenSpace {
                SpaceVolumePreview(space: space)
                    .frame(height: 190)
                    .accessibilityLabel("Three dimensional preview of the approved \(space.surfaceType.title) storage volume")
                LabeledContent("Space type", value: space.surfaceType.title)
                LabeledContent("Height", value: "\(format(space.heightCM)) cm")
                LabeledContent("Geometry confidence", value: space.confidence.overall.formatted(.percent.precision(.fractionLength(0))))
                Label("Unsaved scan — placement calculation is disabled until this area is saved and selected.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                TextField("Storage area name (e.g. Back room floor)", text: $spaceName)
                    .disabled(isSavingSpace)
                Button("Save approved space") {
                    var named = space
                    named.name = spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
                    scannedOpenSpace = named
                    saveApprovedSpace(named)
                }
                .disabled(isSavingSpace)
                if isSavingSpace { ProgressView("Saving and selecting storage area…") }
                if let spaceSaveMessage { Text(spaceSaveMessage).font(.caption) }
            }
            Text("Select the horizontal base surface, place four wall boundaries, then enter the usable storage height. All displayed dimensions are centimetres.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var recommendationsSection: some View {
        Section("4 · Recommended location") {
            Button("Calculate and reserve placement") { calculatePrecisePlacement() }
                .disabled(packageProfile == nil || (selectedShelfID.isEmpty && !usesAreaSearch) || scannedOpenSpace != nil ||
                          isSavingSpace || isCalculating || placementReservation != nil)
            if placementReservation != nil {
                Button("Cancel reservation", role: .destructive) { cancelReservation() }
                    .disabled(isPersistingPlacement)
            }
            Text("The latest saved occupancy is loaded first. A storage-area lock is acquired before guidance is shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let placementStatusMessage {
                Text(placementStatusMessage).font(.caption)
            }
        }
    }

    @ViewBuilder
    /// Confirmed placements across all measured spaces, with the ability to
    /// take a product back out (frees its occupied volume for new placements).
    private var storedPlacementsSection: some View {
        Section("Stored Products") {
            let entries = operationalShelves.flatMap { shelf in
                shelf.products.map { (shelf: shelf, placement: $0) }
            }
            if entries.isEmpty {
                Text("Nothing placed yet. Confirmed placements appear here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.placement.id) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(placedProductName(entry.placement.productID))
                            Text(entry.shelf.displayLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Un-place", role: .destructive) {
                            unplace(entry.placement, from: entry.shelf)
                        }
                        .disabled(isPersistingPlacement)
                    }
                }
            }
        }
    }

    private func placedProductName(_ productID: String) -> String {
        store.products.first { $0.id == productID }?.name ?? "Unknown product"
    }

    private func unplace(_ placement: StoredProductPlacement, from shelf: ShelfState) {
        isPersistingPlacement = true
        Task { @MainActor in
            do {
                try await PlacementRepository.removePlacement(
                    id: placement.id,
                    shelfID: shelf.id,
                    expectedShelfVersion: shelf.version
                )
                await loadOperationalShelves(selecting: shelf.id)
                placementStatusMessage = "Removed \(placedProductName(placement.productID)) from \(shelf.displayLabel)."
            } catch {
                placementStatusMessage = error.localizedDescription
            }
            isPersistingPlacement = false
        }
    }

    private var verificationSection: some View {
        Section("6 · Verify placement") {
            if let destination = selectedPrecisePlacement == nil ? nil : activePlacementState?.displayLabel {
                LabeledContent("Destination", value: destination)
                switch verification?.stage {
                case .scanProduct:
                    Button("Scan product") { showVerificationScanner = true }
                case .scanLocation:
                    Button("Scan location") { showVerificationScanner = true }
                case .complete:
                    Label("Both barcodes verified", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button("Confirm placement is physically complete") {
                        confirmPlacement()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPersistingPlacement || placementReservation == nil)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button("Try again") { verification?.retry() }
                case nil:
                    Text("Select a recommendation first.")
                }
                if let placementStatusMessage {
                    Text(placementStatusMessage).font(.caption)
                }
            } else {
                Text("Select a recommended location to start the two-scan check.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var surfaceScanner: some View {
        NavigationStack {
            ZStack {
                if StorageMarkerScannerView.isSupported {
                    StorageMarkerScannerView(
                        stage: $markerStage,
                        draft: $markerDraft,
                        markerCount: $markerCount,
                        canPlace: $markerCanPlace,
                        guidance: $markerGuidance,
                        errorMessage: $markerError,
                        placementRequestID: markerPlacementRequestID,
                        undoRequestID: markerUndoRequestID,
                        resetRequestID: markerResetRequestID,
                        previewRequestID: markerPreviewRequestID,
                        useCorrectedFootprint: markerUseCorrectedFootprint,
                        previewHeightCM: validManualSpaceHeight
                    )
                    .ignoresSafeArea()
                } else {
                    ContentUnavailableView(
                        "AR measurement unavailable",
                        systemImage: "viewfinder",
                        description: Text("Use a device that supports AR world tracking.")
                    )
                }

                VStack {
                    markerProgressHeader
                    Spacer()
                    markerControls
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSurfaceScanner = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish") {
                        showSurfaceScanner = false
                    }
                    .disabled(markerStage != .complete || scannedOpenSpace == nil)
                }
            }
        }
    }

    private var markerProgressHeader: some View {
        VStack(spacing: 5) {
            Text(markerStageTitle)
                .font(.headline)
            Text(markerProgressText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
    }

    private var markerControls: some View {
        VStack(spacing: 10) {
            Text(markerGuidance)
                .font(.caption)
                .multilineTextAlignment(.center)
            if let markerError {
                Label(markerError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            switch markerStage {
            case .selectSurface:
                Button("Select Storage Surface") { markerPlacementRequestID += 1 }
                    .buttonStyle(.borderedProminent)
                    .disabled(!markerCanPlace)
            case .placeBoundaries:
                Button("Place Boundary \(markerCount + 1)/4") {
                    markerPlacementRequestID += 1
                }
                .buttonStyle(.borderedProminent)
                .disabled(!markerCanPlace || markerCount >= 4)
            case .review:
                if let draft = markerDraft {
                    LabeledContent("Measured area", value: markerArea(draft.rawFootprint2D))
                    if draft.correctedFootprint2D != nil {
                        Toggle("Apply suggested 90° correction", isOn: $markerUseCorrectedFootprint)
                        Text("Maximum corner adjustment: \(format(draft.correctionMaximumMovementMetres * 100)) cm. Raw marker positions remain saved.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("The measured angles are intentionally non-rectangular or exceed the safe correction limit. No rectangle was forced.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Use This Footprint") {
                    markerError = nil
                    markerStage = .enterHeight
                }
                .buttonStyle(.borderedProminent)
            case .enterHeight:
                Text("How many cm do you want the storage height to be?")
                    .font(.headline)
                HStack {
                    TextField("Storage height", text: $assumedHeight)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                    Text("cm")
                        .foregroundStyle(.secondary)
                }
                Button("Preview Storage Volume") {
                    if validManualSpaceHeight != nil {
                        markerError = nil
                        markerStage = .preview
                        markerPreviewRequestID += 1
                    } else {
                        markerError = "Enter a storage height greater than 1 cm and no more than 5000 cm."
                    }
                }
                .buttonStyle(.borderedProminent)
            case .preview:
                if let outline = markerVolumeOutline {
                    Text("Available Storage")
                        .font(.headline)
                    if let dimensions = outline.rectangularDimensions {
                        LabeledContent(
                            "Width", value: "\(format(dimensions.widthMetres * 100)) cm"
                        )
                        LabeledContent(
                            "Depth", value: "\(format(dimensions.depthMetres * 100)) cm"
                        )
                    }
                    LabeledContent(
                        "Floor area", value: "\(format(outline.floorAreaSquareMetres)) m²"
                    )
                    LabeledContent(
                        "Height", value: "\(format(outline.heightMetres * 100)) cm"
                    )
                    LabeledContent(
                        "Volume", value: "\(format(outline.volumeCubicMetres)) m³"
                    )
                }
                Button("Confirm Storage Space") {
                    finalizeMarkerSpace()
                }
                .buttonStyle(.borderedProminent)
            case .complete:
                Label("Storage space confirmed", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Use Finish to return to product placement, or reset to measure again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if [.placeBoundaries, .review].contains(markerStage) {
                Button("Undo Last Marker") { markerUndoRequestID += 1 }
                    .buttonStyle(.bordered)
            } else if markerStage == .enterHeight {
                Button("Back to Boundary Review") { markerStage = .review }
                    .buttonStyle(.bordered)
            } else if markerStage == .preview {
                Button("Adjust Height") { markerStage = .enterHeight }
                    .buttonStyle(.bordered)
                Button("Undo Boundary") { markerUndoRequestID += 1 }
                    .buttonStyle(.bordered)
            }
            if markerStage != .selectSurface {
                Button(markerStage == .preview ? "Rescan" : "Reset Measurement", role: .destructive) {
                    scannedOpenSpace = nil
                    assumedHeight = ""
                    markerUseCorrectedFootprint = true
                    markerResetRequestID += 1
                }
                .buttonStyle(.bordered)
            }
        }
        .font(.footnote.weight(.medium))
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var markerStageTitle: String {
        switch markerStage {
        case .selectSurface: "Select Storage Surface"
        case .placeBoundaries: "Boundary \(min(markerCount + 1, 4))/4"
        case .review: "Review Footprint"
        case .enterHeight: "Enter Storage Height"
        case .preview: "Preview Storage Volume"
        case .complete: "Storage Space Ready"
        }
    }

    private var markerProgressText: String {
        switch markerStage {
        case .selectSurface: "Detect horizontal base"
        case .placeBoundaries: "Horizontal base selected · four wall markers only"
        case .review: "Surface selected · Boundary 4/4 · Review"
        case .enterHeight: "Surface selected · Boundary 4/4 · Height"
        case .preview: "Surface selected · Boundary 4/4 · Preview"
        case .complete: "Surface selected · Boundary 4/4 · Confirmed"
        }
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func dimensionText(_ dimensions: PackageDimensions) -> String {
        "\(format(dimensions.widthCM)) × \(format(dimensions.heightCM)) × \(format(dimensions.depthCM)) cm (W × H × D)"
    }

    private var parsedWeight: Double? {
        PlacementWorkflow.positiveDecimal(
            weight, maximum: PlacementWorkflow.maximumWeightKG
        )
    }

    private func dimensionField(_ label: String, text: Binding<String>) -> some View {
        TextField("\(label) (cm)", text: text)
            .keyboardType(.decimalPad)
    }

    private var packageProfile: PackagePlacementProfile? {
        guard let product = selectedProduct,
              let width = PlacementWorkflow.positiveDecimal(
                width, maximum: PlacementWorkflow.maximumDimensionCM
              ),
              let height = PlacementWorkflow.positiveDecimal(
                height, maximum: PlacementWorkflow.maximumDimensionCM
              ),
              let depth = PlacementWorkflow.positiveDecimal(
                depth, maximum: PlacementWorkflow.maximumDimensionCM
              ),
              let weight = parsedWeight
        else { return nil }
        var metadata = product.placementMetadata ?? .conservative
        metadata.weightKG = weight
        // The engine reads pick frequency from the handling rules.
        metadata.expectedRetrievalFrequency = velocity
        if product.placementMetadata == nil, product.objectScan?.canBeRotated == true {
            // Legacy scan records only establish yaw permission. They do not
            // prove that tipping the product onto another face is safe.
            metadata.mayRotateAutomatically = true
            metadata.mustRemainUpright = true
            metadata.permittedRestingFaces = [.bottom]
        }
        return PackagePlacementProfile(
            productId: product.id,
            dimensions: PackageDimensions(widthCM: width, heightCM: height, depthCM: depth),
            weightKG: weight,
            demandVelocity: velocity,
            productType: product.type,
            metadata: metadata,
            measurementUncertaintyCM: PackageDimensions(
                widthCM: product.objectScan?.scanToleranceWidth ?? 0,
                heightCM: product.objectScan?.scanToleranceHeight ?? 0,
                depthCM: product.objectScan?.scanToleranceLength ?? 0
            )
        )
    }

    @ViewBuilder
    private var preciseGuidanceSection: some View {
        Section("5 · Placement guidance") {
            if isCalculating {
                HStack { ProgressView(); Text("Calculating collision, support, insertion, and retrieval paths…") }
            } else if let placement = selectedPrecisePlacement {
                Label("Reserved safe placement", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let shelf = activePlacementState {
                    PlacementGuide3DView(shelf: shelf, placement: placement)
                }
                Text(placement.instructions)
                ForEach(placement.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if let message = preciseCalculation?.failureMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if shouldOfferRescan {
                    Button("Rescan storage area") {
                        prepareNewMarkerScan()
                        showSurfaceScanner = true
                    }
                }
            } else {
                Text("Complete the product and shelf scan to calculate a precise shelf-local placement.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var validManualSpaceHeight: Double? {
        guard let value = PlacementWorkflow.positiveDecimal(
            assumedHeight, maximum: PlacementWorkflow.maximumDimensionCM
        ), value > 1 else { return nil }
        return value
    }

    private var shouldOfferRescan: Bool {
        let reasons = preciseCalculation?.evaluations.flatMap(\.rejectionReasons) ?? []
        return reasons.contains(.lowScanConfidence) || reasons.contains(.staleShelfState)
    }

    /// With a single saved area there is nothing to search.
    private var usesAreaSearch: Bool {
        searchAllAreas && operationalShelves.count > 1
    }

    private var activePlacementState: ShelfState? {
        operationalShelves.first { $0.id == selectedShelfID }
    }

    private func prepareNewMarkerScan() {
        selectedShelfID = ""
        scannedOpenSpace = nil
        spaceName = ""
        spaceSaveMessage = nil
        preciseCalculation = nil
        selectedPrecisePlacement = nil
        verification = nil
        assumedHeight = ""
        markerDraft = nil
        markerStage = .selectSurface
        markerCount = 0
        markerCanPlace = false
        markerGuidance = "Stand at the front of the storage area, facing in, and aim at the surface where products will sit."
        markerError = nil
        markerUseCorrectedFootprint = true
        markerPlacementRequestID = 0
        markerUndoRequestID = 0
        markerPreviewRequestID = 0
        markerResetRequestID += 1
    }

    private func finalizeMarkerSpace() {
        guard let captured = markerDraft, let height = validManualSpaceHeight else {
            markerError = "The footprint or storage height is incomplete."
            return
        }
        // Stored axes run along the walls, so products are placed square to
        // them whatever angle the phone was held at during the scan.
        let draft = captured.alignedToWalls(useCorrectedFootprint: markerUseCorrectedFootprint)
        let record = draft.record(
            approvedCorrected: markerUseCorrectedFootprint,
            heightCM: height
        )
        let toCentimetres: ([Vector2D]) -> [Vector2D] = { points in
            points.map { Vector2D($0.x * 100, $0.y * 100) }
        }
        let space = ScannedSpaceGeometry(
            id: draft.id,
            geometryType: .openSpace,
            surfaceType: spaceSurfaceType,
            rawBoundary2D: toCentimetres(record.rawFootprint2D),
            suggestedBoundary2D: record.correctedFootprint2D.map(toCentimetres),
            approvedBoundary2D: toCentimetres(record.approvedFootprint2D),
            excludedRegions2D: [],
            localOrigin: draft.basePlaneOriginWorld,
            localXAxis: draft.localXAxisWorld,
            localYAxis: draft.localDepthAxisWorld,
            localVerticalAxis: draft.verticalAxisWorld,
            bottomPlane: CodablePlane(
                origin: draft.basePlaneOriginWorld,
                normal: draft.verticalAxisWorld
            ),
            topDefinition: .manualLimitCM(height),
            heightCM: height,
            accessDirections: [Vector3D(0, 0, 1)],
            confidence: SpaceConfidence(
                baseSurface: draft.confidence,
                boundary: draft.confidence,
                corners: draft.confidence,
                walls: nil,
                surfaceEdges: draft.deviceHasLiDAR ? draft.confidence : nil,
                height: 1
            ),
            approval: .approved,
            geometryVersion: 9,
            createdAt: record.capturedAt,
            updatedAt: record.capturedAt,
            measurementMethod: .markerBoundaries,
            measuredCorners: nil,
            scannedBoundary: nil,
            markerMeasurement: record
        )
        do {
            try SpaceGeometryValidator.validate(space)
            scannedOpenSpace = space
            markerStage = .complete
            markerError = nil
            markerGuidance = "The polygon footprint and height are approved for product placement."
        } catch {
            markerError = error.localizedDescription
        }
    }

    private func markerArea(_ polygon: [Vector2D]) -> String {
        guard polygon.count >= 3 else { return "—" }
        let doubled = polygon.indices.reduce(0.0) { value, index in
            let next = polygon[(index + 1) % polygon.count]
            return value + polygon[index].x * next.y - next.x * polygon[index].y
        }
        return "\(format(abs(doubled) / 2)) m²"
    }

    private var markerVolumeOutline: StorageVolumeOutline? {
        guard let draft = markerDraft, let height = validManualSpaceHeight else { return nil }
        return draft.volumeOutline(
            useCorrectedFootprint: markerUseCorrectedFootprint,
            heightCM: height
        )
    }

    private func calculatePrecisePlacement() {
        guard !isCalculating, placementReservation == nil,
              let packageProfile, let userID = auth.user?.uid else { return }
        guard !usesAreaSearch else {
            calculateAcrossAreas(package: packageProfile, userID: userID)
            return
        }
        let requestedShelfID: String
        do {
            requestedShelfID = try PlacementWorkflow.calculationShelfID(
                selectedShelfID: selectedShelfID,
                unsavedSpaceID: scannedOpenSpace?.id
            )
        } catch {
            placementStatusMessage = error.localizedDescription
            return
        }
        isCalculating = true
        placementStatusMessage = nil
        selectedPrecisePlacement = nil
        Task { @MainActor in
            do {
                guard let shelf = try await PlacementRepository.fetchShelf(id: requestedShelfID) else {
                    throw PlacementPersistenceError.shelfMissing
                }
                guard selectedShelfID == requestedShelfID, scannedOpenSpace == nil else {
                    throw PlacementWorkflowError.selectionChanged
                }
                replaceOperationalShelf(shelf)
                if try await PlacementRepository.fetchActiveReservation(shelfID: shelf.id) != nil {
                    throw PlacementPersistenceError.reservationConflict
                }
                let result = await Task.detached(priority: .userInitiated) {
                    PlacementEngine.calculate(package: packageProfile, shelf: shelf)
                }.value
                guard !Task.isCancelled else {
                    isCalculating = false
                    return
                }
                guard selectedShelfID == requestedShelfID, scannedOpenSpace == nil,
                      self.packageProfile == packageProfile else {
                    throw PlacementWorkflowError.selectionChanged
                }
                preciseCalculation = result
                guard let recommendation = result.recommendation else {
                    // The guidance section already presents the failure.
                    isCalculating = false
                    return
                }
                try await reserve(recommendation, in: shelf, package: packageProfile, userID: userID)
                placementStatusMessage = "Storage area reserved for two minutes. Verify both barcodes, place the product, then confirm."
                isCalculating = false
            } catch {
                placementStatusMessage = error.localizedDescription
                if case .shelfMissing? = error as? PlacementPersistenceError {
                    operationalShelves.removeAll { $0.id == requestedShelfID }
                    if selectedShelfID == requestedShelfID { selectedShelfID = "" }
                }
                isCalculating = false
            }
        }
    }

    private func reserve(
        _ recommendation: ProductPlacementResult,
        in shelf: ShelfState,
        package: PackagePlacementProfile,
        userID: String
    ) async throws {
        placementReservation = try await PlacementRepository.reserve(result: recommendation, userID: userID)
        reservedPackageProfile = package
        selectedPrecisePlacement = recommendation
        // Arm the two-scan check: without this the Verify section can
        // never leave its "Select a recommendation" state.
        verification = PlacementVerification(
            expectedProductBarcode: selectedProduct?.barcode ?? "",
            expectedLocationBarcode: shelf.barcode
        )
    }

    /// Searches every saved area that no other worker currently holds and
    /// reserves the best area and position together.
    private func calculateAcrossAreas(package: PackagePlacementProfile, userID: String) {
        guard scannedOpenSpace == nil else {
            placementStatusMessage = PlacementWorkflowError.unsavedStorageScan.localizedDescription
            return
        }
        isCalculating = true
        placementStatusMessage = nil
        selectedPrecisePlacement = nil
        Task { @MainActor in
            do {
                let shelves = try await PlacementRepository.fetchShelves()
                operationalShelves = shelves
                if !shelves.contains(where: { $0.id == selectedShelfID }) {
                    selectedShelfID = shelves.first?.id ?? ""
                }
                var available: [ShelfState] = []
                for shelf in shelves {
                    if try await PlacementRepository.fetchActiveReservation(shelfID: shelf.id) == nil {
                        available.append(shelf)
                    }
                }
                guard !available.isEmpty || shelves.isEmpty else {
                    throw PlacementPersistenceError.reservationConflict
                }
                let result = await Task.detached(priority: .userInitiated) {
                    PlacementEngine.calculate(package: package, shelves: available)
                }.value
                // The form may have been edited while the areas were fetched and searched.
                guard searchAllAreas, scannedOpenSpace == nil, self.packageProfile == package else {
                    throw PlacementWorkflowError.selectionChanged
                }
                guard let recommendation = result.recommendation,
                      let shelf = available.first(where: { $0.id == result.recommendedShelfID }) else {
                    preciseCalculation = PlacementCalculation(
                        recommendation: nil, alternatives: [], evaluations: [],
                        failureMessage: result.failureMessage
                    )
                    isCalculating = false
                    return
                }
                selectedShelfID = shelf.id
                preciseCalculation = result.calculations[shelf.id]
                try await reserve(recommendation, in: shelf, package: package, userID: userID)
                let skipped = shelves.count - available.count
                placementStatusMessage = "Chose \(shelf.displayLabel) from \(available.count) storage areas"
                    + (skipped > 0 ? " (\(skipped) in use by another placement)" : "")
                    + ". Reserved for two minutes. Verify both barcodes, place the product, then confirm."
                isCalculating = false
            } catch {
                placementStatusMessage = error.localizedDescription
                isCalculating = false
            }
        }
    }

    private func saveApprovedSpace(_ space: ScannedSpaceGeometry) {
        guard !isSavingSpace, scannedOpenSpace?.id == space.id else { return }
        isSavingSpace = true
        spaceSaveMessage = nil
        Task { @MainActor in
            do {
                let savedSpace = try await SpaceRepository.save(space, expectedVersion: nil)
                let shelf = try await PlacementRepository.initializeOperationalShelf(from: savedSpace)
                guard scannedOpenSpace?.id == space.id else {
                    throw PlacementWorkflowError.selectionChanged
                }
                replaceOperationalShelf(shelf)
                selectedShelfID = shelf.id
                scannedOpenSpace = nil
                spaceSaveMessage = "Saved and selected \(shelfSelectionLabel(shelf))."
                placementStatusMessage = "Ready to calculate using \(shelfSelectionLabel(shelf))."
            } catch {
                selectedShelfID = ""
                spaceSaveMessage = error.localizedDescription
            }
            isSavingSpace = false
        }
    }

    private func shelfSelectionLabel(_ shelf: ShelfState) -> String {
        let suffix = String(shelf.id.suffix(8))
        return "\(shelf.displayLabel) · \(suffix)"
    }

    private func loadOperationalShelves(selecting shelfID: String? = nil) async {
        do {
            let shelves = try await PlacementRepository.fetchShelves()
            operationalShelves = shelves
            if let shelfID, shelves.contains(where: { $0.id == shelfID }) {
                selectedShelfID = shelfID
            } else if !shelves.contains(where: { $0.id == selectedShelfID }) {
                selectedShelfID = shelves.first?.id ?? ""
            }
        } catch {
            placementStatusMessage = error.localizedDescription
        }
    }

    private func replaceOperationalShelf(_ shelf: ShelfState) {
        if let index = operationalShelves.firstIndex(where: { $0.id == shelf.id }) {
            operationalShelves[index] = shelf
        } else {
            operationalShelves.append(shelf)
        }
    }

    private func confirmPlacement() {
        guard !isPersistingPlacement,
              verification?.stage == .complete,
              let reservation = placementReservation,
              let result = selectedPrecisePlacement,
              let packageProfile = reservedPackageProfile else { return }
        isPersistingPlacement = true
        Task { @MainActor in
            do {
                guard let currentShelf = try await PlacementRepository.fetchShelf(id: result.shelfID) else {
                    throw PlacementPersistenceError.shelfMissing
                }
                guard currentShelf.version == result.shelfVersion else {
                    throw PlacementPersistenceError.staleShelf(
                        expected: result.shelfVersion, actual: currentShelf.version
                    )
                }
                try await PlacementRepository.confirm(
                    reservation: reservation, result: result, package: packageProfile
                )
                guard let shelf = try await PlacementRepository.fetchShelf(id: result.shelfID) else {
                    throw PlacementPersistenceError.shelfMissing
                }
                replaceOperationalShelf(shelf)
                placementReservation = nil
                reservedPackageProfile = nil
                preciseCalculation = nil
                selectedPrecisePlacement = nil
                verification = nil
                placementStatusMessage = "Placement confirmed. Occupancy and storage version \(shelf.version) are now current."
                isPersistingPlacement = false
            } catch {
                placementStatusMessage = error.localizedDescription
                isPersistingPlacement = false
            }
        }
    }

    private func cancelReservation() {
        guard let reservation = placementReservation else { return }
        isPersistingPlacement = true
        Task { @MainActor in
            do {
                try await PlacementRepository.cancel(reservation)
                placementReservation = nil
                reservedPackageProfile = nil
                selectedPrecisePlacement = nil
                preciseCalculation = nil
                verification = nil
                placementStatusMessage = "Reservation cancelled."
            } catch {
                placementStatusMessage = error.localizedDescription
            }
            isPersistingPlacement = false
        }
    }

    private func selectProduct(barcode: String) {
        selectedProduct = store.products.first {
            $0.barcode == barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let scan = selectedProduct?.objectScan {
            width = String(scan.rawWidth)
            height = String(scan.rawHeight)
            depth = String(scan.rawLength)
        } else {
            // Never carry another product's dimensions into this calculation.
            width = ""
            height = ""
            depth = ""
        }
        if let savedWeight = selectedProduct?.placementMetadata?.weightKG {
            weight = String(savedWeight)
        } else {
            weight = ""
        }
        velocity = selectedProduct?.placementMetadata?.expectedRetrievalFrequency ?? velocity
        verification = nil
        preciseCalculation = nil
        selectedPrecisePlacement = nil
    }

    private var verificationTitle: String {
        switch verification?.stage {
        case .scanLocation: return "Scan Location"
        default: return "Scan Product"
        }
    }

    private func acceptVerificationScan(_ value: String) {
        verification?.accept(value)
    }
}

private struct SpaceVolumePreview: View {
    let space: ScannedSpaceGeometry

    var body: some View {
        Canvas { context, size in
            let points = space.approvedBoundary2D.map(\.simd)
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
            let scale = min((size.width - 52) / max(maxX - minX, 1),
                            (size.height - 52) / max(maxY - minY, 1))
            let lift = CGPoint(x: 18, y: -22)
            func projected(_ point: SIMD2<Double>, top: Bool) -> CGPoint {
                CGPoint(x: 16 + (point.x - minX) * scale + (top ? lift.x : 0),
                        y: size.height - 16 - (point.y - minY) * scale + (top ? lift.y : 0))
            }
            func path(top: Bool) -> Path {
                var value = Path()
                value.move(to: projected(points[0], top: top))
                for point in points.dropFirst() { value.addLine(to: projected(point, top: top)) }
                value.closeSubpath()
                return value
            }
            context.fill(path(top: false), with: .color(.blue.opacity(0.16)))
            context.stroke(path(top: false), with: .color(.blue), lineWidth: 2)
            context.stroke(path(top: true), with: .color(.green), lineWidth: 2)
            for point in points {
                var wall = Path()
                wall.move(to: projected(point, top: false))
                wall.addLine(to: projected(point, top: true))
                context.stroke(wall, with: .color(.secondary), style: .init(lineWidth: 1, dash: [4, 3]))
            }
            for excluded in space.excludedRegions2D where excluded.count >= 3 {
                var hole = Path()
                hole.move(to: projected(excluded[0].simd, top: false))
                for point in excluded.dropFirst() { hole.addLine(to: projected(point.simd, top: false)) }
                hole.closeSubpath()
                context.fill(hole, with: .color(.red.opacity(0.3)))
                context.stroke(hole, with: .color(.red), lineWidth: 2)
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topLeading) {
            Text("3D volume review")
                .font(.caption.weight(.semibold))
                .padding(8)
        }
    }
}
