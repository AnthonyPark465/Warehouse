import ARKit
import Foundation
import SwiftUI

enum ManualMeasurementStage: String, CaseIterable {
    case environment = "Scan Environment"
    case boundary = "Mark Base Boundary"
    case confirmBase = "Confirm Base"
    case bottomLimit = "Set Bottom Limit"
    case topLimit = "Set Top Limit"
    case productScan = "Scan Product"
    case review = "Review Measurements"

    var instruction: String {
        switch self {
        case .environment:
            "Move the phone slowly. Keep the product and surrounding surface visible."
        case .boundary:
            "Aim the centre dot at a base corner, then press Place."
        case .confirmBase:
            "Review the highlighted footprint and confirm the base."
        case .bottomLimit:
            "Aim at the lowest permitted scan level, then set the bottom limit."
        case .topLimit:
            "Aim at the highest permitted scan level, then set the top limit."
        case .productScan:
            "Move slowly around the product. Capture its front, sides, and top."
        case .review:
            "Review the detected product—not the scanning-region dimensions."
        }
    }
}

struct CentreRaycastSample: Equatable {
    let position: SIMD3<Float>
    let raycastType: String
    let surfaceAlignment: String
    let confidence: Double
    let cameraDistanceMetres: Double
}

struct ManualProductScanStatus: Equatable {
    var message = "Ready to scan geometry inside the selected region."
    var integratedFrameCount = 0
    var capturedPointCount = 0
    var stablePointCount = 0
    var rejectedOutsideRegionCount = 0
    var detectedDimensionsCM: ObjectDimensions?
    var detectedWorldPoints: [SIMD3<Float>] = []
    var centredDisplayPoints: [SIMD3<Float>] = []
    var boundingBoxCornersWorld: [SIMD3<Float>] = []
    var confidence = 0.0
    var dimensionsAreStable = false
    var touchesBoundary = false
    var canFinish = false

    static func finishIsAvailable(
        dimensions: ObjectDimensions?,
        stablePointCount: Int,
        boundingBoxCornersWorld: [SIMD3<Float>]
    ) -> Bool {
        guard let dimensions,
              boundingBoxCornersWorld.count == 8,
              stablePointCount >= ObjectScanValidation.minimumPointCount
        else { return false }
        return dimensions.values.allSatisfy {
            $0.isFinite
                && $0 >= ObjectScanValidation.minimumDimensionCM
                && $0 <= ObjectScanValidation.maximumDimensionCM
        }
    }

    mutating func updateCaptureProgress(
        message: String,
        integratedFrameCount: Int,
        capturedPointCount: Int,
        rejectedOutsideRegionCount: Int
    ) {
        self.message = message
        self.integratedFrameCount = integratedFrameCount
        self.capturedPointCount = capturedPointCount
        self.rejectedOutsideRegionCount = rejectedOutsideRegionCount
    }
}

@MainActor
final class ManualARMeasurementState: ObservableObject {
    let sessionIdentifier = UUID()

    @Published private(set) var stage: ManualMeasurementStage = .environment
    @Published private(set) var boundaryMarkers: [ManualBoundaryMarker] = []
    @Published private(set) var bottomMarker: ManualBoundaryMarker?
    @Published private(set) var topMarker: ManualBoundaryMarker?
    @Published private(set) var boundaryMeasurement: BoundaryMeasurement?
    @Published private(set) var currentSample: CentreRaycastSample?
    @Published private(set) var trackingMessage = "Initialising AR tracking…"
    @Published private(set) var trackingIsNormal = false
    @Published private(set) var renderRevision = 0
    @Published private(set) var placementRequestID = 0
    @Published private(set) var productScanStartRequestID = 0
    @Published private(set) var productScanStopRequestID = 0
    @Published private(set) var productScanStatus = ManualProductScanStatus()
    @Published private(set) var productScanIsActive = false
    @Published var errorMessage: String?
    @Published var percentageTolerance = ObjectDimensionPolicy.default.percentageTolerance
    @Published var fixedToleranceCM = ObjectDimensionPolicy.default.fixedToleranceCM
    @Published var useAdjustedDimensions = true
    @Published var canBeRotated = false

