import ARKit
import Foundation
import SwiftUI

enum ManualMeasurementStage: String, CaseIterable {
    case scanning = "Scan Environment"
    case boundary = "Mark Base Boundary"
    case confirmBase = "Confirm Base"
    case bottom = "Mark Bottom"
    case top = "Mark Top"
    case review = "Review Measurements"

    var instruction: String {
        switch self {
        case .scanning:
            "Move the phone slowly. Keep the product and surrounding surface visible."
        case .boundary:
            "Aim the centre dot at a base corner, then press Place."
        case .confirmBase:
            "Review the highlighted footprint and confirm the base."
        case .bottom:
            "Aim at the bottom of the product, then press Place Bottom."
        case .top:
            "Aim at the top of the product, then press Place Top."
        case .review:
            "Review the estimate before applying it to the product."
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

@MainActor
final class ManualARMeasurementState: ObservableObject {
    let sessionIdentifier = UUID()

    @Published private(set) var stage: ManualMeasurementStage = .scanning
    @Published private(set) var boundaryMarkers: [ManualBoundaryMarker] = []
    @Published private(set) var bottomMarker: ManualBoundaryMarker?
    @Published private(set) var topMarker: ManualBoundaryMarker?
    @Published private(set) var boundaryMeasurement: BoundaryMeasurement?
    @Published private(set) var currentSample: CentreRaycastSample?
    @Published private(set) var trackingMessage = "Initialising AR tracking…"
    @Published private(set) var trackingIsNormal = false
    @Published private(set) var renderRevision = 0
    @Published private(set) var placementRequestID = 0
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
        guard let boundaryMeasurement, let topMarker, let bottomMarker,
              let height = try? ManualMeasurementGeometry.height(
                top: topMarker.position.simd,
                bottom: bottomMarker.position.simd,
                boundary: boundaryMeasurement
              )
        else { return nil }
        return ObjectDimensions(
            length: boundaryMeasurement.footprint.lengthMetres * 100,
            width: boundaryMeasurement.footprint.widthMetres * 100,
            height: height * 100
        )
    }

    var confidence: Double {
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
            if stage == .scanning, currentSample != nil {
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
        case .bottom:
            bottomMarker = marker
            stage = .top
        case .top:
            guard let boundaryMeasurement, let bottomMarker else { return }
            do {
                _ = try ManualMeasurementGeometry.height(
                    top: marker.position.simd,
                    bottom: bottomMarker.position.simd,
                    boundary: boundaryMeasurement
                )
                topMarker = marker
                stage = .review
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                reject(error.localizedDescription)
                return
            }
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
        stage = .bottom
    }

    func undo() {
        switch stage {
        case .boundary:
            if !boundaryMarkers.isEmpty { boundaryMarkers.removeLast() }
        case .confirmBase:
            boundaryMeasurement = nil
            stage = .boundary
        case .bottom:
            boundaryMeasurement = nil
            stage = .boundary
        case .top:
            bottomMarker = nil
            stage = .bottom
        case .review:
            topMarker = nil
            stage = .top
        case .scanning:
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
        stage = .boundary
        renderRevision += 1
    }

    func replaceBottom() {
        bottomMarker = nil
        topMarker = nil
        stage = .bottom
        renderRevision += 1
    }

    func replaceTop() {
        topMarker = nil
        stage = .top
        renderRevision += 1
    }

    func reset() {
        boundaryMarkers.removeAll()
        bottomMarker = nil
        topMarker = nil
        boundaryMeasurement = nil
        replacementIndex = nil
        trackingScores.removeAll()
        stage = trackingIsNormal ? .boundary : .scanning
        renderRevision += 1
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
            orientationAngleDegrees: boundaryMeasurement.footprint.orientationRadians * 180 / .pi
        )
        return ObjectScanCapture(
            id: sessionIdentifier,
            rawDimensionsCM: rawDimensionsCM,
            pointsInMetres: boundaryMarkers.map { $0.position.simd },
            scanMethod: .manualBoundary,
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
