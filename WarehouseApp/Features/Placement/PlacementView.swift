import SwiftUI

struct PlacementView: View {
    @Environment(InventoryStore.self) private var store

    @State private var selectedProduct: Product?
    @State private var width = "30"
    @State private var height = "20"
    @State private var depth = "25"
    @State private var weight = "4"
    @State private var velocity = 0.5
    @State private var scale: WarehouseScale = .growing
    @State private var showProductScanner = false
    @State private var showSurfaceScanner = false
    @State private var measuredSurfaces: [MeasuredShelfSurface] = []
    @State private var assumedHeight = "40"
    @State private var mappedPointCount = 0
    @State private var lidarResetToken = 0
    @State private var selectedRecommendation: PlacementRecommendation?
    @State private var verification: PlacementVerification?
    @State private var showVerificationScanner = false

    var body: some View {
        NavigationStack {
            Form {
                productSection
                packageSection
                scanSection
                recommendationsSection
                verificationSection
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
            VStack(alignment: .leading) {
                Text("Pick frequency")
                Slider(value: $velocity, in: 0...1)
            }
            Picker("Business scale", selection: $scale) {
                ForEach(WarehouseScale.allCases) { Text($0.rawValue).tag($0) }
            }
        }
    }

    private var scanSection: some View {
        Section("3 · Shelf capacity") {
            Button {
                showSurfaceScanner = true
            } label: {
                Label("Scan shelf with LiDAR", systemImage: "viewfinder")
            }
            if let surface = measuredSurfaces.first {
                LabeledContent(
                    "Selected surface",
                    value: "\(surface.widthCM.formatted(.number.precision(.fractionLength(0)))) × \(surface.depthCM.formatted(.number.precision(.fractionLength(0)))) cm"
                )
                if let measuredHeight = surface.measuredFreeHeightCM {
                    LabeledContent(
                        "Clear height",
                        value: "\(measuredHeight.formatted(.number.precision(.fractionLength(0)))) cm · measured"
                    )
                } else {
                    dimensionField("Clear height", text: $assumedHeight)
                    Text("No shelf was detected above the scanned surface — enter the clear height manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("LiDAR measures the shelf footprint and the clear height above it. The weight rating still comes from the location master data.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var recommendationsSection: some View {
        Section("4 · Recommended location") {
            if recommendations.isEmpty {
                Text("Scan a product and enter valid dimensions. Locations that fail size or weight checks are excluded.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recommendations.prefix(3)) { recommendation in
                    Button {
                        select(recommendation)
                    } label: {
                        RecommendationRow(
                            recommendation: recommendation,
                            isSelected: selectedRecommendation?.id == recommendation.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var verificationSection: some View {
        Section("5 · Verify placement") {
            if let recommendation = selectedRecommendation {
                LabeledContent("Destination", value: recommendation.location.label)
                switch verification?.stage {
                case .scanProduct:
                    Button("Scan product") { showVerificationScanner = true }
                case .scanLocation:
                    Button("Scan location") { showVerificationScanner = true }
                case .complete:
                    Label("Placement verified", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button("Try again") { verification?.retry() }
                case nil:
                    Text("Select a recommendation first.")
                }
            } else {
                Text("Select a recommended location to start the two-scan check.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var surfaceScanner: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if LiDARSurfaceScannerView.isSupported {
                    LiDARSurfaceScannerView(
                        measuredSurfaces: $measuredSurfaces,
                        mappedPointCount: $mappedPointCount,
                        resetToken: lidarResetToken
                    )
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView(
                        "LiDAR unavailable",
                        systemImage: "viewfinder",
                        description: Text("Use an iPhone Pro model with a LiDAR scanner.")
                    )
                }
                VStack(spacing: 5) {
                    if let surface = measuredSurfaces.first {
                        Label("\(mappedPointCount)-point area mapped", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.white)
                        Text(surfaceSummary(for: surface))
                            .font(.headline.monospacedDigit())
                        if surface.measuredFreeHeightCM == nil {
                            Text("No shelf detected above — enter the clear height after closing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Label(
                            mappedPointCount == 0
                                ? "Tap the shelf to place the first point"
                                : "Add at least \(3 - mappedPointCount) more point\(mappedPointCount == 2 ? "" : "s")",
                            systemImage: "smallcircle.filled.circle"
                        )
                    }
                    Text("Tap around one shelf surface. White lines connect the points and fill the selected area.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Scan") { showSurfaceScanner = false }
                }
            }
        }
    }

    private func dimensionField(_ label: String, text: Binding<String>) -> some View {
        TextField("\(label) (cm)", text: text)
            .keyboardType(.decimalPad)
    }

    private func surfaceSummary(for surface: MeasuredShelfSurface) -> String {
        let width = surface.widthCM.formatted(.number.precision(.fractionLength(0)))
        let depth = surface.depthCM.formatted(.number.precision(.fractionLength(0)))
        guard let height = surface.measuredFreeHeightCM else {
            return "\(width) cm wide × \(depth) cm deep"
        }
        let clear = height.formatted(.number.precision(.fractionLength(0)))
        return "\(width) cm wide × \(depth) cm deep × \(clear) cm clear"
    }

    private var packageProfile: PackagePlacementProfile? {
        guard let product = selectedProduct,
              let width = Double(width), width > 0,
              let height = Double(height), height > 0,
              let depth = Double(depth), depth > 0,
              let weight = Double(weight), weight > 0
        else { return nil }
        return PackagePlacementProfile(
            productId: product.id,
            dimensions: PackageDimensions(widthCM: width, heightCM: height, depthCM: depth),
            weightKG: weight,
            demandVelocity: velocity
        )
    }

    private var recommendations: [PlacementRecommendation] {
        guard let packageProfile else { return [] }
        return PlacementEngine.recommend(
            package: packageProfile,
            locations: candidateLocations,
            scale: scale
        )
    }

    private var candidateLocations: [StorageLocation] {
        var locations = [
            StorageLocation(
                id: "A-01-02", label: "Aisle A · Bay 01 · Shelf 02", barcode: "LOC-A-01-02",
                freeWidthCM: 60, freeHeightCM: 42, freeDepthCM: 50,
                remainingWeightKG: 35, walkingDistanceM: 12, orderAffinity: 0.82, source: .mapped
            ),
            StorageLocation(
                id: "B-03-01", label: "Aisle B · Bay 03 · Shelf 01", barcode: "LOC-B-03-01",
                freeWidthCM: 45, freeHeightCM: 32, freeDepthCM: 45,
                remainingWeightKG: 18, walkingDistanceM: 7, orderAffinity: 0.35, source: .mapped
            ),
            StorageLocation(
                id: "C-02-04", label: "Aisle C · Bay 02 · Shelf 04", barcode: "LOC-C-02-04",
                freeWidthCM: 90, freeHeightCM: 55, freeDepthCM: 60,
                remainingWeightKG: 70, walkingDistanceM: 24, orderAffinity: 0.94, source: .mapped
            )
        ]
        if let surface = measuredSurfaces.first {
            locations.append(StorageLocation(
                id: "LIDAR-01", label: "Current LiDAR scan", barcode: "LOC-LIDAR-01",
                freeWidthCM: surface.widthCM,
                freeHeightCM: surface.measuredFreeHeightCM ?? (Double(assumedHeight) ?? 40),
                freeDepthCM: surface.depthCM,
                remainingWeightKG: 25, walkingDistanceM: 10, orderAffinity: 0.5, source: .lidarScan
            ))
        }
        return locations
    }

    private func selectProduct(barcode: String) {
        selectedProduct = store.products.first {
            $0.barcode == barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        selectedRecommendation = nil
        verification = nil
    }

    private func select(_ recommendation: PlacementRecommendation) {
        guard let barcode = selectedProduct?.barcode else { return }
        selectedRecommendation = recommendation
        verification = PlacementVerification(
            expectedProductBarcode: barcode,
            expectedLocationBarcode: recommendation.location.barcode
        )
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

private struct RecommendationRow: View {
    let recommendation: PlacementRecommendation
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(recommendation.location.label)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(
                    "Fit \(recommendation.orientation.widthCM.formatted()) × \(recommendation.orientation.heightCM.formatted()) × \(recommendation.orientation.depthCM.formatted()) cm"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    metric("Score", recommendation.score)
                    metric("Orders", recommendation.affinityScore)
                    metric("Travel", recommendation.distanceScore)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func metric(_ label: String, _ value: Double) -> some View {
        Text("\(label) \(value.formatted(.percent.precision(.fractionLength(0))))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}