    private(set) var replacementIndex: Int?
    private var trackingScores: [Double] = []

    var canPlace: Bool {
        trackingIsNormal && currentSample != nil
    }

    var markerCountText: String {
        "\(boundaryMarkers.count) base point\(boundaryMarkers.count == 1 ? "" : "s")"
    }

    var rawDimensionsCM: ObjectDimensions? {
        productScanStatus.detectedDimensionsCM
    }

    var confidence: Double {
        if productScanStatus.detectedDimensionsCM != nil {
            return productScanStatus.confidence
        }
        guard !trackingScores.isEmpty else { return 0 }
        let tracking = trackingScores.reduce(0, +) / Double(trackingScores.count)
        let lidarBonus = ObjectScannerCapabilities.hasLiDAR ? 0.08 : 0
        let planePenalty = min((boundaryMeasurement?.plane.maximumDeviation ?? 0) / 0.02, 1) * 0.15
        return min(max(tracking + lidarBonus - planePenalty, 0), 0.95)
    }

    var quality: MeasurementQuality {
        ObjectDimensionCalculator.quality(for: confidence)
    }

    func updatePreview(_ sample: CentreRaycastSample?) {
        currentSample = sample
    }

    func updateTracking(_ state: ARCamera.TrackingState) {
        switch state {
        case .normal:
            trackingIsNormal = true
            trackingMessage = "Tracking ready"
            if stage == .environment, currentSample != nil {
                stage = .boundary
            }
        case .notAvailable:
            trackingIsNormal = false
            trackingMessage = "Tracking unavailable. Check camera access and restart."
        case .limited(let reason):
            trackingIsNormal = false
            switch reason {
            case .initializing:
                trackingMessage = "Initialising—move the phone slowly around the product."
            case .excessiveMotion:
                trackingMessage = "Excessive motion—move the phone more slowly."
            case .insufficientFeatures:
                trackingMessage = "Not enough surface detail—add light or aim at a textured area."
            case .relocalizing:
                trackingMessage = "Relocalising—return the phone to the scanned area."
            @unknown default:
                trackingMessage = "Tracking is limited. Move slowly and improve lighting."
            }
        }
    }

    func requestPlacement() {
        guard canPlace else {
            reject("No reliable surface is under the centre dot. Move closer and aim at a visible surface.")
            return
        }
        placementRequestID += 1
    }

