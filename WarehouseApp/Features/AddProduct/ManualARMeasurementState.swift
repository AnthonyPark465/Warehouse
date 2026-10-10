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
    /// Application-level coverage and stability indicator, not accuracy.
    var confidence = 0.0
    var dimensionsAreStable = false
    var touchesBoundary = false
    var canFinish = false
    /// Outcome of the pipeline's final acceptance stage.
    var decision = LiDARAcceptanceDecision.notStarted
    /// What the scan still needs, most important first.
    var guidance: [String] = []
    var evidence: LiDARMeasurementEvidence?

    /// Finishing requires a measurement the acceptance stage did not refuse,
    /// a complete box to show, and dimensions inside the storable range.
    static func finishIsAvailable(
        decision: LiDARAcceptanceDecision,
        dimensions: ObjectDimensions?,
        boundingBoxCornersWorld: [SIMD3<Float>]
    ) -> Bool {
        guard decision.allowsFinish,
              let dimensions,
              boundingBoxCornersWorld.count == 8
        else { return false }
        return dimensions.values.allSatisfy {
            $0.isFinite
                && $0 >= ObjectScanValidation.minimumDimensionCM
                && $0 <= ObjectScanValidation.maximumDimensionCM
        }
    }
}

extension ManualProductScanStatus {
    init(report: LiDARMeasurementReport) {
        let measurement = report.measurement
        self.init(
            message: Self.message(for: report),
            integratedFrameCount: report.evidence.frames.acceptedFrameCountSinceReset,
            capturedPointCount: report.totalVoxelCount,
            stablePointCount: measurement?.fusedVoxelCount ?? 0,
            rejectedOutsideRegionCount: report.evidence.frames.outsideRegionSampleCount,
            detectedDimensionsCM: report.reportedDimensionsCM,
            detectedWorldPoints: measurement?.worldPointsInMetres ?? [],
            centredDisplayPoints: measurement?.centredPointsInMetres ?? [],
            boundingBoxCornersWorld: measurement?.boundingBoxCornersWorld ?? [],
            confidence: report.coverageScore,
            dimensionsAreStable: report.dimensionsAreStable,
            touchesBoundary: measurement?.touchesRegionBoundary ?? false,
            canFinish: Self.finishIsAvailable(
                decision: report.decision,
                dimensions: report.reportedDimensionsCM,
                boundingBoxCornersWorld: measurement?.boundingBoxCornersWorld ?? []
            ),
            decision: report.decision,
            guidance: report.guidance,
            evidence: report.evidence
        )
    }

