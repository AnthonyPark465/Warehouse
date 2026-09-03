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
    @State private var scanGeometryType: StorageGeometryType = .shelf
    @State private var spaceSurfaceType: SpaceSurfaceType = .unknown
    @State private var scannedOpenSpace: ScannedSpaceGeometry?
    @State private var spaceSaveMessage: String?
    @State private var measuredSurfaces: [MeasuredShelfSurface] = []
    @State private var assumedHeight = "40"
    @State private var mappedPointCount = 0
    @State private var lidarResetToken = 0
    @State private var shelfPlacementRequestID = 0
    @State private var shelfUndoRequestID = 0
    @State private var shelfFrontRequestID = 0
    @State private var shelfReverseFrontRequestID = 0
    @State private var shelfReplaceCornerRequestID = 0
    @State private var selectedShelfCorner = 0
    @State private var shelfCanPlacePoint = false
    @State private var shelfMeasurementStage: ShelfMeasurementStage = .boundary
    @State private var shelfPointStability: ShelfPointStability = .searching
    @State private var shelfPointGuidance = "Move the reticle onto a visible shelf corner."
    @State private var cornerTelemetry = CornerMeasurementTelemetry()
    @State private var borderScanSnapshot = BorderScanSnapshot()
    @State private var borderPauseRequestID = 0
    @State private var borderFinishRequestID = 0
    @State private var borderConfirmCornerRequestID = 0
    @State private var borderContinueEdgeRequestID = 0
    @State private var borderRescanEdgeRequestID = 0
    @State private var showBorderScanHelp = false
    @State private var isManualBorderCorrection = false
    @State private var openSpaceScanState: OpenSpaceScanState = .idle
    @State private var shelfShapeIntent: ShelfShapeIntent = .automatic
    @State private var shelfBoundaryMeaning: ShelfBoundaryMeaning = .innerUsable
    @State private var expectedShelfWidth = ""
    @State private var expectedShelfDepth = ""
    @State private var shelfReviewError: String?
    @State private var verification: PlacementVerification?
    @State private var showVerificationScanner = false
    @State private var preciseCalculation: PlacementCalculation?
    @State private var selectedPrecisePlacement: ProductPlacementResult?
    @State private var isCalculating = false
    @State private var markerStage: StorageMarkerStage = .selectSurface
    @State private var markerDraft: StorageMarkerDraft?
    @State private var markerCount = 0
    @State private var markerCanPlace = false
    @State private var markerGuidance = "Aim at the horizontal surface where products will sit."
    @State private var markerError: String?
    @State private var markerPlacementRequestID = 0
    @State private var markerUndoRequestID = 0
    @State private var markerResetRequestID = 0
    @State private var markerPreviewRequestID = 0
    @State private var markerUseCorrectedFootprint = true
    @State private var operationalShelves: [ShelfState] = []
    @State private var selectedShelfID = ""
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
            .onChange(of: measuredSurfaces) { _, surfaces in
                guard let measuredHeight = surfaces.first?.measuredFreeHeightCM else { return }
                assumedHeight = String((measuredHeight * 10).rounded() / 10)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background, showSurfaceScanner else { return }
                markerError = "The AR session was interrupted. Restart the measurement so markers do not mix coordinate systems."
                markerDraft = nil
                markerStage = .selectSurface
                markerCount = 0
                showSurfaceScanner = false
                if measuredSurfaces.first?.geometry?.isApproved != true {
                    shelfMeasurementStage = .boundary
                    shelfCanPlacePoint = false
                }
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
            if Double(weight).map({ !$0.isFinite || $0 <= 0 }) ?? true {
                Text("A finite positive weight is required for automatic placement.")
                    .font(.caption)
                    .foregroundStyle(.orange)
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
                Picker("Saved storage area", selection: $selectedShelfID) {
                    ForEach(operationalShelves) { shelf in
                        Text(shelf.label).tag(shelf.id)
                    }
                }
                .disabled(placementReservation != nil)
            }
            Button {
                scanGeometryType = .openSpace
                prepareNewMarkerScan()
                showSurfaceScanner = true
            } label: {
                Label("Measure storage space", systemImage: "scope")
            }
            Picker("Storage surface", selection: $spaceSurfaceType) {
                ForEach(SpaceSurfaceType.allCases) { Text($0.title).tag($0) }
            }
            if let surface = measuredSurfaces.first {
                LabeledContent(
                    "Shelf footprint (X × Z)",
                    value: "\(format(surface.widthCM)) × \(format(surface.depthCM)) cm"
                )
                if let measuredHeight = surface.measuredFreeHeightCM {
                    LabeledContent(
                        "Detected clear height (Y)",
                        value: "\(format(measuredHeight)) cm · measured"
                    )
                }
                dimensionField("Usable clear height", text: $assumedHeight)
                if surface.measuredFreeHeightCM == nil {
                    Text("No shelf was detected above the scanned surface — enter the clear height manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The LiDAR result is filled in automatically. You can replace it with a verified shelf clearance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let space = scannedOpenSpace {
                SpaceVolumePreview(space: space)
                    .frame(height: 190)
                    .accessibilityLabel("Three dimensional preview of the approved \(space.surfaceType.title) storage volume")
                LabeledContent("Space type", value: space.surfaceType.title)
                LabeledContent("Height", value: "\(format(space.heightCM)) cm")
                LabeledContent("Geometry confidence", value: space.confidence.overall.formatted(.percent.precision(.fractionLength(0))))
                Button("Save approved space") {
                    Task { @MainActor in
                        do {
                            try await SpaceRepository.save(space, expectedVersion: nil)
                            let shelf = try await PlacementRepository.initializeOperationalShelf(from: space)
                            await loadOperationalShelves(selecting: shelf.id)
                            spaceSaveMessage = "Space saved and operational occupancy initialized."
                        } catch {
                            spaceSaveMessage = error.localizedDescription
                        }
                    }
                }
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
                .disabled(packageProfile == nil || selectedShelfID.isEmpty || isCalculating || placementReservation != nil)
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
                            Text(entry.shelf.label)
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
                placementStatusMessage = "Removed \(placedProductName(placement.productID)) from \(shelf.label)."
            } catch {
                placementStatusMessage = error.localizedDescription
            }
            isPersistingPlacement = false
        }
    }

    private var verificationSection: some View {
        Section("6 · Verify placement") {
            if let destination = selectedPrecisePlacement == nil ? nil : activePlacementState?.label {
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
                        calculatePrecisePlacement()
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

    private var legacySurfaceScanner: some View {
        NavigationStack {
            ZStack {
                if LiDARSurfaceScannerView.isSupported {
                    LiDARSurfaceScannerView(
                        measuredSurfaces: $measuredSurfaces,
                        mappedPointCount: $mappedPointCount,
                        canPlacePoint: $shelfCanPlacePoint,
                        measurementStage: $shelfMeasurementStage,
                        pointStability: $shelfPointStability,
                        pointGuidance: $shelfPointGuidance,
                        cornerTelemetry: $cornerTelemetry,
                        borderScanSnapshot: $borderScanSnapshot,
                        manualBorderCorrection: $isManualBorderCorrection,
                        geometryType: scanGeometryType,
                        surfaceType: spaceSurfaceType,
                        resetToken: lidarResetToken,
                        placementRequestID: shelfPlacementRequestID,
                        undoRequestID: shelfUndoRequestID,
                        frontRequestID: shelfFrontRequestID,
                        reverseFrontRequestID: shelfReverseFrontRequestID,
                        replaceCornerRequestID: shelfReplaceCornerRequestID,
                        borderPauseRequestID: borderPauseRequestID,
                        borderFinishRequestID: borderFinishRequestID,
                        borderConfirmCornerRequestID: borderConfirmCornerRequestID,
                        borderContinueEdgeRequestID: borderContinueEdgeRequestID,
                        borderRescanEdgeRequestID: borderRescanEdgeRequestID,
                        replacementCornerIndex: selectedShelfCorner,
                        guidanceResult: selectedPrecisePlacement ?? preciseCalculation?.recommendation
                    )
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView(
                        "AR measurement unavailable",
                        systemImage: "viewfinder",
                        description: Text("Use a device that supports AR world tracking.")
                    )
                }
                if scanGeometryType == .openSpace,
                   shelfMeasurementStage == .boundary,
                   !isManualBorderCorrection {
                    compactBorderScanOverlay
                }
                VStack {
                    Spacer()
                    VStack(spacing: 8) {
                        if let surface = measuredSurfaces.first {
                            Label("\(mappedPointCount)-point area mapped", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.white)
                            Text(surfaceSummary(for: surface))
                                .font(.headline.monospacedDigit())
                        } else {
                            Label(
                                mappedPointCount == 0
                                    ? "Aim at the first \(scanGeometryType == .shelf ? "shelf" : "space") corner"
                                    : (mappedPointCount < 3
                                        ? "Add at least \(3 - mappedPointCount) more point\(mappedPointCount == 2 ? "" : "s")"
                                        : "Boundary is invalid — reset and mark the shelf corners in order"),
                                systemImage: "smallcircle.filled.circle"
                            )
                        }
                        Text(shelfMeasurementStage == .boundary
                            ? shelfPointGuidance
                            : shelfScannerInstruction)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if shelfMeasurementStage == .boundary {
                            LabeledContent("Current corner", value: "#\(mappedPointCount + 1)")
                            Label(
                                shelfPointStability.rawValue,
                                systemImage: shelfPointStability == .ready
                                    ? "checkmark.circle.fill"
                                    : "scope"
                            )
                            .foregroundStyle(shelfPointStability == .ready ? .green : .orange)
                            HStack(spacing: 12) {
                                Label(cornerTelemetry.tracking.rawValue.capitalized, systemImage: "location.fill.viewfinder")
                                Text("Samples \(cornerTelemetry.sampleCount)")
                                if let distance = cornerTelemetry.distanceMetres {
                                    Text("\(format(distance)) m")
                                }
                            }
                            .font(.caption2.monospacedDigit())
                            if let difference = cornerTelemetry.surfaceHeightDifferenceMetres {
                                Text("Surface height difference \(format(difference * 100)) cm · \(cornerTelemetry.source.rawValue)")
                                    .font(.caption2.monospacedDigit())
                            }
                            if !LiDARSurfaceScannerView.hasLiDAR {
                                Text("LiDAR is unavailable. More stable samples are required; verify the final dimensions manually.")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        if scanGeometryType == .openSpace, shelfMeasurementStage == .bottom {
                            Picker("Surface", selection: $spaceSurfaceType) {
                                ForEach(SpaceSurfaceType.allCases) { Text($0.title).tag($0) }
                            }
                            TextField("Maximum storage height (cm)", text: $assumedHeight)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                            Button("Use Manual Height") {
                                if validManualSpaceHeight != nil {
                                    shelfMeasurementStage = .frontSelection
                                } else {
                                    shelfReviewError = "Enter a height greater than 1 cm and no more than 5000 cm."
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            Text("Or use Set Bottom and Set Top below to measure a physical upper surface.")
                                .font(.caption2)
                        }
                        if [.boundary, .bottom, .top].contains(shelfMeasurementStage) {
                            Button {
                                shelfPlacementRequestID += 1
                            } label: {
                                Label(shelfPlacementButtonTitle, systemImage: "plus.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!shelfCanPlacePoint)
                        }
                        if shelfMeasurementStage == .review {
                            shelfBoundaryReviewControls
                        }
                        if shelfMeasurementStage == .frontSelection {
                            Button("Set as Shelf Front") { shelfFrontRequestID += 1 }
                                .buttonStyle(.borderedProminent)
                                .disabled(!shelfCanPlacePoint)
                        }
                        if shelfMeasurementStage == .frontConfirmation {
                            HStack {
                                Button("Reverse Direction") { shelfReverseFrontRequestID += 1 }
                                Button("Redefine") { shelfMeasurementStage = .frontSelection }
                            }
                            .buttonStyle(.bordered)
                            Button("Confirm Shelf Front") {
                                shelfMeasurementStage = .complete
                                calculatePrecisePlacement()
                            }
                                .buttonStyle(.borderedProminent)
                        }
                        if shelfMeasurementStage == .boundary,
                           mappedPointCount >= 3,
                           !measuredSurfaces.isEmpty {
                            Button("Finish Boundary") {
                                beginBoundaryReview()
                            }
                            .buttonStyle(.borderedProminent)
                        } else if shelfMeasurementStage == .complete {
                            Button("Measure Height Again") {
                                shelfMeasurementStage = .bottom
                            }
                            .buttonStyle(.bordered)
                        }
                        if mappedPointCount > 0 || shelfMeasurementStage != .boundary {
                            Button("Undo Last Marker") {
                                shelfUndoRequestID += 1
                            }
                            .buttonStyle(.bordered)
                        }
                        if mappedPointCount > 0 {
                            Button("Reset points", role: .destructive) {
                                lidarResetToken += 1
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .font(.footnote.weight(.medium))
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding()
                }
                .opacity(scanGeometryType == .openSpace && shelfMeasurementStage == .boundary && !isManualBorderCorrection ? 0 : 1)
                .allowsHitTesting(!(scanGeometryType == .openSpace && shelfMeasurementStage == .boundary && !isManualBorderCorrection))
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSurfaceScanner = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish Scan") {
                        if scanGeometryType == .openSpace { finalizeOpenSpace() }
                        showSurfaceScanner = false
                        calculatePrecisePlacement()
                    }
                        .disabled(
                            shelfMeasurementStage != .complete
                                || (scanGeometryType == .shelf
                                    ? measuredSurfaces.first?.measuredFreeHeightCM == nil
                                    : validManualSpaceHeight == nil && measuredSurfaces.first?.measuredFreeHeightCM == nil)
                                || measuredSurfaces.first?.geometry?.isApproved != true
                        )
                }
            }
            .onChange(of: shelfMeasurementStage) { _, stage in
                guard scanGeometryType == .openSpace else { return }
                openSpaceScanState = switch stage {
                case .boundary:
                    shelfCanPlacePoint
                        ? .cornerReady(index: mappedPointCount)
                        : .measuringCorner(index: mappedPointCount)
                case .review: .reviewingBoundary
                case .bottom, .top: .measuringHeight
                case .frontSelection, .frontConfirmation: .selectingAccessDirection
                case .complete: .previewingVolume
                }
                switch stage {
                case .boundary: break // Scanner owns the detailed acquisition states.
                case .review: borderScanSnapshot.state = .reviewingBoundary
                case .bottom, .top: borderScanSnapshot.state = .measuringHeight
                case .frontSelection, .frontConfirmation:
                    borderScanSnapshot.state = .selectingAccessDirection
                case .complete: borderScanSnapshot.state = .previewingVolume
                }
            }
        }
    }

    private var compactBorderScanOverlay: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Button {
                    showBorderScanHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Border scanning help")
            }
            if showBorderScanHelp {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Point broadly at the middle of the requested surface—not at a corner.")
                    Text("Scan only one labelled surface at a time and move slowly between distinct viewpoints.")
                    Text("Corners are calculated from accepted plane intersections; the broad target never places them.")
                }
                .font(.caption)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 330, alignment: .trailing)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(borderConfidenceColor)
                    .frame(width: 9, height: 9)
                Text(borderScanSnapshot.status)
                    .lineLimit(2)
                Text(borderScanSnapshot.confidenceLevel.rawValue.capitalized)
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())

            if borderScanSnapshot.surfaceFirstState == .scanningSurface {
                ProgressView(value: borderScanSnapshot.scanProgress)
                    .frame(maxWidth: 280)
                Text("Collecting independent, confidence-filtered depth views…")
                    .font(.caption2)
            }

            if let candidate = borderScanSnapshot.surfaceCandidate {
                VStack(spacing: 6) {
                    Text("Fitted \(candidate.surface.scanTitle) surface")
                        .font(.caption.weight(.semibold))
                    Text("Uncertainty ±\(format(candidate.fittedPlane.uncertaintyMetres * 100)) cm · \(candidate.independentViewCount) independent views · RMS \(format(candidate.fittedPlane.rmsResidualMetres * 100)) cm · coverage \(format(candidate.coverageFirstAxisMetres * 100)) × \(format(candidate.coverageSecondAxisMetres * 100)) cm")
                        .font(.caption2.monospacedDigit())
                    HStack(spacing: 10) {
                        Button("Accept Surface") { borderConfirmCornerRequestID += 1 }
                            .buttonStyle(.borderedProminent)
                        Button("Rescan") { borderRescanEdgeRequestID += 1 }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            } else {
                Button {
                    shelfPlacementRequestID += 1
                } label: {
                    Label(
                        borderScanSnapshot.targetVolume == nil
                            ? "Confirm Target Region"
                            : "Scan \((borderScanSnapshot.activeSurface ?? .bottom).scanTitle.capitalized)",
                        systemImage: "viewfinder.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!shelfCanPlacePoint || borderScanSnapshot.lastError == .inconsistentCoordinateSystem)
            }

            if !borderScanSnapshot.acceptedSurfaces.isEmpty {
                Text("Accepted: \(borderScanSnapshot.acceptedSurfaces.map { $0.scanTitle }.joined(separator: ", "))")
                    .font(.caption2)
            }
            if let dimensions = borderScanSnapshot.compartmentDimensions {
                Text("Interior \(format(dimensions.interiorWidthMetres * 100)) × \(format(dimensions.interiorDepthMetres * 100)) × \(dimensions.interiorHeightMetres.map { format($0 * 100) } ?? "—") cm · opening \(dimensions.hasVerifiedUsableOpening ? "verified" : "not verified")")
                    .font(.caption2.monospacedDigit())
                if borderScanSnapshot.surfaceFirstState == .reviewingGeometry,
                   !dimensions.hasVerifiedUsableOpening {
                    Button("Confirm No Lip, Track, or Smaller Frame") {
                        borderContinueEdgeRequestID += 1
                    }
                    .buttonStyle(.bordered)
                    Text("Do not confirm this if any passage restriction is present; measure the smaller opening instead.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 10) {
                Button("Rescan All", role: .destructive) { lidarResetToken += 1 }
                    .disabled(borderScanSnapshot.acceptedSurfaces.isEmpty)
                Button("Calculate Geometry") { borderFinishRequestID += 1 }
                    .disabled(borderScanSnapshot.surfaceFirstState != .reviewingGeometry)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if borderScanSnapshot.lastError != .inconsistentCoordinateSystem {
                Button("Use Lower-Confidence Manual Corner Placement") {
                    isManualBorderCorrection = true
                    shelfPointGuidance = "Manual fallback: hold still for multi-frame sampling, place corners in order, and verify every final dimension."
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
    }

    private var borderConfidenceColor: Color {
        switch borderScanSnapshot.confidenceLevel {
        case .high: .green
        case .medium: .yellow
        case .low: .orange
        case .invalid: .gray
        }
    }

    private var shelfScannerInstruction: String {
        switch shelfMeasurementStage {
        case .boundary:
            "Aim around the usable \(scanGeometryType == .shelf ? "shelf" : "space") surface and place points in boundary order. Hold still until Ready to place."
        case .review:
            "Compare the measured and suggested shapes. No correction is used until you approve it."
        case .bottom:
            "Aim the centre target at the bottom shelf level, then press Set Bottom."
        case .top:
            "Aim at the visible underside of the shelf above, then press Set Top. Horizontal offset will not increase the height."
        case .frontSelection:
            "Stand at the main access side, aim into the usable area, then set the access direction."
        case .frontConfirmation:
            "Check the yellow arrow points from the opening toward the back. Reverse or redefine it if needed, then confirm."
        case .complete:
            "Boundary, height, and shelf front are confirmed. Finish Scan is now available."
        }
    }

    private var shelfPlacementButtonTitle: String {
        switch shelfMeasurementStage {
        case .boundary: scanGeometryType == .openSpace ? "Place Corner" : "Place Point"
        case .review: "Review Boundary"
        case .bottom: "Set Bottom"
        case .top: "Set Top"
        case .frontSelection: "Set as Shelf Front"
        case .frontConfirmation: "Confirm Shelf Front"
        case .complete: "Height Complete"
        }
    }

    @ViewBuilder
    private var shelfBoundaryReviewControls: some View {
        if let analysis = measuredSurfaces.first?.boundaryAnalysis {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Shelf shape", selection: $shelfShapeIntent) {
                        ForEach(ShelfShapeIntent.allCases) { intent in
                            Text(intent.title).tag(intent)
                        }
                    }
                    .onChange(of: shelfShapeIntent) { refreshBoundaryAnalysis() }
                    Picker("Boundary represents", selection: $shelfBoundaryMeaning) {
                        ForEach(ShelfBoundaryMeaning.allCases) { meaning in
                            Text(meaning.title).tag(meaning)
                        }
                    }
                    HStack {
                        TextField("Expected width cm", text: $expectedShelfWidth)
                            .keyboardType(.decimalPad)
                        TextField("Expected depth cm", text: $expectedShelfDepth)
                            .keyboardType(.decimalPad)
                        Button("Compare") { refreshBoundaryAnalysis() }
                    }
                    ShelfBoundaryComparisonView(analysis: analysis)
                        .frame(height: 150)
                    measurementComparison(analysis)
                    if let border = measuredSurfaces.first?.scannedBoundary {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Raw observations: \(border.rawTrace.count)")
                            Text("Detected segments: \(border.detectedSegments.count) · corners: \(border.detectedCorners.count)")
                            Text("Border confidence: \(border.geometryConfidence.formatted(.percent.precision(.fractionLength(0))))")
                            Text("Simplification displacement: max \(format(border.processingMetrics.maximumSimplificationDisplacementMetres * 100)) cm · average \(format(border.processingMetrics.averageSimplificationDisplacementMetres * 100)) cm")
                            Text("Validation: \(border.validationState.rawValue)")
                        }
                        .font(.caption.monospacedDigit())
                        accuracyFirstDiagnostics(border: border, analysis: analysis)
                    }
                    if let error = shelfReviewError ?? analysis.recoveryMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    ForEach(analysis.correctionReasons, id: \.self) { reason in
                        Text("• \(reason.explanation)")
                            .font(.caption2)
                    }
                    HStack {
                        Button(scanGeometryType == .openSpace ? "Keep Detected Shape" : "Keep Original Shape") {
                            approveBoundary(useSuggestion: false)
                        }
                            .disabled(
                                analysis.scanConfidence < 0.45
                                    || (measuredSurfaces.first?.scannedBoundary?.geometryConfidence ?? 1) < 0.55
                            )
                        Button("Accept Suggested Correction") {
                            approveBoundary(useSuggestion: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            analysis.suggestedBoundary == nil || analysis.requiresRescan
                                || (measuredSurfaces.first?.scannedBoundary?.geometryConfidence ?? 1) < 0.55
                        )
                    }
                    HStack {
                        if !analysis.normalizedRawBoundary.isEmpty {
                            Picker("Corner", selection: $selectedShelfCorner) {
                                ForEach(analysis.normalizedRawBoundary.indices, id: \.self) {
                                    Text("Corner \($0 + 1)").tag($0)
                                }
                            }
                            Button("Rescan Selected Corner") {
                                isManualBorderCorrection = false
                                shelfReplaceCornerRequestID += 1
                                shelfMeasurementStage = .boundary
                            }
                        }
                        Button("Rescan Boundary", role: .destructive) {
                            lidarResetToken += 1
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxHeight: 390)
        } else {
            Label(
                shelfReviewError ?? "The boundary is not valid enough to review. Rescan it.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            Button("Rescan Boundary", role: .destructive) { lidarResetToken += 1 }
        }
    }

    private func measurementComparison(_ analysis: ShelfBoundaryAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Measured: \(format(analysis.rawDimensions.widthMetres * 100)) × \(format(analysis.rawDimensions.depthMetres * 100)) cm")
            if let corrected = analysis.suggestedDimensions {
                Text("Suggested: \(format(corrected.widthMetres * 100)) × \(format(corrected.depthMetres * 100)) cm")
            }
            Text("Raw angles: \(analysis.rawCornerAnglesDegrees.map { format($0) + "°" }.joined(separator: ", "))")
            Text("Rectangle confidence: \(analysis.rectangleConfidence.formatted(.percent.precision(.fractionLength(0))))")
            Text("Scan confidence: \(analysis.scanConfidence.formatted(.percent.precision(.fractionLength(0))))")
            Text("Maximum corner movement: \(format(analysis.maximumPointMovementMetres * 100)) cm")
#if DEBUG
            DisclosureGroup("Geometry diagnostics") {
                Text("Plane normal: [\(format(analysis.planeNormal.x)), \(format(analysis.planeNormal.y)), \(format(analysis.planeNormal.z))]")
                Text("Plane RMS / max: \(format(analysis.planeRMSResidualMetres * 100)) / \(format(analysis.planeMaximumResidualMetres * 100)) cm")
                Text("Input revision: \(analysis.inputRevision.uuidString)")
            }
#endif
        }
        .font(.caption.monospacedDigit())
    }

    @ViewBuilder
    private func accuracyFirstDiagnostics(
        border: ScannedStorageBoundary,
        analysis: ShelfBoundaryAnalysis
    ) -> some View {
        if border.schemaVersion >= 5 {
            VStack(alignment: .leading, spacing: 4) {
                Text("Accuracy evidence")
                    .font(.caption.weight(.semibold))
                if let sections = border.acquisitionSections {
                    ForEach(sections) { section in
                        let residual = section.fittedLine?.rmsResidualMetres ?? 0
                        let uncertainty = section.fittedLine?.uncertaintyMetres ?? 0
                        Text(
                            "Edge \(section.index + 1): \(section.evidenceState.rawValue) · "
                                + "RMS \(format(residual * 100)) cm · ±\(format(uncertainty * 100)) cm"
                        )
                    }
                }
                if let worst = border.dimensionUncertainties?.max(by: {
                    $0.estimatedUncertaintyMetres < $1.estimatedUncertaintyMetres
                }) {
                    let width = ConservativeDimensionCalculator.calculate(
                        measuredMetres: analysis.rawDimensions.widthMetres,
                        uncertaintyMetres: worst.estimatedUncertaintyMetres,
                        clearancePerSideMetres: [0.005, 0.005]
                    )
                    let depth = ConservativeDimensionCalculator.calculate(
                        measuredMetres: analysis.rawDimensions.depthMetres,
                        uncertaintyMetres: worst.estimatedUncertaintyMetres,
                        clearancePerSideMetres: [0.005, 0.005]
                    )
                    Text("Estimated uncertainty: ±\(format(worst.estimatedUncertaintyMetres * 100)) cm")
                    Text("Conservative usable: \(format(width.conservativeUsableMetres * 100)) × \(format(depth.conservativeUsableMetres * 100)) cm")
                    Text("Operational clearance: 0.5 cm per side (kept separate from uncertainty)")
                }
            }
            .font(.caption2.monospacedDigit())
        }
    }

    private func beginBoundaryReview() {
        isManualBorderCorrection = false
        refreshBoundaryAnalysis()
        if measuredSurfaces.first?.boundaryAnalysis != nil {
            shelfMeasurementStage = .review
        }
    }

    private func refreshBoundaryAnalysis() {
        guard let surface = measuredSurfaces.first,
              let raw = surface.boundaryAnalysis?.rawBoundary
        else {
            shelfReviewError = "At least three valid, non-crossing points are required."
            return
        }
        do {
            let analysis = try ShelfBoundaryAnalyzer.analyze(
                points: raw,
                cornerConfidence: surface.cornerMetadata.map {
                    max(0, 1 - $0.spreadMetres / 0.012)
                },
                intent: shelfShapeIntent,
                expectedWidthCM: expectedShelfWidth.isEmpty
                    ? nil : Double(expectedShelfWidth),
                expectedDepthCM: expectedShelfDepth.isEmpty
                    ? nil : Double(expectedShelfDepth)
            )
            let draft = ShelfBoundaryAnalyzer.geometryRecord(
                from: analysis,
                approvedBoundary: [],
                approval: .draft,
                intent: shelfShapeIntent,
                meaning: shelfBoundaryMeaning,
                cornerMetadata: surface.cornerMetadata,
                expectedWidthCM: expectedShelfWidth.isEmpty
                    ? nil : Double(expectedShelfWidth),
                expectedDepthCM: expectedShelfDepth.isEmpty
                    ? nil : Double(expectedShelfDepth),
                deviceModel: ObjectScannerCapabilities.deviceModelIdentifier,
                hasLiDAR: LiDARSurfaceScannerView.hasLiDAR
            )
            measuredSurfaces = [surface.replacing(
                widthCM: analysis.rawDimensions.widthMetres * 100,
                depthCM: analysis.rawDimensions.depthMetres * 100,
                geometry: draft,
                analysis: analysis
            )]
            shelfReviewError = nil
        } catch {
            shelfReviewError = error.localizedDescription
        }
    }

    private func approveBoundary(useSuggestion: Bool) {
        guard let surface = measuredSurfaces.first,
              let analysis = surface.boundaryAnalysis,
              (surface.scannedBoundary?.geometryConfidence ?? 1) >= 0.55 else { return }
        if let diagnostics = surface.scannedBoundary?.dimensionUncertainties,
           let failure = diagnostics.map({ MeasurementAccuracyPolicy.evaluate($0, fitCritical: false) })
            .first(where: { $0.use == .rejected || $0.use == .manualOnly }) {
            shelfReviewError = failure.reason
            return
        }
        let approved: [SIMD3<Double>]
        let approval: ShelfGeometryApproval
        if useSuggestion {
            guard let suggestion = analysis.suggestedBoundary,
                  !analysis.requiresRescan else { return }
            approved = suggestion
            approval = .approvedCorrection
        } else {
            guard analysis.scanConfidence >= 0.45 else { return }
            approved = analysis.normalizedRawBoundary
            approval = .approvedRaw
        }
        let record = ShelfBoundaryAnalyzer.geometryRecord(
            from: analysis,
            approvedBoundary: approved,
            approval: approval,
            intent: shelfShapeIntent,
            meaning: shelfBoundaryMeaning,
            cornerMetadata: surface.cornerMetadata,
            expectedWidthCM: expectedShelfWidth.isEmpty ? nil : Double(expectedShelfWidth),
            expectedDepthCM: expectedShelfDepth.isEmpty ? nil : Double(expectedShelfDepth),
            deviceModel: ObjectScannerCapabilities.deviceModelIdentifier,
            hasLiDAR: LiDARSurfaceScannerView.hasLiDAR
        )
        let dimensions = useSuggestion
            ? analysis.suggestedDimensions ?? analysis.rawDimensions
            : analysis.rawDimensions
        var approvedSurface = surface.replacing(
            widthCM: dimensions.widthMetres * 100,
            depthCM: dimensions.depthMetres * 100,
            geometry: record,
            analysis: analysis
        )
        if var border = approvedSurface.scannedBoundary {
            border.approvedPolygon = approved.map { Vector2D($0.x, $0.z) }
            border.suggestedPolygon = analysis.suggestedBoundary?.map { Vector2D($0.x, $0.z) }
            border.approvalState = useSuggestion ? .approvedCorrected : .approvedRaw
            border.updatedAt = .now
            approvedSurface = approvedSurface.replacingScannedBoundary(border)
        }
        measuredSurfaces = [approvedSurface]
        shelfMeasurementStage = .bottom
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func dimensionField(_ label: String, text: Binding<String>) -> some View {
        TextField("\(label) (cm)", text: text)
            .keyboardType(.decimalPad)
    }

    private func surfaceSummary(for surface: MeasuredShelfSurface) -> String {
        let width = format(surface.widthCM)
        let depth = format(surface.depthCM)
        guard let height = surface.measuredFreeHeightCM else {
            return "\(width) cm wide × \(depth) cm deep"
        }
        let clear = format(height)
        return "\(width) cm wide × \(depth) cm deep × \(clear) cm clear"
    }

    private var packageProfile: PackagePlacementProfile? {
        guard let product = selectedProduct,
              let width = Double(width), width > 0,
              let height = Double(height), height > 0,
              let depth = Double(depth), depth > 0,
              let weight = Double(weight), weight > 0
        else { return nil }
        var metadata = product.placementMetadata ?? .conservative
        metadata.weightKG = metadata.weightKG ?? weight
        if product.placementMetadata == nil, product.objectScan?.canBeRotated == true {
            metadata.mayRotateAutomatically = true
            metadata.mustRemainUpright = false
            metadata.permittedRestingFaces = Set(RestingFace.allCases)
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
            } else if let result = selectedPrecisePlacement ?? preciseCalculation?.recommendation,
                      let shelf = scannedShelfState {
                ShelfPlacementDiagram(shelf: shelf, result: result)
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
                Text(result.instructions)
                    .font(.callout)
                LabeledContent("Confidence", value: result.confidence.formatted(.percent.precision(.fractionLength(0))))
                LabeledContent("Clearance from front", value: "\(result.position.z.formatted(.number.precision(.fractionLength(0)))) cm")
                if let orientation = result.orientation {
                    LabeledContent("Resting face", value: orientation.restingFace.rawValue.capitalized)
                    LabeledContent("Forward-facing face", value: orientation.forwardFace.rawValue.capitalized)
                } else {
                    LabeledContent("Legacy yaw", value: "\(result.quarterTurns * 90)° clockwise")
                }
                if let support = result.supportingProductIDs.first {
                    LabeledContent("Supporting product", value: support)
                }
                ForEach(result.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Use Recommendation") { selectPrecise(result) }
                }
            } else if let message = preciseCalculation?.failureMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Rescan shelf") { showSurfaceScanner = true }
            } else {
                Text("Complete the product and shelf scan to calculate a precise shelf-local placement.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scannedShelfState: ShelfState? {
        guard let surface = measuredSurfaces.first,
              let height = Double(assumedHeight), height > 0,
              let front = surface.frontDirectionLocal,
              let sourceGeometry = surface.geometry,
              sourceGeometry.isApproved,
              let origin = surface.originLocal else { return nil }
        let depthAxis = front.normalized
        let widthAxis = Vector3D(depthAxis.z, 0, -depthAxis.x)
        let geometry = shelfLocalGeometry(
            sourceGeometry,
            origin: origin,
            widthAxis: widthAxis,
            depthAxis: depthAxis
        )
        let footprint = geometry.approvedBoundary
        guard let minX = footprint.map(\.x).min(),
              let maxX = footprint.map(\.x).max(),
              let minZ = footprint.map(\.z).min(),
              let maxZ = footprint.map(\.z).max(),
              maxX > minX, maxZ > minZ
        else { return nil }
        let boundary = AxisAlignedVolume(
            id: "\(surface.id.uuidString)-boundary",
            minimum: Vector3D(minX, 0, minZ),
            dimensions: PackageDimensions(
                widthCM: maxX - minX,
                heightCM: height,
                depthCM: maxZ - minZ
            )
        )
        return ShelfState(
            id: surface.id.uuidString, label: "Current scanned shelf", barcode: "LOC-\(surface.id.uuidString)",
            version: 1, boundary: boundary,
            coordinateSystem: ShelfLocalCoordinateSystem(anchorOrigin: Vector3D(0, 0, 0),
                widthAxis: widthAxis, upAxis: Vector3D(0, 1, 0), depthAxis: depthAxis),
            primaryFrontDirection: Vector3D(0, 0, 1), secondaryAccessDirections: [],
            compartments: [ShelfCompartment(id: "main", label: "main compartment", volume: boundary, ratedWeightKG: nil)],
            obstacles: [], products: [],
            scanQuality: ShelfScanQuality(hasClosedBoundary: surface.boundaryClosed, missingSurfaceCount: 0,
                trackingDriftCM: 0, confidence: surface.scanConfidence, capturedAt: .now),
            geometry: geometry,
            ratedWeightKG: nil, updatedAt: .now
        )
    }

    private var validManualSpaceHeight: Double? {
        guard let value = Double(assumedHeight), value.isFinite,
              value > 1, value <= 5_000 else { return nil }
        return value
    }

    private var activePlacementState: ShelfState? {
        operationalShelves.first { $0.id == selectedShelfID }
    }

    private func prepareNewMarkerScan() {
        scannedOpenSpace = nil
        measuredSurfaces = []
        assumedHeight = ""
        markerDraft = nil
        markerStage = .selectSurface
        markerCount = 0
        markerCanPlace = false
        markerGuidance = "Aim at the horizontal surface where products will sit."
        markerError = nil
        markerUseCorrectedFootprint = true
        markerPlacementRequestID = 0
        markerUndoRequestID = 0
        markerPreviewRequestID = 0
        markerResetRequestID += 1
    }

    private func finalizeMarkerSpace() {
        guard let draft = markerDraft, let height = validManualSpaceHeight else {
            markerError = "The footprint or storage height is incomplete."
            return
        }
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

    private func prepareNewGeometryScan() {
        measuredSurfaces = []
        scannedOpenSpace = nil
        mappedPointCount = 0
        shelfMeasurementStage = .boundary
        shelfReviewError = nil
        cornerTelemetry = .init()
        borderScanSnapshot = BorderScanSnapshot(
            state: .checkingDeviceSupport,
            status: "Checking device"
        )
        borderPauseRequestID = 0
        borderFinishRequestID = 0
        borderConfirmCornerRequestID = 0
        borderContinueEdgeRequestID = 0
        borderRescanEdgeRequestID = 0
        showBorderScanHelp = false
        isManualBorderCorrection = false
        openSpaceScanState = scanGeometryType == .openSpace
            ? .initializingSession : .idle
        lidarResetToken += 1
    }

    private func finalizeOpenSpace() {
        guard let surface = measuredSurfaces.first,
              let source = surface.geometry, source.isApproved,
              let origin = surface.originLocal,
              let front = surface.frontDirectionLocal,
              let height = surface.measuredFreeHeightCM ?? validManualSpaceHeight else { return }
        let depthAxis = front.normalized
        let widthAxis = Vector3D(depthAxis.z, 0, -depthAxis.x)
        let local = shelfLocalGeometry(source, origin: origin, widthAxis: widthAxis, depthAxis: depthAxis)
        let confidence = SpaceConfidence(
            baseSurface: surface.scanConfidence,
            boundary: source.correctionConfidence,
            corners: source.scanConfidence,
            walls: nil,
            surfaceEdges: LiDARSurfaceScannerView.hasLiDAR ? surface.scanConfidence : nil,
            height: surface.measuredFreeHeightCM == nil ? 0.8 : surface.scanConfidence
        )
        scannedOpenSpace = ScannedSpaceGeometry(
            id: surface.id, geometryType: .openSpace, surfaceType: spaceSurfaceType,
            rawBoundary2D: local.rawBoundary.map { Vector2D($0.x, $0.z) },
            suggestedBoundary2D: local.correctedBoundary?.map { Vector2D($0.x, $0.z) },
            approvedBoundary2D: local.approvedBoundary.map { Vector2D($0.x, $0.z) },
            excludedRegions2D: [], localOrigin: origin,
            localXAxis: widthAxis, localYAxis: depthAxis,
            localVerticalAxis: Vector3D(0, 1, 0),
            bottomPlane: CodablePlane(origin: origin, normal: Vector3D(0, 1, 0)),
            topDefinition: .manualLimitCM(height), heightCM: height,
            accessDirections: [Vector3D(0, 0, 1)], confidence: confidence,
            approval: .approved,
            geometryVersion: surface.scannedBoundary?.schemaVersion ?? 3,
            createdAt: .now, updatedAt: .now,
            measurementMethod: surface.scannedBoundary?.measurementMethod
                ?? (LiDARSurfaceScannerView.hasLiDAR
                    ? .lidarCornerPlacement : .standardARCornerPlacement),
            measuredCorners: surface.measuredSpaceCorners.map { corner in
                var converted = corner
                let point = SIMD3(
                    corner.localBoundaryPositionMetres.x,
                    0,
                    corner.localBoundaryPositionMetres.y
                )
                let delta = point - origin.simd
                converted.localBoundaryPositionMetres = Vector2D(
                    simd_dot(delta, widthAxis.simd),
                    simd_dot(delta, depthAxis.simd)
                )
                return converted
            },
            scannedBoundary: surface.scannedBoundary
        )
        openSpaceScanState = .completed
    }

    private func shelfLocalGeometry(
        _ geometry: ShelfGeometryRecord,
        origin: Vector3D,
        widthAxis: Vector3D,
        depthAxis: Vector3D
    ) -> ShelfGeometryRecord {
        func convert(_ point: Vector3D) -> Vector3D {
            let delta = point.simd - origin.simd
            return Vector3D(
                simd_dot(delta, widthAxis.simd) * 100,
                0,
                simd_dot(delta, depthAxis.simd) * 100
            )
        }
        var result = geometry
        result.rawBoundary = geometry.rawBoundary.map(convert)
        result.correctedBoundary = geometry.correctedBoundary?.map(convert)
        result.approvedBoundary = geometry.approvedBoundary.map(convert)
        result.measurementMetadata.coordinateSpace = .shelfLocal
        result.measurementMetadata.unit = .centimetres
        return result
    }

    private func calculatePrecisePlacement() {
        guard let packageProfile, !selectedShelfID.isEmpty,
              let userID = auth.user?.uid else { return }
        isCalculating = true
        placementStatusMessage = nil
        selectedPrecisePlacement = nil
        Task { @MainActor in
            do {
                guard let shelf = try await PlacementRepository.fetchShelf(id: selectedShelfID) else {
                    throw PlacementPersistenceError.shelfMissing
                }
                if try await PlacementRepository.fetchActiveReservation(shelfID: shelf.id) != nil {
                    throw PlacementPersistenceError.reservationConflict
                }
                let result = await Task.detached(priority: .userInitiated) {
                    PlacementEngine.calculate(package: packageProfile, shelf: shelf)
                }.value
                guard !Task.isCancelled else { return }
                preciseCalculation = result
                guard let recommendation = result.recommendation else {
                    placementStatusMessage = result.failureMessage
                    isCalculating = false
                    return
                }
                let reservation = try await PlacementRepository.reserve(
                    result: recommendation, userID: userID
                )
                placementReservation = reservation
                reservedPackageProfile = packageProfile
                selectedPrecisePlacement = recommendation
                replaceOperationalShelf(shelf)
                placementStatusMessage = "Storage area reserved for two minutes. Verify both barcodes, place the product, then confirm."
                isCalculating = false
            } catch {
                placementStatusMessage = error.localizedDescription
                isCalculating = false
            }
        }
    }

    private func selectPrecise(_ result: ProductPlacementResult) {
        guard let barcode = selectedProduct?.barcode else { return }
        selectedPrecisePlacement = result
        verification = PlacementVerification(
            expectedProductBarcode: barcode,
            expectedLocationBarcode: activePlacementState?.barcode ?? ""
        )
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
        guard verification?.stage == .complete,
              let reservation = placementReservation,
              let result = selectedPrecisePlacement,
              let packageProfile = reservedPackageProfile else { return }
        isPersistingPlacement = true
        Task { @MainActor in
            do {
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

/// Always-visible guidance when AR tracking is unavailable. The top view uses
/// the same shelf-local x/z coordinates as collision and path calculations.
private struct ShelfPlacementDiagram: View {
    let shelf: ShelfState
    let result: ProductPlacementResult

    var body: some View {
        GeometryReader { proxy in
            let width = max(shelf.boundary.dimensions.widthCM, 1)
            let depth = max(shelf.boundary.dimensions.depthCM, 1)
            let scale = min((proxy.size.width - 44) / width, (proxy.size.height - 54) / depth)
            let origin = CGPoint(x: 22, y: 30)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.secondary, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .frame(width: width * scale, height: depth * scale)
                    .position(x: origin.x + width * scale / 2, y: origin.y + depth * scale / 2)
                RoundedRectangle(cornerRadius: 5)
                    .fill(.cyan.opacity(0.25))
                    .stroke(.cyan, lineWidth: 3)
                    .frame(width: result.orientedDimensions.widthCM * scale,
                           height: result.orientedDimensions.depthCM * scale)
                    .position(
                        x: origin.x + (result.position.x + result.orientedDimensions.widthCM / 2) * scale,
                        y: origin.y + (result.position.z + result.orientedDimensions.depthCM / 2) * scale
                    )
                Image(systemName: "arrow.down")
                    .font(.title.bold())
                    .foregroundStyle(.yellow)
                    .position(x: origin.x + width * scale / 2, y: 13)
                Text("SHELF FRONT")
                    .font(.caption2.bold())
                    .position(x: origin.x + width * scale / 2, y: proxy.size.height - 10)
                Text("TARGET")
                    .font(.caption2.bold())
                    .foregroundStyle(.cyan)
                    .position(
                        x: origin.x + (result.position.x + result.orientedDimensions.widthCM / 2) * scale,
                        y: origin.y + (result.position.z + result.orientedDimensions.depthCM / 2) * scale
                    )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Shelf top view. Target is \(result.position.z.formatted()) centimetres behind the shelf front.")
        }
        .background(Color(.secondarySystemBackground))
    }
}

private struct ShelfBoundaryComparisonView: View {
    let analysis: ShelfBoundaryAnalysis

    var body: some View {
        GeometryReader { proxy in
            let raw = analysis.normalizedRawBoundary.map { SIMD2($0.x, $0.z) }
            let suggested = analysis.suggestedBoundary?.map { SIMD2($0.x, $0.z) } ?? []
            let all = raw + suggested
            let minX = all.map(\.x).min() ?? 0
            let maxX = all.map(\.x).max() ?? 1
            let minY = all.map(\.y).min() ?? 0
            let maxY = all.map(\.y).max() ?? 1
            let width = max(maxX - minX, 0.001)
            let height = max(maxY - minY, 0.001)
            let scale = min((proxy.size.width - 24) / width, (proxy.size.height - 24) / height)
            let point: (SIMD2<Double>) -> CGPoint = { value in
                CGPoint(
                    x: 12 + (value.x - minX) * scale,
                    y: proxy.size.height - 12 - (value.y - minY) * scale
                )
            }
            Canvas { context, _ in
                drawPolygon(
                    raw,
                    point: point,
                    context: &context,
                    color: .white,
                    dashed: true
                )
                drawPolygon(
                    suggested,
                    point: point,
                    context: &context,
                    color: .green,
                    dashed: false
                )
                for index in raw.indices {
                    let original = point(raw[index])
                    context.stroke(
                        Path(ellipseIn: CGRect(
                            x: original.x - 4, y: original.y - 4,
                            width: 8, height: 8
                        )),
                        with: .color(.white),
                        lineWidth: 2
                    )
                    if suggested.indices.contains(index) {
                        let corrected = point(suggested[index])
                        var displacement = Path()
                        displacement.move(to: original)
                        displacement.addLine(to: corrected)
                        context.stroke(displacement, with: .color(.yellow), lineWidth: 1)
                        context.fill(
                            Path(ellipseIn: CGRect(
                                x: corrected.x - 4, y: corrected.y - 4,
                                width: 8, height: 8
                            )),
                            with: .color(.green)
                        )
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                Text("Measured — dashed")
                    .font(.caption2)
                    .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                Text("Suggested — solid")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .padding(4)
            }
        }
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func drawPolygon(
        _ points: [SIMD2<Double>],
        point: (SIMD2<Double>) -> CGPoint,
        context: inout GraphicsContext,
        color: Color,
        dashed: Bool
    ) {
        guard let first = points.first else { return }
        var path = Path()
        path.move(to: point(first))
        points.dropFirst().forEach { path.addLine(to: point($0)) }
        path.closeSubpath()
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: 2, dash: dashed ? [6, 4] : [])
        )
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

private extension MeasuredShelfSurface {
    func replacing(
        widthCM: Double? = nil,
        depthCM: Double? = nil,
        geometry: ShelfGeometryRecord? = nil,
        analysis: ShelfBoundaryAnalysis? = nil
    ) -> MeasuredShelfSurface {
        MeasuredShelfSurface(
            id: id,
            widthCM: widthCM ?? self.widthCM,
            depthCM: depthCM ?? self.depthCM,
            measuredFreeHeightCM: measuredFreeHeightCM,
            frontDirectionLocal: frontDirectionLocal,
            originLocal: originLocal,
            scanConfidence: scanConfidence,
            boundaryClosed: boundaryClosed,
            geometry: geometry ?? self.geometry,
            boundaryAnalysis: analysis ?? boundaryAnalysis,
            cornerMetadata: cornerMetadata,
            measuredSpaceCorners: measuredSpaceCorners,
            scannedBoundary: scannedBoundary
        )
    }
}
