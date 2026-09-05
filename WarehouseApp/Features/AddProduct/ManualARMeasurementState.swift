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
    /// Inline, non-modal placement rejection reason (D16). Session-level
    /// failures still use the modal `errorMessage`.
    @Published private(set) var statusReason: String?
    /// Live per-frame guidance while the reticle sample is unusable (for
    /// example a top-limit aim below the bottom marker). Cleared each frame
    /// the sample becomes valid.
    @Published private(set) var placementGuidance: String?
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
        // Up to the historical 2 cm limit the penalty is unchanged. The
        // relaxed 2–3.5 cm band is accepted with an extra penalty instead of
        // the old hard rejection (D11).
        let deviation = boundaryMeasurement?.plane.maximumDeviation ?? 0
        let penaltyStart = ManualMeasurementGeometry.planeDeviationPenaltyStartMetres
        let relaxedBand = ManualMeasurementGeometry.maximumPlaneDeviationMetres - penaltyStart
        let planePenalty = min(deviation / penaltyStart, 1) * 0.15
            + max(0, min(1, (deviation - penaltyStart) / relaxedBand)) * 0.10
        return min(max(tracking + lidarBonus - planePenalty, 0), 0.95)
    }

    var quality: MeasurementQuality {
        ObjectDimensionCalculator.quality(for: confidence)
    }

    func updatePreview(_ sample: CentreRaycastSample?) {
        currentSample = sample
    }

    func updatePlacementGuidance(_ message: String?) {
        // Called at frame rate; only publish real changes.
        guard placementGuidance != message else { return }
        placementGuidance = message
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
            if let replacementIndex, boundaryMarkers.indices.contains(replacementIndex) {
                boundaryMarkers[replacementIndex] = marker
                self.replacementIndex = nil
            } else {
                // A stale replacement index (markers changed underneath it)
                // must never subscript out of range; fall through to append.
                replacementIndex = nil
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
            guard let boundaryMeasurement else {
                reject("Close and confirm the base boundary before setting the bottom limit.")
                return
            }
            // Validate the bottom the same way tops are validated: on the
            // fitted base plane (3 cm slack) and inside the footprint plus
            // the 25% margin (D2/D6). An unvalidated bottom used to poison
            // every later height computation.
            guard ManualMeasurementGeometry.limitMarkerIsOnBase(
                sample.position,
                boundary: boundaryMeasurement
            ) else {
                reject("Place the bottom marker on the product's base, inside the scanned boundary.")
                return
            }
            bottomMarker = marker
            if let topMarker,
               topMarker.position.y - marker.position.y
                    >= ManualMeasurementGeometry.minimumHeightMetres,
               (try? ManualMeasurementGeometry.height(
                   top: topMarker.position.simd,
                   bottom: marker.position.simd,
                   boundary: boundaryMeasurement
               )) != nil {
                // A retained top marker that is still geometrically valid
                // against the new bottom survives a bottom replacement.
                stage = .productScan
            } else {
                topMarker = nil
                stage = .topLimit
            }
        case .topLimit:
            guard let boundaryMeasurement, let bottomMarker else {
                reject("Set the base boundary and bottom limit before placing the top limit.")
                return
            }
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
        statusReason = nil
        renderRevision += 1
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func closeBoundary() {
        // Corners tapped in Z/diagonal order are repaired into a simple
        // polygon; reorder the stored markers with the same permutation so
        // the rendered outline and the scan prism match the measurement (D10).
        if let order = ManualMeasurementGeometry.repairedBoundaryOrder(
            boundaryMarkers.map { $0.position.simd }
        ) {
            boundaryMarkers = order.map { boundaryMarkers[$0] }
        }
        do {
            boundaryMeasurement = try ManualMeasurementGeometry.measureBoundary(
                boundaryMarkers.map { $0.position.simd }
            )
            stage = .confirmBase
            statusReason = nil
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
            if replacementIndex != nil {
                // Undo during a point replacement cancels the replacement;
                // removing an unrelated marker instead would leave a stale
                // index that crashes the next place() (D14).
                replacementIndex = nil
            } else if !boundaryMarkers.isEmpty {
                boundaryMarkers.removeLast()
            }
        case .confirmBase:
            boundaryMeasurement = nil
            stage = .boundary
        case .bottomLimit:
            boundaryMeasurement = nil
            // A top retained across a bottom replacement is meaningless once
            // the boundary itself is being redone.
            topMarker = nil
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
        // Keep the top marker: place(.bottomLimit) re-validates it against
        // the new bottom and only clears it when geometrically invalid (D7).
        bottomMarker = nil
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
        // A reset is a clean slate: stale error text from the previous
        // attempt must not survive into the new one (D16).
        errorMessage = nil
        statusReason = nil
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
        guard let region = productScanRegion, region.polygon.count >= 3 else { return nil }
        // The vertex centroid can fall outside a concave footprint and seed
        // region growing in empty space; use the polygon's interior seed
        // point (area centroid, nudged inside when necessary) instead (D12).
        let polygon = region.polygon.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        guard let seed = ManualMeasurementGeometry.interiorSeedPoint(for: polygon) else {
            return nil
        }
        let centre = SIMD2<Float>(Float(seed.x), Float(seed.y))
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

    func restartProductScan() {
        // The coordinator resets the fusion engine on every start request, so
        // a "continue" cannot resume the previous capture — present the
        // action honestly as a restart and drop the stale status (D8).
        clearDetectedProduct()
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

    /// Boundary + limit markers alone always yield a usable measurement:
    /// W/D from the footprint's minimum-area rectangle and H from the marker
    /// height. Nil until the region is complete (D9).
    var boundaryFallbackDimensionsCM: ObjectDimensions? {
        guard let boundaryMeasurement, let bottomMarker, let topMarker,
              let heightMetres = try? ManualMeasurementGeometry.height(
                  top: topMarker.position.simd,
                  bottom: bottomMarker.position.simd,
                  boundary: boundaryMeasurement
              )
        else { return nil }
        return ObjectDimensions(
            length: boundaryMeasurement.footprint.lengthMetres * 100,
            width: boundaryMeasurement.footprint.widthMetres * 100,
            height: heightMetres * 100
        )
    }

    /// Completion path for when fusion cannot converge (or on non-LiDAR
    /// devices, where it never reaches its voxel target). The boundary IS the
    /// measurement here, so `scanningRegionOnly` is false and confidence is
    /// capped well below a fused scan's (D9).
    func makeBoundaryFallbackCapture() -> ObjectScanCapture? {
        guard let dimensions = boundaryFallbackDimensionsCM,
              let boundaryMeasurement, let bottomMarker, let topMarker
        else { return nil }
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
            scanningRegionOnly: false,
            detectedProductPointCount: productScanStatus.stablePointCount,
            detectedProductTouchedRegionBoundary: productScanStatus.touchesBoundary
        )
        return ObjectScanCapture(
            id: sessionIdentifier,
            rawDimensionsCM: dimensions,
            pointsInMetres: [],
            scanMethod: .standardAR,
            deviceModel: ObjectScannerCapabilities.deviceModelIdentifier,
            hasLiDAR: ObjectScannerCapabilities.hasLiDAR,
            confidence: 0.5,
            timestamp: .now,
            manualMeasurement: metadata
        )
    }

    private func reject(_ message: String) {
        // Inline, not modal: placement problems are transient aiming feedback
        // and must not interrupt the AR flow with an alert (D16).
        statusReason = message
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