    private static func message(for report: LiDARMeasurementReport) -> String {
        switch report.decision.status {
        case .accepted:
            "All scan checks passed. You can finish."
        case .qualified:
            report.guidance.first.map { "You can finish, with a caution: \($0)" }
                ?? "You can finish, with cautions."
        case .refused:
            report.guidance.first ?? "Collecting product surfaces inside the scanning region…"
        }
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
    /// Bumped when only the detected product's points or box changed, so the
    /// AR view can redraw those without rebuilding the markers and boundary.
    @Published private(set) var detectedProductRevision = 0
    @Published private(set) var placementRequestID = 0
    @Published private(set) var productScanStartRequestID = 0
    @Published private(set) var productScanStopRequestID = 0
    @Published private(set) var productScanStatus = ManualProductScanStatus()
    @Published private(set) var productScanIsActive = false
    /// Outcome of the last validation recording, when recording is on.
    @Published private(set) var recordingNote: String?
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

    // These two run ten times a second. A published property announces a
    // change on every assignment, so each is assigned only when it differs.

    func updatePreview(_ sample: CentreRaycastSample?) {
        if currentSample != sample { currentSample = sample }
    }

    func updateTracking(_ state: ARCamera.TrackingState) {
        let isNormal: Bool
        let message: String
        switch state {
        case .normal:
            isNormal = true
            message = "Tracking ready"
        case .notAvailable:
            isNormal = false
            message = "Tracking unavailable. Check camera access and restart."
        case .limited(let reason):
            isNormal = false
            switch reason {
            case .initializing:
                message = "Initialising—move the phone slowly around the product."
            case .excessiveMotion:
                message = "Excessive motion—move the phone more slowly."
            case .insufficientFeatures:
                message = "Not enough surface detail—add light or aim at a textured area."
            case .relocalizing:
                message = "Relocalising—return the phone to the scanned area."
            @unknown default:
                message = "Tracking is limited. Move slowly and improve lighting."
            }
        }
        if trackingIsNormal != isNormal { trackingIsNormal = isNormal }
        if trackingMessage != message { trackingMessage = message }
        if isNormal, stage == .environment, currentSample != nil {
            stage = .boundary
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

    /// The seed sits this far above the lower limit so it lies inside the
    /// product rather than on the supporting surface.
    static let seedHeightAboveLowerLimitMetres: Float = 0.02

    /// The point the product is expected to surround: an interior point of
    /// the marked polygon. The user selects the object by drawing the region
    /// around it, so the region's middle stands in for an aim point.
    var productSeed: SIMD3<Float>? {
        guard let region = productScanRegion,
              let centre = ManualMeasurementGeometry.interiorPoint(
                of: region.polygon.map { SIMD2<Double>($0) }
              )
        else { return nil }
        return region.origin
            + region.axisU * Float(centre.x)
            + region.axisV * Float(centre.y)
            + region.normal * (region.lowerOffset + Self.seedHeightAboveLowerLimitMetres)
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

    func noteRecording(_ message: String) {
        recordingNote = message
    }

    func stopProductScan() {
        guard productScanIsActive else { return }
        productScanIsActive = false
        productScanStopRequestID += 1
    }

    func finishProductScan() {
        let canFinishNow = ManualProductScanStatus.finishIsAvailable(
            decision: productScanStatus.decision,
            dimensions: productScanStatus.detectedDimensionsCM,
            boundingBoxCornersWorld: productScanStatus.boundingBoxCornersWorld
        )
        guard canFinishNow else {
            reject(scanCompletionProblem)
            return
        }
        guard trackingIsNormal else {
            reject(LiDARMeasurementGuidance.message(for: .trackingNotNormal))
            return
        }
        stopProductScan()
        stage = .review
        renderRevision += 1
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// The AR coordinate system may have changed mid-scan. The fused data is
    /// already discarded; the marked region was placed in the old coordinates
    /// too, so the scan stops until the user has checked it.
    func handleTrackingReset() {
        guard stage == .productScan, productScanIsActive else { return }
        stopProductScan()
        clearDetectedProduct()
        renderRevision += 1
        reject("Tracking was interrupted, so the scan was stopped and its data discarded. Check that the cyan region still surrounds the product, re-mark it if it has shifted, then start the scan again.")
    }

    /// Returns from review to scanning. Capture restarts from empty, so the
    /// previous result is cleared rather than left on screen as if current.
    func continueProductScan() {
        stage = .productScan
        clearDetectedProduct()
        productScanIsActive = true
        productScanStartRequestID += 1
        renderRevision += 1
    }

    func updateProductScan(_ status: ManualProductScanStatus) {
        let detectedGeometryChanged =
            productScanStatus.detectedWorldPoints != status.detectedWorldPoints
            || productScanStatus.boundingBoxCornersWorld
                != status.boundingBoxCornersWorld
        productScanStatus = status
        if detectedGeometryChanged {
            detectedProductRevision += 1
        }
    }

    private var scanCompletionProblem: String {
        productScanStatus.guidance.first
            ?? "More scan coverage is required before finishing."
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
            manualMeasurement: metadata,
            measurementEvidence: productScanStatus.evidence
        )
    }

    private func reject(_ message: String) {
        errorMessage = message
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