    func place(_ sample: CentreRaycastSample?) {
        guard let sample, trackingIsNormal else {
            reject("The centre raycast failed. Hold the phone steady, aim at a visible surface, and try again.")
            return
        }
        let marker = ManualBoundaryMarker(
            id: UUID(),
            position: ARWorldCoordinate(sample.position),
            timestamp: .now,
            trackingConfidence: sample.confidence,
            raycastType: sample.raycastType,
            surfaceAlignment: sample.surfaceAlignment,
            sessionIdentifier: sessionIdentifier
        )
        switch stage {
        case .boundary:
            if let replacementIndex {
                boundaryMarkers[replacementIndex] = marker
                self.replacementIndex = nil
            } else {
                if boundaryMarkers.contains(where: {
                    simd_distance($0.position.simd, sample.position)
                        < Float(ManualMeasurementGeometry.minimumPointSpacingMetres)
                }) {
                    reject("That point is too close to an existing marker. Aim at a different corner.")
                    return
                }
                boundaryMarkers.append(marker)
            }
        case .bottomLimit:
            bottomMarker = marker
            stage = .topLimit
        case .topLimit:
            guard let boundaryMeasurement, let bottomMarker else { return }
            do {
                _ = try ManualMeasurementGeometry.height(
                    top: marker.position.simd,
                    bottom: bottomMarker.position.simd,
                    boundary: boundaryMeasurement
                )
            } catch {
                reject(error.localizedDescription)
                return
            }
            guard marker.position.y - bottomMarker.position.y
                    >= ManualMeasurementGeometry.minimumHeightMetres
            else {
                reject("The top scan limit must be above the bottom limit. Aim higher and try again.")
                return
            }
            topMarker = marker
            stage = .productScan
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        default:
            return
        }
        trackingScores.append(sample.confidence)
        renderRevision += 1
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func closeBoundary() {
        do {
            boundaryMeasurement = try ManualMeasurementGeometry.measureBoundary(
                boundaryMarkers.map { $0.position.simd }
            )
            stage = .confirmBase
            renderRevision += 1
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            reject(error.localizedDescription)
        }
    }

    func confirmBase() {
        guard boundaryMeasurement != nil else { return }
        stage = .bottomLimit
    }

    func undo() {
        switch stage {
        case .boundary:
            if !boundaryMarkers.isEmpty { boundaryMarkers.removeLast() }
        case .confirmBase:
            boundaryMeasurement = nil
            stage = .boundary
        case .bottomLimit:
            boundaryMeasurement = nil
            stage = .boundary
        case .topLimit:
            bottomMarker = nil
            stage = .bottomLimit
        case .productScan:
            stopProductScan()
            clearDetectedProduct()
            topMarker = nil
            stage = .topLimit
        case .review:
            stage = .productScan
        case .environment:
            break
        }
        renderRevision += 1
    }

    func replaceBoundaryPoint(at index: Int) {
        guard boundaryMarkers.indices.contains(index) else { return }
        replacementIndex = index
        boundaryMeasurement = nil
        bottomMarker = nil
        topMarker = nil
        clearDetectedProduct()
        stage = .boundary
        renderRevision += 1
    }

    func replaceBottom() {
        bottomMarker = nil
        topMarker = nil
        clearDetectedProduct()
        stage = .bottomLimit
        renderRevision += 1
    }

    func replaceTop() {
        topMarker = nil
        clearDetectedProduct()
        stage = .topLimit
        renderRevision += 1
    }

    func reset() {
        stopProductScan()
        boundaryMarkers.removeAll()
        bottomMarker = nil
        topMarker = nil
        boundaryMeasurement = nil
        replacementIndex = nil
        trackingScores.removeAll()
        clearDetectedProduct()
        stage = trackingIsNormal ? .boundary : .environment
        renderRevision += 1
    }

    var productScanRegion: LiDARPolygonalPrism? {
        guard let boundaryMeasurement, let bottomMarker, let topMarker else {
            return nil
        }
        let plane = boundaryMeasurement.plane
        guard (try? ManualMeasurementGeometry.height(
            top: topMarker.position.simd,
            bottom: bottomMarker.position.simd,
            boundary: boundaryMeasurement
        )) != nil else { return nil }

        // ARKit's gravity-aligned world coordinate system uses +Y as up. Keep
        // the fitted plane for footprint measurement, but make the scan crop
        // and voxel engine's height axis independent of floor-plane tilt.
        let origin = SIMD3<Float>(plane.origin)
        let bottomOffset = bottomMarker.position.simd.y - origin.y
        let topOffset = topMarker.position.simd.y - origin.y
        let horizontalBoundary = boundaryMarkers.map {
            SIMD2<Float>($0.position.simd.x - origin.x, $0.position.simd.z - origin.z)
        }
        return LiDARPolygonalPrism(
            origin: origin,
            axisU: SIMD3<Float>(1, 0, 0),
            axisV: SIMD3<Float>(0, 0, 1),
            normal: SIMD3<Float>(0, 1, 0),
            polygon: horizontalBoundary,
            lowerOffset: bottomOffset,
            upperOffset: topOffset
        )
    }

    var productSeed: SIMD3<Float>? {
        guard let region = productScanRegion, !region.polygon.isEmpty else { return nil }
        let centre = region.polygon.reduce(SIMD2<Float>.zero, +)
            / Float(region.polygon.count)
        return region.origin
            + region.axisU * centre.x
            + region.axisV * centre.y
            + region.normal * (region.lowerOffset + 0.02)
    }

    func startProductScan() {
        guard stage == .productScan, productScanRegion != nil, productSeed != nil else {
            reject("Finish the scanning boundary and its bottom/top limits first.")
            return
        }
        clearDetectedProduct()
        productScanIsActive = true
        productScanStatus.message = ObjectScannerCapabilities.hasLiDAR
            ? "Scanning only inside the highlighted region. Move around the product."
            : "LiDAR is unavailable. Collecting lower-density AR feature points."
        productScanStartRequestID += 1
    }

    func stopProductScan() {
        guard productScanIsActive else { return }
        productScanIsActive = false
        productScanStopRequestID += 1
    }

    func finishProductScan() {
        let canFinishNow = ManualProductScanStatus.finishIsAvailable(
            dimensions: productScanStatus.detectedDimensionsCM,
            stablePointCount: productScanStatus.stablePointCount,
            boundingBoxCornersWorld: productScanStatus.boundingBoxCornersWorld
        )
        guard canFinishNow else {
            reject(scanCompletionProblem)
            return
        }
        stopProductScan()
        stage = .review
        renderRevision += 1
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func continueProductScan() {
        stage = .productScan
        productScanIsActive = true
        productScanStartRequestID += 1
    }

    func updateProductScan(_ status: ManualProductScanStatus) {
        let detectedGeometryChanged =
            productScanStatus.detectedWorldPoints != status.detectedWorldPoints
            || productScanStatus.boundingBoxCornersWorld
                != status.boundingBoxCornersWorld
        productScanStatus = status
        if detectedGeometryChanged {
            renderRevision += 1
        }
    }

    private var scanCompletionProblem: String {
        if productScanStatus.touchesBoundary {
            return "The detected product touches the scanning limit. Expand the boundary or limits and rescan."
        }
        if productScanStatus.stablePointCount < LiDARFusionConfiguration.smallObject.minimumStableVoxelCount {
            return "Too little product geometry was collected. Scan the front, sides, and top."
        }
        if !productScanStatus.dimensionsAreStable {
            return "The calculated dimensions are still changing. Continue scanning slowly."
        }
        return "More scan coverage is required before finishing."
    }

    private func clearDetectedProduct() {
        if productScanIsActive {
            productScanStopRequestID += 1
        }
        productScanIsActive = false
        productScanStatus = ManualProductScanStatus()
    }

    func makeCapture() -> ObjectScanCapture? {
        guard let rawDimensionsCM, let boundaryMeasurement,
              let bottomMarker, let topMarker else { return nil }
        let plane = boundaryMeasurement.plane
        let metadata = ManualARMeasurementMetadata(
            sessionIdentifier: sessionIdentifier,
            boundaryMarkers: boundaryMarkers,
            bottomMarker: bottomMarker,
            topMarker: topMarker,
            basePlane: MeasurementBasePlane(
                origin: ARWorldCoordinate(SIMD3<Float>(plane.origin)),
                normal: ARWorldCoordinate(SIMD3<Float>(plane.normal)),
                maximumDeviationMetres: plane.maximumDeviation
            ),
            footprintAreaSquareMetres: boundaryMeasurement.footprint.areaSquareMetres,
            perimeterMetres: boundaryMeasurement.footprint.perimeterMetres,
            orientationAngleDegrees: boundaryMeasurement.footprint.orientationRadians * 180 / .pi,
            scanningRegionOnly: true,
            detectedProductPointCount: productScanStatus.stablePointCount,
            detectedProductTouchedRegionBoundary: productScanStatus.touchesBoundary
        )
        return ObjectScanCapture(
            id: sessionIdentifier,
            rawDimensionsCM: rawDimensionsCM,
            pointsInMetres: productScanStatus.centredDisplayPoints,
            scanMethod: ObjectScannerCapabilities.hasLiDAR ? .manualBoundary : .standardAR,
            deviceModel: ObjectScannerCapabilities.deviceModelIdentifier,
            hasLiDAR: ObjectScannerCapabilities.hasLiDAR,
            confidence: confidence,
            timestamp: .now,
            manualMeasurement: metadata
        )
    }

    private func reject(_ message: String) {
        errorMessage = message
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
