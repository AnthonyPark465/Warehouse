import ARKit
import RealityKit
import SwiftUI
import UIKit

enum ShelfMeasurementStage: Equatable {
    case boundary
    case review
    case bottom
    case top
    case frontSelection
    case frontConfirmation
    case complete
}

struct MeasuredShelfSurface: Equatable {
    let id: UUID
    let widthCM: Double
    let depthCM: Double
    /// nil when no obstruction was found above (open-topped shelf).
    let measuredFreeHeightCM: Double?
    /// Access-to-back direction expressed in the selected plane anchor's local coordinates.
    let frontDirectionLocal: Vector3D?
    let originLocal: Vector3D?
    let scanConfidence: Double
    let boundaryClosed: Bool
    let geometry: ShelfGeometryRecord?
    let boundaryAnalysis: ShelfBoundaryAnalysis?
    let cornerMetadata: [ShelfCornerMeasurementMetadata]
    let measuredSpaceCorners: [MeasuredSpaceCornerRecord]
    let scannedBoundary: ScannedStorageBoundary?

    func replacingScannedBoundary(_ boundary: ScannedStorageBoundary?) -> Self {
        Self(
            id: id, widthCM: widthCM, depthCM: depthCM,
            measuredFreeHeightCM: measuredFreeHeightCM,
            frontDirectionLocal: frontDirectionLocal, originLocal: originLocal,
            scanConfidence: boundary?.geometryConfidence ?? scanConfidence,
            boundaryClosed: boundary?.validationState == .valid || boundaryClosed,
            geometry: geometry, boundaryAnalysis: boundaryAnalysis,
            cornerMetadata: cornerMetadata, measuredSpaceCorners: measuredSpaceCorners,
            scannedBoundary: boundary
        )
    }
}

struct LiDARSurfaceScannerView: UIViewRepresentable {
    @Binding var measuredSurfaces: [MeasuredShelfSurface]
    @Binding var mappedPointCount: Int
    @Binding var canPlacePoint: Bool
    @Binding var measurementStage: ShelfMeasurementStage
    @Binding var pointStability: ShelfPointStability
    @Binding var pointGuidance: String
    @Binding var cornerTelemetry: CornerMeasurementTelemetry
    @Binding var borderScanSnapshot: BorderScanSnapshot
    @Binding var manualBorderCorrection: Bool
    let geometryType: StorageGeometryType
    let surfaceType: SpaceSurfaceType
    let resetToken: Int
    let placementRequestID: Int
    let undoRequestID: Int
    let frontRequestID: Int
    let reverseFrontRequestID: Int
    let replaceCornerRequestID: Int
    let borderPauseRequestID: Int
    let borderFinishRequestID: Int
    let borderConfirmCornerRequestID: Int
    let borderContinueEdgeRequestID: Int
    let borderRescanEdgeRequestID: Int
    let replacementCornerIndex: Int
    let guidanceResult: ProductPlacementResult?

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    static var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            measuredSurfaces: $measuredSurfaces,
            mappedPointCount: $mappedPointCount,
            canPlacePoint: $canPlacePoint,
            measurementStage: $measurementStage,
            pointStability: $pointStability,
            pointGuidance: $pointGuidance,
            cornerTelemetry: $cornerTelemetry,
            borderScanSnapshot: $borderScanSnapshot,
            manualBorderCorrection: $manualBorderCorrection,
            geometryType: geometryType,
            surfaceType: surfaceType,
            resetToken: resetToken,
            placementRequestID: placementRequestID,
            undoRequestID: undoRequestID,
            frontRequestID: frontRequestID,
            reverseFrontRequestID: reverseFrontRequestID,
            replaceCornerRequestID: replaceCornerRequestID,
            borderPauseRequestID: borderPauseRequestID,
            borderFinishRequestID: borderFinishRequestID,
            borderConfirmCornerRequestID: borderConfirmCornerRequestID,
            borderContinueEdgeRequestID: borderContinueEdgeRequestID,
            borderRescanEdgeRequestID: borderRescanEdgeRequestID,
            replacementCornerIndex: replacementCornerIndex,
            guidanceResult: guidanceResult
        )
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if Self.hasLiDAR {
            configuration.sceneReconstruction = .mesh
        }
        configuration.environmentTexturing = .automatic
        view.session.delegate = context.coordinator
        view.session.run(configuration)
        context.coordinator.arView = view
        let coaching = ARCoachingOverlayView()
        coaching.session = view.session
        coaching.goal = .horizontalPlane
        coaching.activatesAutomatically = true
        coaching.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(coaching)
        NSLayoutConstraint.activate([
            coaching.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            coaching.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            coaching.topAnchor.constraint(equalTo: view.topAnchor),
            coaching.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // This is a broad region cue, not a corner-placement crosshair. The active
        // surface-first workflow adapts its depth footprint to physical distance.
        let target = UIView()
        target.translatesAutoresizingMaskIntoConstraints = false
        target.isUserInteractionEnabled = false
        target.isAccessibilityElement = true
        target.accessibilityLabel = "Point broadly at the requested shelf surface"
        target.layer.cornerRadius = geometryType == .openSpace ? 24 : 14
        target.layer.borderWidth = 2
        target.layer.borderColor = UIColor.white.cgColor
        target.layer.shadowColor = UIColor.black.cgColor
        target.layer.shadowOpacity = 0.45
        target.layer.shadowRadius = 2
        target.layer.shadowOffset = .zero

        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isUserInteractionEnabled = false
        dot.backgroundColor = .white
        dot.layer.cornerRadius = 3
        target.addSubview(dot)
        view.addSubview(target)
        NSLayoutConstraint.activate([
            target.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            target.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            target.widthAnchor.constraint(equalToConstant: geometryType == .openSpace ? 96 : 28),
            target.heightAnchor.constraint(equalToConstant: geometryType == .openSpace ? 64 : 28),
            dot.centerXAnchor.constraint(equalTo: target.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: target.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: geometryType == .openSpace ? 0 : 6),
            dot.heightAnchor.constraint(equalToConstant: geometryType == .openSpace ? 0 : 6)
        ])
        context.coordinator.attachTarget(target, dot: dot)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.handle(
            resetToken: resetToken,
            placementRequestID: placementRequestID,
            undoRequestID: undoRequestID,
            frontRequestID: frontRequestID,
            reverseFrontRequestID: reverseFrontRequestID,
            replaceCornerRequestID: replaceCornerRequestID,
            borderPauseRequestID: borderPauseRequestID,
            borderFinishRequestID: borderFinishRequestID,
            borderConfirmCornerRequestID: borderConfirmCornerRequestID,
            borderContinueEdgeRequestID: borderContinueEdgeRequestID,
            borderRescanEdgeRequestID: borderRescanEdgeRequestID,
            replacementCornerIndex: replacementCornerIndex,
            guidanceResult: guidanceResult
        )
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        weak var arView: ARView?
        private var measuredSurfaces: Binding<[MeasuredShelfSurface]>
        private var mappedPointCount: Binding<Int>
        private var canPlacePoint: Binding<Bool>
        private var measurementStage: Binding<ShelfMeasurementStage>
        private var pointStability: Binding<ShelfPointStability>
        private var pointGuidance: Binding<String>
        private var cornerTelemetry: Binding<CornerMeasurementTelemetry>
        private var borderScanSnapshot: Binding<BorderScanSnapshot>
        private var manualBorderCorrection: Binding<Bool>
        private let geometryType: StorageGeometryType
        private let surfaceType: SpaceSurfaceType
        private var mappedPoints: [SIMD3<Float>] = []
        private var selectedPlaneID: UUID?
        private var selectedPlane: ARPlaneAnchor?
        private var boundaryMeasurement: BoundaryMeasurement?
        private var bottomPoint: SIMD3<Float>?
        private var topPoint: SIMD3<Float>?
        private var selectionAnchor: AnchorEntity?
        private var heightAnchor: AnchorEntity?
        private var frontAnchor: AnchorEntity?
        private var guidanceAnchor: AnchorEntity?
        private weak var targetView: UIView?
        private weak var targetDot: UIView?
        private var lastResetToken: Int
        private var handledPlacementRequestID: Int
        private var handledUndoRequestID: Int
        private var handledFrontRequestID: Int
        private var handledReverseFrontRequestID: Int
        private var handledReplaceCornerRequestID: Int
        private var handledBorderPauseRequestID: Int
        private var handledBorderFinishRequestID: Int
        private var handledBorderConfirmCornerRequestID: Int
        private var handledBorderContinueEdgeRequestID: Int
        private var handledBorderRescanEdgeRequestID: Int
        private var pendingReplacementIndex: Int?
        private var handledGuidanceID: String?
        private var rollingSamples: [ShelfPointSample] = []
        private var currentPointEstimate: ShelfPointEstimate?
        private var cornerMetadata: [ShelfCornerMeasurementMetadata] = []
        private var measuredSpaceCorners: [MeasuredSpaceCornerRecord] = []
        private var coordinateEpochInvalid = false
        private var lastFrameTimestamp: TimeInterval = 0
        private let hasLiDAR = LiDARSurfaceScannerView.hasLiDAR
        private let borderDetector: any BorderDetectionEngine = DefaultBorderDetectionEngine()
        private let borderTraceBuilder = DefaultBorderTraceBuilder()
        private let sectionedBoundary = SectionedBoundaryAcquisition()
        private let boundaryProcessor: any BoundaryProcessing = DefaultBoundaryProcessor()
        private var borderAnchor: AnchorEntity?
        private var borderPaused = false
        private var candidatePersistence = 0
        private var lastCandidatePosition: SIMD2<Double>?
        private var coordinateEpoch = UUID()
        private var guidedCornerMeasurements: [GuidedCornerMeasurement] = []
        private var guidedPatchSamples: [LocalCornerPatchSample] = []
        private var guidedCaptureStartedAt: TimeInterval?
        private var guidedFrameSequence = 0
        private var guidedLastAcceptedCameraTransform: simd_float4x4?
        private var guidedLastAcceptedFrameTimestamp: TimeInterval = 0
        private var guidedCandidate: GuidedCornerMeasurement?
        private var targetVolume: LocalTargetVolume?
        private var surfaceCaptures: [CompartmentSurface: SurfaceCaptureRecord] = [:]
        private var surfaceObservations: [SurfaceCaptureObservation] = []
        private var surfaceCaptureStartedAt: TimeInterval?
        private var surfaceFrameSequence = 0
        private var surfaceLastAcceptedCameraTransform: simd_float4x4?
        private var surfaceLastAcceptedFrameTimestamp: TimeInterval = 0
        private var surfaceSelectedRegionSeed: Vector3D?
        private var surfaceCandidate: SurfaceCaptureRecord?
        private var surfaceEvidenceAnchor: AnchorEntity?

        private let surfaceSequence: [CompartmentSurface] = [
            .bottom, .back, .left, .right, .top, .frontOpening
        ]

        init(
            measuredSurfaces: Binding<[MeasuredShelfSurface]>,
            mappedPointCount: Binding<Int>,
            canPlacePoint: Binding<Bool>,
            measurementStage: Binding<ShelfMeasurementStage>,
            pointStability: Binding<ShelfPointStability>,
            pointGuidance: Binding<String>,
            cornerTelemetry: Binding<CornerMeasurementTelemetry>,
            borderScanSnapshot: Binding<BorderScanSnapshot>,
            manualBorderCorrection: Binding<Bool>,
            geometryType: StorageGeometryType,
            surfaceType: SpaceSurfaceType,
            resetToken: Int,
            placementRequestID: Int,
            undoRequestID: Int,
            frontRequestID: Int,
            reverseFrontRequestID: Int,
            replaceCornerRequestID: Int,
            borderPauseRequestID: Int,
            borderFinishRequestID: Int,
            borderConfirmCornerRequestID: Int,
            borderContinueEdgeRequestID: Int,
            borderRescanEdgeRequestID: Int,
            replacementCornerIndex: Int,
            guidanceResult: ProductPlacementResult?
        ) {
            self.measuredSurfaces = measuredSurfaces
            self.mappedPointCount = mappedPointCount
            self.canPlacePoint = canPlacePoint
            self.measurementStage = measurementStage
            self.pointStability = pointStability
            self.pointGuidance = pointGuidance
            self.cornerTelemetry = cornerTelemetry
            self.borderScanSnapshot = borderScanSnapshot
            self.manualBorderCorrection = manualBorderCorrection
            self.geometryType = geometryType
            self.surfaceType = surfaceType
            self.lastResetToken = resetToken
            self.handledPlacementRequestID = placementRequestID
            self.handledUndoRequestID = undoRequestID
            self.handledFrontRequestID = frontRequestID
            self.handledReverseFrontRequestID = reverseFrontRequestID
            self.handledReplaceCornerRequestID = replaceCornerRequestID
            self.handledBorderPauseRequestID = borderPauseRequestID
            self.handledBorderFinishRequestID = borderFinishRequestID
            self.handledBorderConfirmCornerRequestID = borderConfirmCornerRequestID
            self.handledBorderContinueEdgeRequestID = borderContinueEdgeRequestID
            self.handledBorderRescanEdgeRequestID = borderRescanEdgeRequestID
            self.handledGuidanceID = guidanceResult?.id
        }

        @MainActor
        func attachTarget(_ target: UIView, dot: UIView) {
            targetView = target
            targetDot = dot
            updateTargetAppearance(isValid: false)
        }

        @MainActor
        func handle(
            resetToken: Int,
            placementRequestID: Int,
            undoRequestID: Int,
            frontRequestID: Int,
            reverseFrontRequestID: Int,
            replaceCornerRequestID: Int,
            borderPauseRequestID: Int,
            borderFinishRequestID: Int,
            borderConfirmCornerRequestID: Int,
            borderContinueEdgeRequestID: Int,
            borderRescanEdgeRequestID: Int,
            replacementCornerIndex: Int,
            guidanceResult: ProductPlacementResult?
        ) {
            if resetToken != lastResetToken {
                lastResetToken = resetToken
                DispatchQueue.main.async { [weak self] in self?.resetSelection() }
            }
            if placementRequestID != handledPlacementRequestID {
                handledPlacementRequestID = placementRequestID
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.geometryType == .openSpace,
                       !self.manualBorderCorrection.wrappedValue,
                       self.measurementStage.wrappedValue == .boundary {
                        self.advanceSurfaceFirstWorkflow()
                    } else {
                        self.performPlacementAtCentre()
                    }
                }
            }
            if undoRequestID != handledUndoRequestID {
                handledUndoRequestID = undoRequestID
                DispatchQueue.main.async { [weak self] in self?.undoLastMarker() }
            }
            if frontRequestID != handledFrontRequestID {
                handledFrontRequestID = frontRequestID
                DispatchQueue.main.async { [weak self] in self?.setFrontFromCamera() }
            }
            if reverseFrontRequestID != handledReverseFrontRequestID {
                handledReverseFrontRequestID = reverseFrontRequestID
                DispatchQueue.main.async { [weak self] in self?.reverseFront() }
            }
            if replaceCornerRequestID != handledReplaceCornerRequestID {
                handledReplaceCornerRequestID = replaceCornerRequestID
                if mappedPoints.indices.contains(replacementCornerIndex) {
                    pendingReplacementIndex = replacementCornerIndex
                    rollingSamples.removeAll()
                    currentPointEstimate = nil
                    guidedCandidate = nil
                    guidedPatchSamples.removeAll()
                    guidedCaptureStartedAt = nil
                    measurementStage.wrappedValue = .boundary
                    borderScanSnapshot.wrappedValue.guidedState = .correcting(index: replacementCornerIndex)
                    borderScanSnapshot.wrappedValue.selectedCornerIndex = replacementCornerIndex
                    borderScanSnapshot.wrappedValue.status = "Aim at replacement corner \(replacementCornerIndex + 1)"
                }
            }
            if borderPauseRequestID != handledBorderPauseRequestID {
                handledBorderPauseRequestID = borderPauseRequestID
                // Retained for source compatibility with the obsolete continuous
                // trace controls. Guided capture cannot be paused mid-corner.
            }
            if borderFinishRequestID != handledBorderFinishRequestID {
                handledBorderFinishRequestID = borderFinishRequestID
                DispatchQueue.main.async { [weak self] in self?.finalizeSurfaceFirstCompartment() }
            }
            if borderConfirmCornerRequestID != handledBorderConfirmCornerRequestID {
                handledBorderConfirmCornerRequestID = borderConfirmCornerRequestID
                DispatchQueue.main.async { [weak self] in self?.acceptSurfaceCandidate() }
            }
            if borderContinueEdgeRequestID != handledBorderContinueEdgeRequestID {
                handledBorderContinueEdgeRequestID = borderContinueEdgeRequestID
                DispatchQueue.main.async { [weak self] in self?.confirmUsableOpening() }
            }
            if borderRescanEdgeRequestID != handledBorderRescanEdgeRequestID {
                handledBorderRescanEdgeRequestID = borderRescanEdgeRequestID
                DispatchQueue.main.async { [weak self] in self?.discardSurfaceCandidate() }
            }
            if guidanceResult?.id != handledGuidanceID {
                handledGuidanceID = guidanceResult?.id
                DispatchQueue.main.async { [weak self] in self?.showGuidance(guidanceResult) }
            }
        }

        @MainActor
        private func resetSelection() {
            mappedPoints.removeAll()
            selectedPlaneID = nil
            selectedPlane = nil
            boundaryMeasurement = nil
            bottomPoint = nil
            topPoint = nil
            selectionAnchor?.removeFromParent()
            selectionAnchor = nil
            heightAnchor?.removeFromParent()
            heightAnchor = nil
            frontAnchor?.removeFromParent()
            frontAnchor = nil
            guidanceAnchor?.removeFromParent()
            guidanceAnchor = nil
            rollingSamples.removeAll()
            currentPointEstimate = nil
            cornerMetadata.removeAll()
            measuredSpaceCorners.removeAll()
            guidedCornerMeasurements.removeAll()
            guidedPatchSamples.removeAll()
            guidedCaptureStartedAt = nil
            guidedFrameSequence = 0
            guidedLastAcceptedCameraTransform = nil
            guidedLastAcceptedFrameTimestamp = 0
            guidedCandidate = nil
            targetVolume = nil
            surfaceCaptures.removeAll()
            surfaceObservations.removeAll()
            surfaceCaptureStartedAt = nil
            surfaceFrameSequence = 0
            surfaceLastAcceptedCameraTransform = nil
            surfaceLastAcceptedFrameTimestamp = 0
            surfaceSelectedRegionSeed = nil
            surfaceCandidate = nil
            surfaceEvidenceAnchor?.removeFromParent()
            surfaceEvidenceAnchor = nil
            coordinateEpoch = UUID()
            borderTraceBuilder.reset()
            sectionedBoundary.reset()
            borderAnchor?.removeFromParent()
            borderAnchor = nil
            borderPaused = false
            candidatePersistence = 0
            lastCandidatePosition = nil
            coordinateEpochInvalid = false
            pendingReplacementIndex = nil
            measuredSurfaces.wrappedValue = []
            mappedPointCount.wrappedValue = 0
            measurementStage.wrappedValue = .boundary
            pointStability.wrappedValue = .searching
            pointGuidance.wrappedValue = geometryType == .openSpace
                ? "Point broadly at the middle of the storage compartment."
                : "Move the reticle onto a visible shelf corner."
            cornerTelemetry.wrappedValue = .init()
            borderScanSnapshot.wrappedValue = BorderScanSnapshot(
                state: hasLiDAR ? .findingBaseSurface : .failed(.lidarUnavailable),
                status: hasLiDAR ? "Finding base surface" : "LiDAR unavailable",
                lastError: hasLiDAR ? nil : .lidarUnavailable,
                guidedState: hasLiDAR ? .findingBasePlane : .failed(.lidarUnavailable),
                surfaceFirstState: hasLiDAR ? .findingCompartment : .failed
            )
            updateTargetAvailability()
        }

        @MainActor
        private func undoLastMarker() {
            if geometryType == .openSpace, measurementStage.wrappedValue == .boundary {
                undoBoundaryMarker()
                if !guidedCornerMeasurements.isEmpty { guidedCornerMeasurements.removeLast() }
                borderScanSnapshot.wrappedValue.acceptedCornerCount = mappedPoints.count
                borderScanSnapshot.wrappedValue.tracePointCount = mappedPoints.count
                borderScanSnapshot.wrappedValue.canFinish = mappedPoints.count >= 3
                borderScanSnapshot.wrappedValue.guidedState = .aiming(index: mappedPoints.count)
                borderScanSnapshot.wrappedValue.status = "Last corner removed"
                showGuidedBoundary()
                return
            }
            switch measurementStage.wrappedValue {
            case .boundary, .review, .bottom:
                undoBoundaryMarker()
            case .top:
                bottomPoint = nil
                topPoint = nil
                replaceMeasuredHeight(nil)
                heightAnchor?.removeFromParent()
                heightAnchor = nil
                measurementStage.wrappedValue = .bottom
            case .frontSelection, .frontConfirmation:
                clearFrontSelection()
                measurementStage.wrappedValue = .frontSelection
            case .complete:
                topPoint = nil
                replaceMeasuredHeight(nil)
                measurementStage.wrappedValue = .top
                showHeightMarkers()
            }
            updateTargetAvailability()
        }

        @MainActor
        private func undoBoundaryMarker() {
            guard !mappedPoints.isEmpty else {
                measurementStage.wrappedValue = .boundary
                return
            }
            mappedPoints.removeLast()
            if !cornerMetadata.isEmpty { cornerMetadata.removeLast() }
            if !measuredSpaceCorners.isEmpty { measuredSpaceCorners.removeLast() }
            rollingSamples.removeAll()
            currentPointEstimate = nil
            mappedPointCount.wrappedValue = mappedPoints.count
            bottomPoint = nil
            topPoint = nil
            heightAnchor?.removeFromParent()
            heightAnchor = nil
            measurementStage.wrappedValue = .boundary

            guard !mappedPoints.isEmpty, let selectedPlane else {
                selectedPlaneID = nil
                self.selectedPlane = nil
                boundaryMeasurement = nil
                selectionAnchor?.removeFromParent()
                selectionAnchor = nil
                measuredSurfaces.wrappedValue = []
                return
            }
            updateMeasurement(on: selectedPlane)
            showMappedArea(on: selectedPlane)
        }

        @MainActor
        private func performPlacementAtCentre() {
            switch measurementStage.wrappedValue {
            case .boundary:
                placeBoundaryPointAtCentre()
            case .review:
                break
            case .bottom:
                placeBottomPointAtCentre()
            case .top:
                placeTopPointAtCentre()
            case .frontSelection, .frontConfirmation:
                break
            case .complete:
                break
            }
        }

        @MainActor
        private func placeBoundaryPointAtCentre() {
            guard !coordinateEpochInvalid,
                  let estimate = currentPointEstimate,
                  estimate.canPlace,
                  let estimatedPosition = estimate.position,
                  let result = centreRaycast(),
                  let plane = result.anchor as? ARPlaneAnchor
            else { return }

            if let selectedPlaneID, selectedPlaneID != plane.identifier {
                return
            }

            if selectedPlaneID == nil {
                selectedPlaneID = plane.identifier
            }
            selectedPlane = plane

            let worldPosition = SIMD4<Float>(
                Float(estimatedPosition.x),
                Float(estimatedPosition.y),
                Float(estimatedPosition.z), 1
            )
            let localPosition = simd_inverse(plane.transform) * worldPosition
            let projectionDistance = abs(Double(localPosition.y))
            guard projectionDistance <= ShelfPointSamplingConfiguration.shelf.maximumSurfaceProjectionMetres else {
                pointStability.wrappedValue = .lowConfidence
                pointGuidance.wrappedValue = "Corner not on selected surface. Aim at the base edge."
                return
            }
            // The base plane is locked by the first corner. Every stored footprint point
            // is projected to that plane; the unprojected world point remains in provenance.
            let point = SIMD3<Float>(localPosition.x, 0, localPosition.z)
            guard !mappedPoints.contains(where: { simd_distance($0, point) < 0.005 }) else {
                pointStability.wrappedValue = .lowConfidence
                pointGuidance.wrappedValue = "That corner was already measured. Aim at the next corner."
                return
            }
            let metadata = ShelfCornerMeasurementMetadata(
                id: UUID(),
                validSampleCount: estimate.validSampleCount,
                rejectedSampleCount: estimate.rejectedSampleCount,
                spreadMetres: estimate.spreadMetres,
                capturedAt: .now,
                trackingWasNormal: true,
                usedLiDAR: hasLiDAR
            )
            if let replacementIndex = pendingReplacementIndex,
               mappedPoints.indices.contains(replacementIndex) {
                mappedPoints[replacementIndex] = point
                if cornerMetadata.indices.contains(replacementIndex) {
                    cornerMetadata[replacementIndex] = metadata
                }
                if measuredSpaceCorners.indices.contains(replacementIndex) {
                    measuredSpaceCorners[replacementIndex] = spaceCornerRecord(
                        estimate: estimate,
                        originalWorldPosition: SIMD3<Float>(estimatedPosition),
                        projectedLocalPosition: point,
                        plane: plane,
                        projectionDistance: projectionDistance
                    )
                }
                pendingReplacementIndex = nil
            } else {
                mappedPoints.append(point)
                cornerMetadata.append(metadata)
                measuredSpaceCorners.append(spaceCornerRecord(
                    estimate: estimate,
                    originalWorldPosition: SIMD3<Float>(estimatedPosition),
                    projectedLocalPosition: point,
                    plane: plane,
                    projectionDistance: projectionDistance
                ))
            }
            rollingSamples.removeAll()
            currentPointEstimate = nil
            cornerTelemetry.wrappedValue = .init()
            mappedPointCount.wrappedValue = mappedPoints.count
            updateMeasurement(on: plane)
            showMappedArea(on: plane)
            updateTargetAvailability()
        }

        private func spaceCornerRecord(
            estimate: ShelfPointEstimate,
            originalWorldPosition: SIMD3<Float>,
            projectedLocalPosition: SIMD3<Float>,
            plane: ARPlaneAnchor,
            projectionDistance: Double
        ) -> MeasuredSpaceCornerRecord {
            let projected = plane.transform * SIMD4<Float>(
                projectedLocalPosition.x, projectedLocalPosition.y, projectedLocalPosition.z, 1
            )
            return MeasuredSpaceCornerRecord(
                id: UUID(),
                originalWorldPosition: Vector3D(SIMD3<Double>(originalWorldPosition)),
                projectedWorldPosition: Vector3D(
                    Double(projected.x), Double(projected.y), Double(projected.z)
                ),
                localBoundaryPositionMetres: Vector2D(
                    Double(projectedLocalPosition.x), Double(projectedLocalPosition.z)
                ),
                sampleCount: estimate.validSampleCount,
                positionalVariance: estimate.spreadMetres * estimate.spreadMetres,
                depthVariance: estimate.depthVariance,
                projectionDistance: projectionDistance,
                measurementDistance: estimate.measurementDistanceMetres,
                measurementSource: estimate.source,
                trackingState: .normal,
                confidenceScore: estimate.confidence,
                timestamp: .now,
                estimatorKind: .manualMultiFrame,
                provenance: .manualFallback,
                estimatedUncertaintyMetres: max(estimate.spreadMetres, 0.012),
                approval: .accepted,
                coordinateEpoch: coordinateEpoch,
                schemaVersion: 1
            )
        }

        @MainActor
        private func placeBottomPointAtCentre() {
            guard let result = centreRaycast() else { return }
            bottomPoint = worldPosition(of: result)
            topPoint = nil
            replaceMeasuredHeight(nil)
            measurementStage.wrappedValue = .top
            showHeightMarkers()
            updateTargetAvailability()
        }

        @MainActor
        private func placeTopPointAtCentre() {
            guard let top = visibleSurfacePointAtCentre(),
                  let bottomPoint,
                  let boundaryMeasurement,
                  let heightMetres = try? ManualMeasurementGeometry.height(
                    top: top,
                    bottom: bottomPoint,
                    boundary: boundaryMeasurement
                  )
            else { return }
            topPoint = top
            replaceMeasuredHeight(heightMetres * 100)
            measurementStage.wrappedValue = .frontSelection
            showHeightMarkers()
            updateTargetAvailability()
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let timestamp = frame.timestamp
            let trackingState = frame.camera.trackingState
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.geometryType == .openSpace,
                   !self.manualBorderCorrection.wrappedValue,
                   self.measurementStage.wrappedValue == .boundary {
                    self.collectSurfaceFirstFrame(frame, trackingState: trackingState)
                } else {
                    self.collectReticleSample(
                        timestamp: timestamp,
                        trackingState: trackingState
                    )
                }
            }
        }

        @MainActor
        private func advanceSurfaceFirstWorkflow() {
            guard hasLiDAR, !coordinateEpochInvalid, surfaceCaptureStartedAt == nil,
                  surfaceCandidate == nil else { return }
            if targetVolume == nil {
                guard let frame = arView?.session.currentFrame,
                      let seed = depthPointAtCentre(frame: frame) else {
                    borderScanSnapshot.wrappedValue.status = "Point broadly at the middle of the compartment"
                    return
                }
                let camera = SIMD3<Float>(frame.camera.transform.columns.3.x,
                                          frame.camera.transform.columns.3.y,
                                          frame.camera.transform.columns.3.z)
                let distance = Double(simd_distance(camera, seed))
                let configuration = SurfaceCaptureConfiguration.standard
                guard distance >= configuration.minimumDepthMetres,
                      distance <= configuration.maximumDepthMetres else {
                    borderScanSnapshot.wrappedValue.status = "The target is outside the validated operating range"
                    borderScanSnapshot.wrappedValue.lastError = .pointOutOfRange
                    return
                }
                coordinateEpoch = UUID()
                let volume = LocalTargetVolume(
                    centre: Vector3D(SIMD3<Double>(seed)),
                    halfExtents: Vector3D(configuration.targetHalfExtentsMetres),
                    coordinateEpoch: coordinateEpoch, seedDepthMetres: distance
                )
                targetVolume = volume
                borderScanSnapshot.wrappedValue.targetVolume = volume
                borderScanSnapshot.wrappedValue.surfaceFirstState = .confirmingTarget
                borderScanSnapshot.wrappedValue.activeSurface = .bottom
                borderScanSnapshot.wrappedValue.status = "Target region confirmed — point at the middle of the shelf bottom"
                pointGuidance.wrappedValue = "Point at the middle of the shelf bottom. Precise corner aiming is not required."
                renderTargetVolume(volume)
                canPlacePoint.wrappedValue = true
                return
            }
            guard let surface = nextSurface else {
                finalizeSurfaceFirstCompartment()
                return
            }
            guard let frame = arView?.session.currentFrame,
                  let selectedSeed = depthPointAtCentre(frame: frame) else {
                borderScanSnapshot.wrappedValue.status = "Point at the middle of the \(surface.scanTitle)"
                return
            }
            surfaceSelectedRegionSeed = Vector3D(SIMD3<Double>(selectedSeed))
            surfaceObservations.removeAll()
            surfaceFrameSequence = 0
            surfaceLastAcceptedCameraTransform = nil
            surfaceLastAcceptedFrameTimestamp = 0
            surfaceCaptureStartedAt = frame.timestamp
            borderScanSnapshot.wrappedValue.surfaceFirstState = .scanningSurface
            borderScanSnapshot.wrappedValue.activeSurface = surface
            borderScanSnapshot.wrappedValue.scanProgress = 0
            borderScanSnapshot.wrappedValue.status = "Scanning \(surface.scanTitle) — move slowly across this surface"
            pointGuidance.wrappedValue = "Move slowly to capture the \(surface.scanTitle) from meaningfully different viewpoints."
            canPlacePoint.wrappedValue = false
        }

        private var nextSurface: CompartmentSurface? {
            surfaceSequence.first { surfaceCaptures[$0] == nil }
        }

        @MainActor
        private func collectSurfaceFirstFrame(
            _ frame: ARFrame, trackingState: ARCamera.TrackingState
        ) {
            guard hasLiDAR else {
                borderScanSnapshot.wrappedValue.surfaceFirstState = .failed
                borderScanSnapshot.wrappedValue.lastError = .lidarUnavailable
                return
            }
            guard case .normal = trackingState else {
                if case .limited(.relocalizing) = trackingState, targetVolume != nil {
                    coordinateEpochInvalid = true
                    surfaceCaptureStartedAt = nil
                    surfaceObservations.removeAll()
                    borderScanSnapshot.wrappedValue.surfaceFirstState = .failed
                    borderScanSnapshot.wrappedValue.lastError = .inconsistentCoordinateSystem
                    borderScanSnapshot.wrappedValue.status = "Tracking origin changed — restart the compartment scan"
                } else {
                    borderScanSnapshot.wrappedValue.status = "Tracking is limited — keep observed surfaces visible"
                    borderScanSnapshot.wrappedValue.lastError = .trackingUnavailable
                }
                canPlacePoint.wrappedValue = false
                return
            }
            guard !coordinateEpochInvalid else { return }
            guard let started = surfaceCaptureStartedAt,
                  let volume = targetVolume,
                  let active = nextSurface,
                  let selectedSeed = surfaceSelectedRegionSeed else {
                canPlacePoint.wrappedValue = true
                updateTargetAppearance(isValid: true)
                return
            }
            let elapsed = frame.timestamp - started
            borderScanSnapshot.wrappedValue.scanProgress = min(elapsed / 3.2, 1)
            guard isIndependentSurfaceFrame(frame) else {
                if elapsed >= 4.5 { finishSurfaceCapture(active, volume: volume, seed: selectedSeed) }
                return
            }
            surfaceFrameSequence += 1
            surfaceObservations.append(contentsOf: depthSurfaceObservations(
                frame: frame, volume: volume, sequence: surfaceFrameSequence
            ))
            surfaceLastAcceptedCameraTransform = frame.camera.transform
            surfaceLastAcceptedFrameTimestamp = frame.timestamp
            cornerTelemetry.wrappedValue = CornerMeasurementTelemetry(
                source: frame.smoothedSceneDepth == nil ? .sceneDepth : .smoothedSceneDepth,
                tracking: .normal, distanceMetres: volume.seedDepthMetres,
                surfaceHeightDifferenceMetres: nil, sampleCount: surfaceObservations.count,
                confidence: surfaceObservations.map(\.depthConfidence).max()
            )
            if elapsed >= 2.4, surfaceFrameSequence >= SurfaceCaptureConfiguration.standard.minimumIndependentViews {
                finishSurfaceCapture(active, volume: volume, seed: selectedSeed, allowMoreEvidence: elapsed < 3.8)
            } else if elapsed >= 4.5 {
                finishSurfaceCapture(active, volume: volume, seed: selectedSeed)
            }
        }

        private func isIndependentSurfaceFrame(_ frame: ARFrame) -> Bool {
            guard let previous = surfaceLastAcceptedCameraTransform else { return true }
            let configuration = SurfaceCaptureConfiguration.standard
            let oldPosition = SIMD3<Float>(previous.columns.3.x, previous.columns.3.y, previous.columns.3.z)
            let newPosition = SIMD3<Float>(frame.camera.transform.columns.3.x,
                                           frame.camera.transform.columns.3.y,
                                           frame.camera.transform.columns.3.z)
            let oldForward = -SIMD3<Float>(previous.columns.2.x, previous.columns.2.y, previous.columns.2.z)
            let newForward = -SIMD3<Float>(frame.camera.transform.columns.2.x,
                                           frame.camera.transform.columns.2.y, frame.camera.transform.columns.2.z)
            let angle = acos(max(-1, min(1, simd_dot(simd_normalize(oldForward), simd_normalize(newForward)))))
            return Double(simd_distance(oldPosition, newPosition)) >= configuration.minimumCameraTranslationMetres
                || Double(angle) >= configuration.minimumViewingAngleRadians
        }

        private func depthSurfaceObservations(
            frame: ARFrame, volume: LocalTargetVolume, sequence: Int
        ) -> [SurfaceCaptureObservation] {
            guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return [] }
            let depthMap = depthData.depthMap, confidenceMap = depthData.confidenceMap
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
            defer {
                CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
                if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
            }
            guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return [] }
            let width = CVPixelBufferGetWidth(depthMap), height = CVPixelBufferGetHeight(depthMap)
            let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
            let depths = depthBase.assumingMemoryBound(to: Float32.self)
            let confidences = confidenceMap.flatMap(CVPixelBufferGetBaseAddress)?.assumingMemoryBound(to: UInt8.self)
            let confidenceStride = confidenceMap.map(CVPixelBufferGetBytesPerRow) ?? 0
            let scaleX = Double(width) / Double(frame.camera.imageResolution.width)
            let focal = Double(frame.camera.intrinsics.columns.0.x) * scaleX
            let radius = AdaptiveDepthSampling.pixelRadius(
                seedDepthMetres: volume.seedDepthMetres, focalLengthPixels: focal
            )
            let pixelStep = max(2, radius / 14)
            let centreX = width / 2, centreY = height / 2
            let camera = SIMD3<Double>(Double(frame.camera.transform.columns.3.x),
                                       Double(frame.camera.transform.columns.3.y),
                                       Double(frame.camera.transform.columns.3.z))
            var result: [SurfaceCaptureObservation] = []
            for y in stride(from: max(0, centreY - radius), through: min(height - 1, centreY + radius), by: pixelStep) {
                for x in stride(from: max(0, centreX - radius), through: min(width - 1, centreX + radius), by: pixelStep) {
                    let depth = depths[y * depthStride + x]
                    let level = confidences.map { $0[y * confidenceStride + x] }
                        ?? UInt8(ARConfidenceLevel.medium.rawValue)
                    let confidence = Double(level) / Double(ARConfidenceLevel.high.rawValue)
                    guard depth.isFinite,
                          Double(depth) >= SurfaceCaptureConfiguration.standard.minimumDepthMetres,
                          Double(depth) <= SurfaceCaptureConfiguration.standard.maximumDepthMetres,
                          confidence >= SurfaceCaptureConfiguration.standard.minimumDepthConfidence,
                          let world = worldPoint(depthPixelX: x, y: y, depth: depth,
                                                 depthWidth: width, depthHeight: height, frame: frame)
                    else { continue }
                    let point = Vector3D(SIMD3<Double>(world))
                    guard volume.contains(point) else { continue }
                    var normal: Vector3D?
                    if x + pixelStep < width, y + pixelStep < height {
                        let dx = depths[y * depthStride + x + pixelStep]
                        let dy = depths[(y + pixelStep) * depthStride + x]
                        if dx.isFinite, dy.isFinite,
                           let wx = worldPoint(depthPixelX: x + pixelStep, y: y, depth: dx,
                                               depthWidth: width, depthHeight: height, frame: frame),
                           let wy = worldPoint(depthPixelX: x, y: y + pixelStep, depth: dy,
                                               depthWidth: width, depthHeight: height, frame: frame) {
                            let value = simd_cross(SIMD3<Double>(wx - world), SIMD3<Double>(wy - world))
                            if simd_length(value) > 1e-8 { normal = Vector3D(simd_normalize(value)) }
                        }
                    }
                    let direction = simd_normalize(point.simd - camera)
                    result.append(SurfaceCaptureObservation(
                        id: UUID(), position: point, normal: normal,
                        cameraPosition: Vector3D(camera), viewingDirection: Vector3D(direction),
                        depthConfidence: confidence, trackingState: .normal,
                        frameSequence: sequence, timestamp: frame.timestamp,
                        coordinateEpoch: coordinateEpoch
                    ))
                }
            }
            return result
        }

        @MainActor
        private func finishSurfaceCapture(
            _ surface: CompartmentSurface, volume: LocalTargetVolume, seed: Vector3D,
            allowMoreEvidence: Bool = false
        ) {
            let accepted = surfaceCaptures.values.map(\.fittedPlane)
            switch SurfaceFirstPlaneEstimator.fit(
                surface: surface, observations: surfaceObservations,
                targetVolume: volume, selectedRegionSeed: seed, acceptedSurfaces: accepted
            ) {
            case .success(let record):
                surfaceCandidate = record
                surfaceCaptureStartedAt = nil
                borderScanSnapshot.wrappedValue.surfaceCandidate = record
                borderScanSnapshot.wrappedValue.surfaceFirstState = .reviewingSurface
                borderScanSnapshot.wrappedValue.scanProgress = 1
                borderScanSnapshot.wrappedValue.confidenceLevel = record.fittedPlane.uncertaintyMetres <= 0.008 ? .high : .medium
                borderScanSnapshot.wrappedValue.status = "\(surface.scanTitle.capitalized) surface found — inspect and accept or rescan"
                pointGuidance.wrappedValue = "Review the fitted \(surface.scanTitle) surface."
                renderSurfaceEvidence(record)
            case .failure(let error):
                if allowMoreEvidence { return }
                renderRejectedSurfaceEvidence(
                    surfaceObservations,
                    conflicting: error == .ambiguousSurfaces
                )
                surfaceCaptureStartedAt = nil
                surfaceObservations.removeAll()
                borderScanSnapshot.wrappedValue.surfaceFirstState = .confirmingTarget
                borderScanSnapshot.wrappedValue.status = error.localizedDescription
                borderScanSnapshot.wrappedValue.lastError = .unstableMeasurement
                canPlacePoint.wrappedValue = true
            }
        }

        @MainActor
        private func acceptSurfaceCandidate() {
            guard var candidate = surfaceCandidate,
                  candidate.coordinateEpoch == coordinateEpoch else { return }
            candidate.approval = .accepted
            surfaceCaptures[candidate.surface] = candidate
            surfaceCandidate = nil
            surfaceObservations.removeAll()
            borderScanSnapshot.wrappedValue.surfaceCandidate = nil
            borderScanSnapshot.wrappedValue.acceptedSurfaces = surfaceSequence.filter { surfaceCaptures[$0] != nil }
            borderScanSnapshot.wrappedValue.acceptedCornerCount = surfaceCaptures.count
            recomputeSurfaceCorners()
            if let next = nextSurface {
                borderScanSnapshot.wrappedValue.activeSurface = next
                borderScanSnapshot.wrappedValue.surfaceFirstState = .confirmingTarget
                borderScanSnapshot.wrappedValue.status = "\(candidate.surface.scanTitle.capitalized) accepted — point at the middle of the \(next.scanTitle)"
                pointGuidance.wrappedValue = "Point at the middle of the \(next.scanTitle)."
                canPlacePoint.wrappedValue = true
            } else {
                borderScanSnapshot.wrappedValue.surfaceFirstState = .reviewingGeometry
                if borderScanSnapshot.wrappedValue.compartmentDimensions != nil {
                    borderScanSnapshot.wrappedValue.status = "Supporting surfaces accepted — review calculated corners and dimensions"
                    borderScanSnapshot.wrappedValue.canFinish = !borderScanSnapshot.wrappedValue.calculatedCorners.isEmpty
                } else {
                    borderScanSnapshot.wrappedValue.status = "Accepted planes contradict a rectangular compartment — rescan the highlighted surface"
                    borderScanSnapshot.wrappedValue.canFinish = false
                }
                canPlacePoint.wrappedValue = false
            }
        }

        @MainActor
        private func discardSurfaceCandidate() {
            surfaceCandidate = nil
            surfaceObservations.removeAll()
            surfaceCaptureStartedAt = nil
            borderScanSnapshot.wrappedValue.surfaceCandidate = nil
            borderScanSnapshot.wrappedValue.surfaceFirstState = .confirmingTarget
            if let next = nextSurface {
                borderScanSnapshot.wrappedValue.status = "Point at the middle of the \(next.scanTitle) and rescan"
            }
            canPlacePoint.wrappedValue = true
        }

        @MainActor
        private func recomputeSurfaceCorners() {
            guard let volume = targetVolume else { return }
            let planes = Dictionary(uniqueKeysWithValues: surfaceCaptures.map { ($0.key, $0.value.fittedPlane) })
            let combinations: [[CompartmentSurface]] = [
                [.bottom, .left, .back], [.bottom, .right, .back],
                [.top, .left, .back], [.top, .right, .back],
                [.bottom, .left, .frontOpening], [.bottom, .right, .frontOpening],
                [.top, .left, .frontOpening], [.top, .right, .frontOpening]
            ]
            let corners = combinations.compactMap { surfaces -> CompartmentCornerEvidence? in
                guard let a = planes[surfaces[0]], let b = planes[surfaces[1]], let c = planes[surfaces[2]],
                      case .success(let corner) = CompartmentPlaneGeometry.intersect(a, b, c, targetVolume: volume)
                else { return nil }
                return corner
            }
            let assessment = RectangularCompartmentEvaluator.evaluate(planes: Array(planes.values))
            let dimensions = assessment.approval == .rejected
                ? nil
                : CompartmentPlaneGeometry.dimensions(planes: Array(planes.values))
            borderScanSnapshot.wrappedValue.calculatedCorners = corners
            borderScanSnapshot.wrappedValue.compartmentDimensions = dimensions
            if let dimensions { publishSurfaceFirstDraft(corners: corners, dimensions: dimensions) }
            if nextSurface == nil, let failure = assessment.failureReason {
                borderScanSnapshot.wrappedValue.status = failure
                borderScanSnapshot.wrappedValue.canFinish = false
            }
            renderAcceptedSurfaceGeometry(corners: corners)
        }

        private func publishSurfaceFirstDraft(
            corners: [CompartmentCornerEvidence], dimensions: CompartmentDimensions
        ) {
            guard let volume = targetVolume else { return }
            let localBoundary = [
                Vector3D(0, 0, 0), Vector3D(dimensions.interiorWidthMetres, 0, 0),
                Vector3D(dimensions.interiorWidthMetres, 0, dimensions.interiorDepthMetres),
                Vector3D(0, 0, dimensions.interiorDepthMetres)
            ]
            let uncertainty = surfaceCaptures.values.map { $0.fittedPlane.uncertaintyMetres }.max() ?? 0.05
            var measuredDimensions = [
                dimensions.interiorWidthMetres, dimensions.interiorDepthMetres
            ]
            if let height = dimensions.interiorHeightMetres { measuredDimensions.append(height) }
            if let openingWidth = dimensions.openingWidthMetres { measuredDimensions.append(openingWidth) }
            if let openingHeight = dimensions.openingHeightMetres { measuredDimensions.append(openingHeight) }
            let dimensionDiagnostics = measuredDimensions.map { measured in
                DimensionUncertainty(
                    measuredMetres: measured,
                    estimatedUncertaintyMetres: dimensions.uncertaintyMetres,
                    robustFitResidualMetres: surfaceCaptures.values.map { $0.fittedPlane.rmsResidualMetres }.max() ?? 0,
                    repeatabilityMetres: uncertainty,
                    spatialCoverage: surfaceCaptures.values.map { min($0.coverageFirstAxisMetres, $0.coverageSecondAxisMetres) }.min() ?? 0,
                    viewingDiversityRadians: surfaceCaptures.values.map { $0.fittedPlane.viewingDiversityRadians }.min() ?? 0,
                    closureErrorMetres: 0, inferencePenaltyMetres: 0,
                    correctionDisplacementMetres: 0, correlatedSampleFraction: 0
                )
            }
            let record = SurfaceFirstCompartmentRecord(
                targetVolume: volume, surfaces: surfaceSequence.compactMap { surfaceCaptures[$0] },
                corners: corners, dimensions: dimensions, rectangularCorrectionApproved: false,
                approval: .proposed, schemaVersion: 1
            )
            let plane = surfaceCaptures[.bottom]?.fittedPlane.plane
                ?? CodablePlane(origin: volume.centre, normal: Vector3D(0, 1, 0))
            let polygon = localBoundary.map { Vector2D($0.x, $0.z) }
            let boundary = ScannedStorageBoundary(
                id: UUID(), basePlane: plane, surfaceType: surfaceType,
                rawTrace: [], detectedSegments: [], detectedCorners: [],
                simplifiedPolygon: polygon, approvedPolygon: [], suggestedPolygon: nil,
                geometryConfidence: max(0, 1 - uncertainty / 0.05),
                validationState: dimensions.hasVerifiedUsableOpening ? .valid : .draft,
                processingMetrics: .init(maximumSimplificationDisplacementMetres: 0,
                                         averageSimplificationDisplacementMetres: 0,
                                         inferredGapLengthMetres: 0, manualEditCount: 0),
                measurementMethod: .fittedCompartmentPlanes, deviceHasLiDAR: true,
                schemaVersion: 7, createdAt: .now, updatedAt: .now,
                shapeIntent: .rectangularCompartment, acquisitionSections: nil,
                circleFit: nil, dimensionUncertainties: dimensionDiagnostics,
                approvalState: .proposed,
                globalMapUncertaintyMetres: dimensions.uncertaintyMetres,
                localPlacementUncertaintyMetres: dimensions.uncertaintyMetres,
                guidedCornerMeasurements: nil, surfaceFirstCompartment: record
            )
            let geometry = ShelfGeometryRecord(
                version: 2, inputRevision: UUID(), rawBoundary: localBoundary,
                correctedBoundary: nil, approvedBoundary: [], detectedShapeType: .rectangle,
                requestedShapeIntent: .rectangular, boundaryMeaning: .innerUsable,
                correctionConfidence: 0, scanConfidence: boundary.geometryConfidence,
                correctionReasons: [], approval: .draft, approvedAt: nil,
                placementSafetyMarginCM: ShelfBoundaryAnalysisConfiguration.shelf.placementSafetyMarginCM,
                measurementMetadata: ShelfMeasurementMetadata(
                    capturedAt: .now, deviceModel: ObjectScannerCapabilities.deviceModelIdentifier,
                    hasLiDAR: true, coordinateSpace: .shelfLocal, unit: .metres,
                    planeRMSResidualMetres: surfaceCaptures.values.map { $0.fittedPlane.rmsResidualMetres }.max() ?? 0,
                    planeMaximumResidualMetres: surfaceCaptures.values.map { $0.fittedPlane.maximumResidualMetres }.max() ?? 0,
                    cornerMeasurements: [], expectedWidthCM: nil, expectedDepthCM: nil
                )
            )
            measuredSurfaces.wrappedValue = [MeasuredShelfSurface(
                id: boundary.id, widthCM: dimensions.interiorWidthMetres * 100,
                depthCM: dimensions.interiorDepthMetres * 100,
                measuredFreeHeightCM: dimensions.interiorHeightMetres.map { $0 * 100 },
                frontDirectionLocal: nil, originLocal: .init(0, 0, 0),
                scanConfidence: boundary.geometryConfidence,
                boundaryClosed: dimensions.hasVerifiedUsableOpening,
                geometry: geometry, boundaryAnalysis: nil, cornerMetadata: [],
                measuredSpaceCorners: [], scannedBoundary: boundary
            )]
            mappedPointCount.wrappedValue = corners.count
        }

        @MainActor
        private func confirmUsableOpening() {
            guard var dimensions = borderScanSnapshot.wrappedValue.compartmentDimensions,
                  nextSurface == nil else { return }
            // Explicitly confirming that no lip/track/trim reduces the passage is
            // the only case where the interior cross-section may define opening.
            dimensions.openingWidthMetres = dimensions.interiorWidthMetres
            dimensions.openingHeightMetres = dimensions.interiorHeightMetres
            dimensions.hasVerifiedUsableOpening = dimensions.interiorHeightMetres != nil
            borderScanSnapshot.wrappedValue.compartmentDimensions = dimensions
            borderScanSnapshot.wrappedValue.canFinish = dimensions.hasVerifiedUsableOpening
            borderScanSnapshot.wrappedValue.status = dimensions.hasVerifiedUsableOpening
                ? "Usable opening confirmed — calculate and approve geometry"
                : "Top surface is required before the opening can be confirmed"
            publishSurfaceFirstDraft(
                corners: borderScanSnapshot.wrappedValue.calculatedCorners,
                dimensions: dimensions
            )
        }

        @MainActor
        private func finalizeSurfaceFirstCompartment() {
            guard nextSurface == nil, let volume = targetVolume else {
                if let next = nextSurface {
                    borderScanSnapshot.wrappedValue.status = "Scan and accept the \(next.scanTitle) before calculating corners"
                }
                return
            }
            recomputeSurfaceCorners()
            let corners = borderScanSnapshot.wrappedValue.calculatedCorners
            guard corners.count == 8, let dimensions = borderScanSnapshot.wrappedValue.compartmentDimensions else {
                borderScanSnapshot.wrappedValue.status = "Corner uncertainty is too high—rescan the highlighted supporting surface"
                return
            }
            let record = SurfaceFirstCompartmentRecord(
                targetVolume: volume,
                surfaces: surfaceSequence.compactMap { surfaceCaptures[$0] }, corners: corners,
                dimensions: dimensions, rectangularCorrectionApproved: false,
                approval: .proposed, schemaVersion: 1
            )
            // A fitted front plane defines depth, but a lip/track can still make the
            // passage smaller. Keep the opening unverified and refuse fit authorization.
            guard dimensions.hasVerifiedUsableOpening else {
                borderScanSnapshot.wrappedValue.surfaceFirstState = .reviewingGeometry
                borderScanSnapshot.wrappedValue.status = "Interior measured; usable opening is unverified. Measure the lip/frame or enter opening dimensions."
                borderScanSnapshot.wrappedValue.canFinish = false
                persistSurfaceFirstDiagnostics(record)
                return
            }
            guard let measured = measuredSurfaces.wrappedValue.first,
                  var boundary = measured.scannedBoundary,
                  var geometry = measured.geometry else { return }
            var approvedRecord = record
            approvedRecord.approval = .approvedRaw
            boundary.surfaceFirstCompartment = approvedRecord
            boundary.validationState = .valid
            boundary.approvedPolygon = boundary.simplifiedPolygon
            boundary.approvalState = .approvedRaw
            geometry.approvedBoundary = geometry.rawBoundary
            geometry.approval = .approvedRaw
            geometry.approvedAt = .now
            measuredSurfaces.wrappedValue = [MeasuredShelfSurface(
                id: measured.id, widthCM: measured.widthCM, depthCM: measured.depthCM,
                measuredFreeHeightCM: measured.measuredFreeHeightCM,
                frontDirectionLocal: Vector3D(0, 0, 1), originLocal: Vector3D(0, 0, 0),
                scanConfidence: measured.scanConfidence, boundaryClosed: true,
                geometry: geometry, boundaryAnalysis: measured.boundaryAnalysis,
                cornerMetadata: measured.cornerMetadata,
                measuredSpaceCorners: measured.measuredSpaceCorners,
                scannedBoundary: boundary
            )]
            borderScanSnapshot.wrappedValue.surfaceFirstState = .completed
            borderScanSnapshot.wrappedValue.status = "Compartment approved — confirm the opening-to-back access direction"
            measurementStage.wrappedValue = .frontConfirmation
        }

        private func persistSurfaceFirstDiagnostics(_ record: SurfaceFirstCompartmentRecord) {
            guard let surface = measuredSurfaces.wrappedValue.first,
                  var boundary = surface.scannedBoundary else { return }
            boundary.surfaceFirstCompartment = record
            boundary.schemaVersion = max(boundary.schemaVersion, 7)
            measuredSurfaces.wrappedValue = [surface.replacingScannedBoundary(boundary)]
        }

        @MainActor
        private func renderTargetVolume(_ volume: LocalTargetVolume) {
            guard let arView else { return }
            surfaceEvidenceAnchor?.removeFromParent()
            let anchor = AnchorEntity(world: matrix_identity_float4x4)
            var material = UnlitMaterial()
            material.color = .init(tint: UIColor.systemCyan.withAlphaComponent(0.10), texture: nil)
            let box = ModelEntity(
                mesh: .generateBox(width: Float(volume.halfExtents.x * 2),
                                   height: Float(volume.halfExtents.y * 2),
                                   depth: Float(volume.halfExtents.z * 2)), materials: [material]
            )
            box.position = SIMD3(Float(volume.centre.x), Float(volume.centre.y), Float(volume.centre.z))
            anchor.addChild(box)
            arView.scene.addAnchor(anchor)
            surfaceEvidenceAnchor = anchor
        }

        @MainActor
        private func renderSurfaceEvidence(_ record: SurfaceCaptureRecord) {
            guard let arView else { return }
            surfaceEvidenceAnchor?.removeFromParent()
            let anchor = AnchorEntity(world: matrix_identity_float4x4)
            let accepted = Set(record.acceptedObservationIDs)
            for observation in record.diagnosticObservations.prefix(180) {
                var material = UnlitMaterial()
                material.color = .init(tint: accepted.contains(observation.id)
                    ? UIColor.systemGreen.withAlphaComponent(0.8)
                    : UIColor.systemGray.withAlphaComponent(0.35), texture: nil)
                let point = ModelEntity(mesh: .generateSphere(radius: 0.003), materials: [material])
                point.position = SIMD3(Float(observation.position.x), Float(observation.position.y), Float(observation.position.z))
                anchor.addChild(point)
            }
            var planeMaterial = UnlitMaterial()
            planeMaterial.color = .init(tint: UIColor.systemGreen.withAlphaComponent(0.22), texture: nil)
            let sheet = ModelEntity(
                mesh: .generatePlane(width: Float(record.coverageFirstAxisMetres),
                                     depth: Float(record.coverageSecondAxisMetres)),
                materials: [planeMaterial]
            )
            sheet.position = SIMD3(Float(record.fittedPlane.plane.origin.x),
                                   Float(record.fittedPlane.plane.origin.y),
                                   Float(record.fittedPlane.plane.origin.z))
            sheet.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0),
                                           to: SIMD3<Float>(record.fittedPlane.plane.normal.normalized.simd))
            anchor.addChild(sheet)
            arView.scene.addAnchor(anchor)
            surfaceEvidenceAnchor = anchor
        }

        @MainActor
        private func renderRejectedSurfaceEvidence(
            _ observations: [SurfaceCaptureObservation], conflicting: Bool
        ) {
            guard let arView else { return }
            surfaceEvidenceAnchor?.removeFromParent()
            let anchor = AnchorEntity(world: matrix_identity_float4x4)
            for observation in observations.prefix(180) {
                var material = UnlitMaterial()
                material.color = .init(
                    tint: (conflicting ? UIColor.systemRed : UIColor.systemGray).withAlphaComponent(0.5),
                    texture: nil
                )
                let point = ModelEntity(mesh: .generateSphere(radius: 0.003), materials: [material])
                point.position = SIMD3(Float(observation.position.x), Float(observation.position.y), Float(observation.position.z))
                anchor.addChild(point)
            }
            arView.scene.addAnchor(anchor)
            surfaceEvidenceAnchor = anchor
        }

        @MainActor
        private func renderAcceptedSurfaceGeometry(corners: [CompartmentCornerEvidence]) {
            guard let arView else { return }
            surfaceEvidenceAnchor?.removeFromParent()
            let anchor = AnchorEntity(world: matrix_identity_float4x4)
            let colors: [CompartmentSurface: UIColor] = [
                .bottom: .systemGreen, .back: .systemBlue, .left: .systemOrange,
                .right: .systemPurple, .top: .systemYellow, .frontOpening: .systemTeal
            ]
            for surface in surfaceSequence {
                guard let capture = surfaceCaptures[surface] else { continue }
                var material = UnlitMaterial()
                material.color = .init(tint: (colors[surface] ?? .white).withAlphaComponent(0.20), texture: nil)
                let sheet = ModelEntity(
                    mesh: .generatePlane(width: Float(capture.coverageFirstAxisMetres),
                                         depth: Float(capture.coverageSecondAxisMetres)),
                    materials: [material]
                )
                sheet.position = SIMD3(Float(capture.fittedPlane.plane.origin.x),
                                       Float(capture.fittedPlane.plane.origin.y),
                                       Float(capture.fittedPlane.plane.origin.z))
                sheet.orientation = simd_quatf(
                    from: SIMD3<Float>(0, 1, 0),
                    to: SIMD3<Float>(capture.fittedPlane.plane.normal.normalized.simd)
                )
                anchor.addChild(sheet)
            }
            for corner in corners {
                var markerMaterial = UnlitMaterial()
                markerMaterial.color = .init(tint: .systemPink, texture: nil)
                let marker = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [markerMaterial])
                marker.position = SIMD3(Float(corner.position.x), Float(corner.position.y), Float(corner.position.z))
                anchor.addChild(marker)
                var uncertaintyMaterial = UnlitMaterial()
                uncertaintyMaterial.color = .init(tint: UIColor.systemPink.withAlphaComponent(0.15), texture: nil)
                let uncertainty = ModelEntity(
                    mesh: .generateSphere(radius: Float(min(max(corner.uncertaintyMetres, 0.004), 0.08))),
                    materials: [uncertaintyMaterial]
                )
                uncertainty.position = marker.position
                anchor.addChild(uncertainty)
            }
            for first in corners.indices {
                for second in corners.indices where second > first {
                    let shared = Set(corners[first].supportingSurfaces)
                        .intersection(corners[second].supportingSurfaces).count
                    if shared == 2 {
                        anchor.addChild(spatialLine(
                            from: SIMD3(Float(corners[first].position.x),
                                        Float(corners[first].position.y),
                                        Float(corners[first].position.z)),
                            to: SIMD3(Float(corners[second].position.x),
                                      Float(corners[second].position.y),
                                      Float(corners[second].position.z)),
                            color: .systemCyan
                        ))
                    }
                }
            }
            arView.scene.addAnchor(anchor)
            surfaceEvidenceAnchor = anchor
        }

        @MainActor
        private func startGuidedCornerScan() {
            guard geometryType == .openSpace, hasLiDAR, !coordinateEpochInvalid,
                  measurementStage.wrappedValue == .boundary,
                  selectedPlane != nil, guidedCaptureStartedAt == nil else { return }
            guidedCandidate = nil
            guidedPatchSamples.removeAll()
            guidedFrameSequence = 0
            guidedLastAcceptedCameraTransform = nil
            guidedLastAcceptedFrameTimestamp = 0
            guidedCaptureStartedAt = arView?.session.currentFrame?.timestamp
            let index = pendingReplacementIndex ?? mappedPoints.count
            borderScanSnapshot.wrappedValue.candidate = nil
            borderScanSnapshot.wrappedValue.scanProgress = 0
            borderScanSnapshot.wrappedValue.guidedState = .scanning(index: index, progress: 0)
            borderScanSnapshot.wrappedValue.status = "Scanning corner \(index + 1) — move slightly to reveal both sides"
            pointGuidance.wrappedValue = "Keep the reticle on the physical corner for 1–2 seconds."
            canPlacePoint.wrappedValue = false
            updateTargetAppearance(isValid: false)
        }

        @MainActor
        private func collectGuidedCornerFrame(
            _ frame: ARFrame,
            trackingState: ARCamera.TrackingState
        ) {
            guard hasLiDAR else {
                borderScanSnapshot.wrappedValue.guidedState = .failed(.lidarUnavailable)
                borderScanSnapshot.wrappedValue.lastError = .lidarUnavailable
                return
            }
            guard case .normal = trackingState else {
                guidedCandidate = nil
                guidedPatchSamples.removeAll()
                guidedCaptureStartedAt = nil
                borderScanSnapshot.wrappedValue.candidate = nil
                borderScanSnapshot.wrappedValue.scanProgress = 0
                canPlacePoint.wrappedValue = false
                if case .limited(.relocalizing) = trackingState {
                    if mappedPoints.isEmpty {
                        coordinateEpoch = UUID()
                        selectedPlane = nil
                        selectedPlaneID = nil
                        borderScanSnapshot.wrappedValue.guidedState = .findingBasePlane
                        borderScanSnapshot.wrappedValue.status = "Tracking changed — relock the base plane"
                    } else {
                        coordinateEpochInvalid = true
                        borderScanSnapshot.wrappedValue.guidedState = .failed(.inconsistentCoordinateSystem)
                        borderScanSnapshot.wrappedValue.lastError = .inconsistentCoordinateSystem
                        borderScanSnapshot.wrappedValue.status = "Coordinate system changed — restart boundary"
                    }
                } else {
                    borderScanSnapshot.wrappedValue.status = "Tracking unstable — hold still"
                    borderScanSnapshot.wrappedValue.lastError = .trackingUnavailable
                }
                updateTargetAppearance(isValid: false)
                return
            }
            guard !coordinateEpochInvalid else { return }
            if selectedPlane == nil {
                guard let result = centreRaycast(), let plane = result.anchor as? ARPlaneAnchor else {
                    borderScanSnapshot.wrappedValue.guidedState = .findingBasePlane
                    borderScanSnapshot.wrappedValue.status = "Find and lock the base storage plane"
                    canPlacePoint.wrappedValue = false
                    updateTargetAppearance(isValid: false)
                    return
                }
                selectedPlane = plane
                selectedPlaneID = plane.identifier
                coordinateEpoch = UUID()
                borderScanSnapshot.wrappedValue.guidedState = .aiming(index: pendingReplacementIndex ?? mappedPoints.count)
                borderScanSnapshot.wrappedValue.status = "Base locked — aim at corner \((pendingReplacementIndex ?? mappedPoints.count) + 1)"
                pointGuidance.wrappedValue = "Aim at the physical corner, then press Scan Corner."
            }
            guard let started = guidedCaptureStartedAt else {
                canPlacePoint.wrappedValue = true
                updateTargetAppearance(isValid: true)
                return
            }
            let elapsed = frame.timestamp - started
            let progress = min(max(elapsed / CornerEstimatorConfiguration.standard.maximumCaptureDurationSeconds, 0), 1)
            let index = pendingReplacementIndex ?? mappedPoints.count
            borderScanSnapshot.wrappedValue.scanProgress = progress
            borderScanSnapshot.wrappedValue.guidedState = .scanning(index: index, progress: progress)
            guard isIndependentGuidedFrame(frame) else {
                if elapsed >= CornerEstimatorConfiguration.standard.maximumCaptureDurationSeconds {
                    finishGuidedCornerCapture(frameTimestamp: frame.timestamp)
                }
                return
            }
            guidedFrameSequence += 1
            guidedPatchSamples.append(contentsOf: depthPatchSamples(
                frame: frame, plane: selectedPlane!, sequence: guidedFrameSequence
            ))
            guidedLastAcceptedCameraTransform = frame.camera.transform
            guidedLastAcceptedFrameTimestamp = frame.timestamp
            cornerTelemetry.wrappedValue.sampleCount = guidedPatchSamples.count
            cornerTelemetry.wrappedValue.tracking = .normal
            if elapsed >= CornerEstimatorConfiguration.standard.minimumCaptureDurationSeconds,
               guidedFrameSequence >= CornerEstimatorConfiguration.standard.minimumIndependentFrames {
                finishGuidedCornerCapture(frameTimestamp: frame.timestamp, allowMoreEvidence: elapsed < 1.45)
            } else if elapsed >= CornerEstimatorConfiguration.standard.maximumCaptureDurationSeconds {
                finishGuidedCornerCapture(frameTimestamp: frame.timestamp)
            }
        }

        private func isIndependentGuidedFrame(_ frame: ARFrame) -> Bool {
            guard frame.timestamp - guidedLastAcceptedFrameTimestamp >= 0.12 else { return false }
            guard let previous = guidedLastAcceptedCameraTransform else { return true }
            let oldPosition = SIMD3<Float>(previous.columns.3.x, previous.columns.3.y, previous.columns.3.z)
            let newPosition = SIMD3<Float>(frame.camera.transform.columns.3.x,
                                           frame.camera.transform.columns.3.y,
                                           frame.camera.transform.columns.3.z)
            let oldForward = -SIMD3<Float>(previous.columns.2.x, previous.columns.2.y, previous.columns.2.z)
            let newForward = -SIMD3<Float>(frame.camera.transform.columns.2.x,
                                           frame.camera.transform.columns.2.y,
                                           frame.camera.transform.columns.2.z)
            let angle = acos(max(-1, min(1, simd_dot(simd_normalize(oldForward), simd_normalize(newForward)))))
            return simd_distance(oldPosition, newPosition) >= 0.0025
                || angle >= 0.5 * .pi / 180
                || frame.timestamp - guidedLastAcceptedFrameTimestamp >= 0.28
        }

        private func depthPatchSamples(
            frame: ARFrame, plane: ARPlaneAnchor, sequence: Int
        ) -> [LocalCornerPatchSample] {
            guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return [] }
            let buffer = depthData.depthMap
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let row = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float32>.size
            let values = base.assumingMemoryBound(to: Float32.self)
            let centreX = width / 2, centreY = height / 2
            let inverse = simd_inverse(plane.transform)
            let cameraWorld = SIMD4<Float>(frame.camera.transform.columns.3.x,
                                           frame.camera.transform.columns.3.y,
                                           frame.camera.transform.columns.3.z, 1)
            let cameraLocal4 = inverse * cameraWorld
            let cameraLocal = Vector3D(Double(cameraLocal4.x), Double(cameraLocal4.y), Double(cameraLocal4.z))
            var result: [LocalCornerPatchSample] = []
            for y in stride(from: centreY - 14, through: centreY + 14, by: 2) {
                for x in stride(from: centreX - 14, through: centreX + 14, by: 2) {
                    guard x >= 0, x < width, y >= 0, y < height else { continue }
                    let depth = values[y * row + x]
                    guard depth.isFinite, depth >= 0.10, depth <= 5,
                          let world = worldPoint(depthPixelX: x, y: y, depth: depth,
                                                 depthWidth: width, depthHeight: height, frame: frame)
                    else { continue }
                    let local = inverse * SIMD4<Float>(world.x, world.y, world.z, 1)
                    guard local.x.isFinite, local.y.isFinite, local.z.isFinite,
                          abs(local.y) <= 0.60 else { continue }
                    result.append(LocalCornerPatchSample(
                        id: UUID(),
                        localPosition: Vector3D(Double(local.x), Double(local.y), Double(local.z)),
                        cameraPositionLocal: cameraLocal, timestamp: frame.timestamp,
                        frameSequence: sequence, trackingState: .normal,
                        depthConfidence: frame.smoothedSceneDepth == nil ? 0.85 : 0.95
                    ))
                }
            }
            return result
        }

        @MainActor
        private func finishGuidedCornerCapture(
            frameTimestamp: TimeInterval,
            allowMoreEvidence: Bool = false
        ) {
            guard let started = guidedCaptureStartedAt, let plane = selectedPlane else { return }
            let reticle: SIMD2<Double>
            if let result = centreRaycast() {
                let world = worldPosition(of: result)
                let local = simd_inverse(plane.transform) * SIMD4<Float>(world.x, world.y, world.z, 1)
                reticle = SIMD2(Double(local.x), Double(local.z))
            } else if let last = guidedPatchSamples.last {
                reticle = SIMD2(last.localPosition.x, last.localPosition.z)
            } else {
                reticle = .zero
            }
            let capture = CornerPatchCapture(
                samples: guidedPatchSamples, reticleLocalPosition: Vector2D(reticle),
                coordinateEpoch: coordinateEpoch, startedAt: started, endedAt: frameTimestamp
            )
            switch DefaultLocalCornerEstimator.estimate(capture: capture) {
            case .success(let candidate):
                guidedCandidate = candidate
                guidedCaptureStartedAt = nil
                borderScanSnapshot.wrappedValue.candidate = candidate
                borderScanSnapshot.wrappedValue.scanProgress = 1
                borderScanSnapshot.wrappedValue.guidedState = .candidateReady(
                    index: pendingReplacementIndex ?? mappedPoints.count
                )
                borderScanSnapshot.wrappedValue.status = candidate.provenance == .inferredFromSupportingGeometry
                    ? "Inferred corner ready — inspect uncertainty before accepting"
                    : "Corner candidate ready"
                borderScanSnapshot.wrappedValue.confidenceLevel = candidate.uncertaintyMetres <= 0.01 ? .high : .medium
                borderScanSnapshot.wrappedValue.confidence = max(0, 1 - candidate.uncertaintyMetres / 0.05)
                pointGuidance.wrappedValue = "Accept this fixed candidate or rescan it."
                showGuidedBoundary()
            case .failure(let error):
                if allowMoreEvidence { return }
                guidedCaptureStartedAt = nil
                guidedPatchSamples.removeAll()
                borderScanSnapshot.wrappedValue.guidedState = .aiming(index: pendingReplacementIndex ?? mappedPoints.count)
                borderScanSnapshot.wrappedValue.status = error.localizedDescription
                borderScanSnapshot.wrappedValue.lastError = .unstableMeasurement
                pointGuidance.wrappedValue = error.localizedDescription
                canPlacePoint.wrappedValue = true
                updateTargetAppearance(isValid: true)
            }
        }

        @MainActor
        private func discardGuidedCandidate() {
            guidedCandidate = nil
            guidedPatchSamples.removeAll()
            guidedCaptureStartedAt = nil
            borderScanSnapshot.wrappedValue.candidate = nil
            borderScanSnapshot.wrappedValue.scanProgress = 0
            borderScanSnapshot.wrappedValue.guidedState = .aiming(index: pendingReplacementIndex ?? mappedPoints.count)
            borderScanSnapshot.wrappedValue.status = "Candidate discarded — aim and scan again"
            canPlacePoint.wrappedValue = selectedPlane != nil
            showGuidedBoundary()
        }

        @MainActor
        private func acceptGuidedCandidate() {
            guard var candidate = guidedCandidate, let plane = selectedPlane,
                  candidate.coordinateEpoch == coordinateEpoch else { return }
            let point = SIMD3<Float>(Float(candidate.acceptedLocalPosition.x), 0,
                                     Float(candidate.acceptedLocalPosition.y))
            let replacing = pendingReplacementIndex
            for index in mappedPoints.indices where index != replacing {
                guard simd_distance(mappedPoints[index], point)
                        >= Float(ShelfBoundaryAnalysisConfiguration.shelf.duplicatePointDistanceMetres)
                else {
                    borderScanSnapshot.wrappedValue.status = OpenSpaceScanError.duplicateCorner.localizedDescription
                    return
                }
            }
            if replacing == nil, let previous = mappedPoints.last,
               simd_distance(previous, point)
                < Float(ShelfBoundaryAnalysisConfiguration.shelf.minimumEdgeLengthMetres) {
                borderScanSnapshot.wrappedValue.status = OpenSpaceScanError.edgeTooShort.localizedDescription
                return
            }
            candidate.approval = .accepted
            let metadata = ShelfCornerMeasurementMetadata(
                id: candidate.id, validSampleCount: candidate.diagnosticSamples.count,
                rejectedSampleCount: max(0, guidedPatchSamples.count - candidate.diagnosticSamples.count),
                spreadMetres: candidate.uncertaintyMetres, capturedAt: candidate.capturedAt,
                trackingWasNormal: true, usedLiDAR: true
            )
            let world4 = plane.transform * SIMD4<Float>(point.x, 0, point.z, 1)
            let record = MeasuredSpaceCornerRecord(
                id: candidate.id,
                originalWorldPosition: Vector3D(Double(world4.x), Double(world4.y), Double(world4.z)),
                projectedWorldPosition: Vector3D(Double(world4.x), Double(world4.y), Double(world4.z)),
                localBoundaryPositionMetres: candidate.acceptedLocalPosition,
                sampleCount: candidate.diagnosticSamples.count,
                positionalVariance: candidate.uncertaintyMetres * candidate.uncertaintyMetres,
                depthVariance: candidate.rmsResidualMetres * candidate.rmsResidualMetres,
                projectionDistance: 0, measurementDistance: candidate.measurementDistanceMetres,
                measurementSource: candidate.estimator == .tabletopTerminationEdges
                    ? .smoothedSceneDepth : .sceneDepth,
                trackingState: .normal,
                confidenceScore: max(0, 1 - candidate.uncertaintyMetres / 0.05),
                timestamp: candidate.capturedAt,
                estimatorKind: candidate.estimator,
                provenance: candidate.provenance,
                estimatedUncertaintyMetres: candidate.uncertaintyMetres,
                approval: .accepted,
                coordinateEpoch: candidate.coordinateEpoch,
                schemaVersion: 1
            )
            if let index = replacing, mappedPoints.indices.contains(index) {
                mappedPoints[index] = point
                cornerMetadata[index] = metadata
                measuredSpaceCorners[index] = record
                guidedCornerMeasurements[index] = candidate
                pendingReplacementIndex = nil
            } else {
                mappedPoints.append(point)
                cornerMetadata.append(metadata)
                measuredSpaceCorners.append(record)
                guidedCornerMeasurements.append(candidate)
            }
            guidedCandidate = nil
            guidedPatchSamples.removeAll()
            borderScanSnapshot.wrappedValue.candidate = nil
            mappedPointCount.wrappedValue = mappedPoints.count
            borderScanSnapshot.wrappedValue.acceptedCornerCount = mappedPoints.count
            borderScanSnapshot.wrappedValue.tracePointCount = mappedPoints.count
            borderScanSnapshot.wrappedValue.canFinish = mappedPoints.count >= 3
            borderScanSnapshot.wrappedValue.guidedState = .aiming(index: mappedPoints.count)
            borderScanSnapshot.wrappedValue.status = "Corner \(mappedPoints.count) accepted — aim at the next corner"
            updateMeasurement(on: plane)
            showGuidedBoundary()
            canPlacePoint.wrappedValue = true
        }

        @MainActor
        private func closeGuidedShape() {
            guard geometryType == .openSpace, measurementStage.wrappedValue == .boundary,
                  mappedPoints.count >= 3, let plane = selectedPlane else { return }
            borderScanSnapshot.wrappedValue.guidedState = .closingShape
            do {
                let analysis = try ShelfBoundaryAnalyzer.analyze(
                    points: mappedPoints.map(SIMD3<Double>.init),
                    cornerConfidence: guidedCornerMeasurements.map {
                        max(0, 1 - $0.uncertaintyMetres / 0.05)
                    }, intent: .automatic
                )
                let polygon = mappedPoints.map { Vector2D(Double($0.x), Double($0.z)) }
                let segmentIDs = mappedPoints.indices.map { _ in UUID() }
                let segments = mappedPoints.indices.map { index in
                    DetectedBorderSegment(
                        id: segmentIDs[index], rawObservations: [],
                        simplifiedPoints: [polygon[index], polygon[(index + 1) % polygon.count]],
                        segmentType: .manual, confidence: min(
                            max(0, 1 - guidedCornerMeasurements[index].uncertaintyMetres / 0.05),
                            max(0, 1 - guidedCornerMeasurements[(index + 1) % polygon.count].uncertaintyMetres / 0.05)
                        ), isInferred: guidedCornerMeasurements[index].provenance == .inferredFromSupportingGeometry,
                        isManuallyEdited: false
                    )
                }
                let corners = mappedPoints.indices.map { index in
                    DetectedBorderCorner(
                        id: guidedCornerMeasurements[index].id, localPosition: polygon[index],
                        incomingSegmentID: segmentIDs[(index - 1 + segmentIDs.count) % segmentIDs.count],
                        outgoingSegmentID: segmentIDs[index],
                        angleRadians: analysis.rawCornerAnglesDegrees[index] * .pi / 180,
                        confidence: max(0, 1 - guidedCornerMeasurements[index].uncertaintyMetres / 0.05),
                        isRoundedApproximation: false, isManuallyEdited: false
                    )
                }
                let uncertainties = mappedPoints.indices.map { index -> DimensionUncertainty in
                    let next = (index + 1) % mappedPoints.count
                    let length = Double(simd_distance(mappedPoints[index], mappedPoints[next]))
                    let uncertainty = hypot(guidedCornerMeasurements[index].uncertaintyMetres,
                                            guidedCornerMeasurements[next].uncertaintyMetres)
                    return DimensionUncertainty(
                        measuredMetres: length, estimatedUncertaintyMetres: uncertainty,
                        robustFitResidualMetres: max(guidedCornerMeasurements[index].rmsResidualMetres,
                                                    guidedCornerMeasurements[next].rmsResidualMetres),
                        repeatabilityMetres: uncertainty, spatialCoverage: min(
                            guidedCornerMeasurements[index].spatialCoverageMetres,
                            guidedCornerMeasurements[next].spatialCoverageMetres
                        ), viewingDiversityRadians: min(
                            guidedCornerMeasurements[index].viewingAngleDiversityRadians,
                            guidedCornerMeasurements[next].viewingAngleDiversityRadians
                        ), closureErrorMetres: 0,
                        inferencePenaltyMetres: guidedCornerMeasurements[index].provenance
                            == .inferredFromSupportingGeometry ? 0.006 : 0,
                        correctionDisplacementMetres: 0, correlatedSampleFraction: 0
                    )
                }
                if let failure = uncertainties.map({ MeasurementAccuracyPolicy.evaluate($0, fitCritical: false) })
                    .first(where: { $0.use == .rejected || $0.use == .manualOnly }) {
                    borderScanSnapshot.wrappedValue.status = failure.reason
                    borderScanSnapshot.wrappedValue.guidedState = .failed(.geometryConfidenceTooLow)
                    return
                }
                let origin = plane.transform.columns.3, normal = plane.transform.columns.1
                let confidence = guidedCornerMeasurements.map {
                    max(0, 1 - $0.uncertaintyMetres / max(
                        CornerAccuracyPolicy.maximumAcceptedUncertainty(
                            measurementDistanceMetres: $0.measurementDistanceMetres
                        ), 0.001
                    )) - ($0.provenance == .inferredFromSupportingGeometry ? 0.1 : 0)
                }.reduce(0, +) / Double(guidedCornerMeasurements.count)
                let boundary = ScannedStorageBoundary(
                    id: plane.identifier,
                    basePlane: CodablePlane(
                        origin: Vector3D(Double(origin.x), Double(origin.y), Double(origin.z)),
                        normal: Vector3D(Double(normal.x), Double(normal.y), Double(normal.z))
                    ), surfaceType: surfaceType, rawTrace: [], detectedSegments: segments,
                    detectedCorners: corners, simplifiedPolygon: polygon, approvedPolygon: [],
                    suggestedPolygon: analysis.suggestedBoundary?.map { Vector2D($0.x, $0.z) },
                    geometryConfidence: confidence, validationState: .valid,
                    processingMetrics: .init(
                        maximumSimplificationDisplacementMetres: 0,
                        averageSimplificationDisplacementMetres: 0,
                        inferredGapLengthMetres: 0, manualEditCount: 0
                    ), measurementMethod: .lidarCornerPlacement, deviceHasLiDAR: true,
                    schemaVersion: 6, createdAt: .now, updatedAt: .now,
                    shapeIntent: .straightSidedPolygon, acquisitionSections: nil,
                    circleFit: nil, dimensionUncertainties: uncertainties,
                    approvalState: .proposed,
                    globalMapUncertaintyMetres: guidedCornerMeasurements.map(\.uncertaintyMetres).max(),
                    localPlacementUncertaintyMetres: nil,
                    guidedCornerMeasurements: guidedCornerMeasurements
                )
                updateMeasurement(on: plane)
                guard let surface = measuredSurfaces.wrappedValue.first else { return }
                measuredSurfaces.wrappedValue = [surface.replacingScannedBoundary(boundary)]
                borderScanSnapshot.wrappedValue.guidedState = .reviewingBoundary
                borderScanSnapshot.wrappedValue.state = .reviewingBoundary
                borderScanSnapshot.wrappedValue.status = "Review raw corners and any optional correction"
                measurementStage.wrappedValue = .review
                showGuidedBoundary(showClosingSegment: true)
            } catch let error as ShelfBoundaryAnalysisError {
                borderScanSnapshot.wrappedValue.status = error.localizedDescription
                borderScanSnapshot.wrappedValue.guidedState = .failed(
                    error == .selfIntersection ? .selfIntersectingPolygon : .boundaryNotClosed
                )
            } catch {
                borderScanSnapshot.wrappedValue.status = error.localizedDescription
                borderScanSnapshot.wrappedValue.guidedState = .failed(.boundaryNotClosed)
            }
        }

        @MainActor
        private func showGuidedBoundary(showClosingSegment: Bool = true) {
            guard let arView, let plane = selectedPlane else { return }
            borderAnchor?.removeFromParent()
            let anchor = AnchorEntity(world: plane.transform)
            let points = mappedPoints.map { SIMD3<Float>($0.x, 0.006, $0.z) }
            for index in points.indices {
                let selected = pendingReplacementIndex == index
                var material = UnlitMaterial()
                material.color = .init(tint: selected ? .systemOrange : .systemGreen, texture: nil)
                let marker = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [material])
                marker.position = points[index]
                anchor.addChild(marker)
                let uncertainty = guidedCornerMeasurements.indices.contains(index)
                    ? guidedCornerMeasurements[index].uncertaintyMetres : 0.01
                addUncertaintyRing(to: anchor, centre: points[index], radius: Float(uncertainty),
                                   color: selected ? .systemOrange : .systemGreen)
                if index + 1 < points.count {
                    anchor.addChild(spatialLine(from: points[index], to: points[index + 1], color: .systemCyan))
                }
            }
            if showClosingSegment, points.count >= 3, let first = points.first, let last = points.last {
                addDashedLine(to: anchor, from: last, to: first, color: .systemGray)
            }
            if let candidate = guidedCandidate {
                let point = SIMD3<Float>(Float(candidate.acceptedLocalPosition.x), 0.009,
                                         Float(candidate.acceptedLocalPosition.y))
                let color: UIColor = candidate.provenance == .inferredFromSupportingGeometry
                    ? .systemOrange : .systemPurple
                var material = UnlitMaterial()
                material.color = .init(tint: color, texture: nil)
                let marker = ModelEntity(mesh: .generateSphere(radius: 0.014), materials: [material])
                marker.position = point
                anchor.addChild(marker)
                addUncertaintyRing(to: anchor, centre: point,
                                   radius: Float(candidate.uncertaintyMetres), color: color)
            }
            arView.scene.addAnchor(anchor)
            borderAnchor = anchor
        }

        private func addUncertaintyRing(
            to anchor: AnchorEntity, centre: SIMD3<Float>, radius: Float, color: UIColor
        ) {
            let safeRadius = max(0.006, min(radius, 0.08))
            let segments = 28
            for index in 0..<segments {
                let a = Float(index) * 2 * .pi / Float(segments)
                let b = Float(index + 1) * 2 * .pi / Float(segments)
                let start = centre + SIMD3<Float>(cos(a) * safeRadius, 0, sin(a) * safeRadius)
                let end = centre + SIMD3<Float>(cos(b) * safeRadius, 0, sin(b) * safeRadius)
                anchor.addChild(spatialLine(from: start, to: end, color: color))
            }
        }

        private func addDashedLine(
            to anchor: AnchorEntity, from start: SIMD3<Float>, to end: SIMD3<Float>, color: UIColor
        ) {
            let count = 12
            for index in stride(from: 0, to: count, by: 2) {
                let a = Float(index) / Float(count)
                let b = Float(index + 1) / Float(count)
                anchor.addChild(spatialLine(from: simd_mix(start, end, SIMD3<Float>(repeating: a)),
                                            to: simd_mix(start, end, SIMD3<Float>(repeating: b)),
                                            color: color))
            }
        }

        private struct DepthEdgeCandidate {
            var worldPosition: SIMD3<Float>
            var localPosition: SIMD2<Double>
            var depthGradient: Double
            var normalDifference: Double
            var basePlaneDistance: Double
            var measurementDistance: Double
            var validSampleCount: Int
            var depthVariance: Double
            var missingDepthFraction: Double
            var surfaceContinuesBeyondEdge: Bool
            var source: BorderObservationSource
        }

        @MainActor
        private func collectBorderFrame(
            _ frame: ARFrame,
            trackingState: ARCamera.TrackingState
        ) {
            guard frame.timestamp - lastFrameTimestamp >= 0.08 else { return }
            lastFrameTimestamp = frame.timestamp
            guard hasLiDAR else {
                borderScanSnapshot.wrappedValue = BorderScanSnapshot(
                    state: .failed(.lidarUnavailable), status: "LiDAR unavailable",
                    lastError: .lidarUnavailable
                )
                return
            }
            guard case .normal = trackingState else {
                let relocalizing: Bool
                if case .limited(.relocalizing) = trackingState { relocalizing = true } else { relocalizing = false }
                if relocalizing, !borderTraceBuilder.observations.isEmpty {
                    coordinateEpochInvalid = true
                    borderScanSnapshot.wrappedValue = BorderScanSnapshot(
                        state: .failed(.inconsistentCoordinateSystem),
                        status: "Tracking origin changed",
                        tracePointCount: borderTraceBuilder.observations.count,
                        lastError: .inconsistentCoordinateSystem
                    )
                } else {
                    borderScanSnapshot.wrappedValue.state = .borderLost
                    borderScanSnapshot.wrappedValue.status = "Hold steady"
                    borderScanSnapshot.wrappedValue.lastError = .trackingUnavailable
                }
                updateTargetAppearance(isValid: false)
                return
            }
            guard !coordinateEpochInvalid, !borderPaused else { return }

            if selectedPlane == nil {
                guard let result = centreRaycast(), let plane = result.anchor as? ARPlaneAnchor else {
                    borderScanSnapshot.wrappedValue.state = .findingBaseSurface
                    borderScanSnapshot.wrappedValue.status = "Finding base surface"
                    updateTargetAppearance(isValid: false)
                    return
                }
                selectedPlane = plane
                selectedPlaneID = plane.identifier
                borderScanSnapshot.wrappedValue.state = .searchingForBorder
                borderScanSnapshot.wrappedValue.status = "Searching for edge"
            }
            guard let plane = selectedPlane,
                  let candidate = depthEdgeCandidate(frame: frame, plane: plane) else {
                candidatePersistence = 0
                borderScanSnapshot.wrappedValue.state = borderTraceBuilder.observations.isEmpty
                    ? .searchingForBorder : .borderLost
                borderScanSnapshot.wrappedValue.status = borderTraceBuilder.observations.isEmpty
                    ? "Searching for edge" : "Edge lost"
                borderScanSnapshot.wrappedValue.confidence = 0
                borderScanSnapshot.wrappedValue.confidenceLevel = .invalid
                updateTargetAppearance(isValid: false)
                return
            }

            if let previous = lastCandidatePosition,
               simd_distance(previous, candidate.localPosition) <= 0.08 {
                candidatePersistence += 1
            } else {
                candidatePersistence = 1
            }
            lastCandidatePosition = candidate.localPosition
            let cameraPosition = SIMD3<Float>(
                frame.camera.transform.columns.3.x,
                frame.camera.transform.columns.3.y,
                frame.camera.transform.columns.3.z
            )
            let evidence = BorderDetectionEvidence(
                depthGradientMetres: candidate.depthGradient,
                normalDifference: candidate.normalDifference,
                basePlaneDistanceMetres: candidate.basePlaneDistance,
                measurementDistanceMetres: candidate.measurementDistance,
                validDepthSampleCount: candidate.validSampleCount,
                depthVariance: candidate.depthVariance,
                persistenceFrames: candidatePersistence,
                viewingAngleDiversity: viewingDiversity(at: candidate.localPosition),
                hasPlaneSupport: true,
                hasMeshSupport: !frame.anchors.compactMap { $0 as? ARMeshAnchor }.isEmpty,
                surfaceContinuesBeyondEdge: candidate.surfaceContinuesBeyondEdge,
                missingDepthFraction: candidate.missingDepthFraction,
                trackingState: .normal,
                surfaceType: surfaceType
            )
            let detection = borderDetector.detectBorder(evidence: evidence)
            borderScanSnapshot.wrappedValue.confidence = detection.confidence
            borderScanSnapshot.wrappedValue.confidenceLevel = detection.confidenceLevel
            guard let segmentType = detection.segmentType else {
                borderScanSnapshot.wrappedValue.state = .searchingForBorder
                borderScanSnapshot.wrappedValue.status = "Searching for edge"
                updateTargetAppearance(isValid: false)
                return
            }
            borderScanSnapshot.wrappedValue.state = detection.shouldCommit
                ? .tracingBorder : .borderCandidateDetected
            borderScanSnapshot.wrappedValue.status = detection.shouldCommit
                ? "Move slowly along edge" : "Edge detected"
            updateTargetAppearance(isValid: detection.confidenceLevel >= .medium)

            guard detection.shouldCommit else { return }
            let forward = -SIMD3<Float>(frame.camera.transform.columns.2.x,
                                        frame.camera.transform.columns.2.y,
                                        frame.camera.transform.columns.2.z)
            let observation = BorderObservation(
                id: UUID(),
                worldPosition: Vector3D(SIMD3<Double>(candidate.worldPosition)),
                localPosition: Vector2D(candidate.localPosition),
                depthGradient: candidate.depthGradient,
                normalDifference: candidate.normalDifference,
                basePlaneDistance: candidate.basePlaneDistance,
                measurementDistance: Double(simd_distance(cameraPosition, candidate.worldPosition)),
                source: candidate.source,
                segmentType: segmentType,
                trackingState: .normal,
                confidence: detection.confidence,
                timestamp: .now,
                viewingDirection: Vector3D(SIMD3<Double>(forward))
            )
            if borderTraceBuilder.observations.isEmpty {
                borderTraceBuilder.begin(at: observation, type: segmentType)
            } else {
                borderTraceBuilder.add(observation, type: segmentType)
            }
            sectionedBoundary.add(observation)
            let count = borderTraceBuilder.observations.count
            mappedPointCount.wrappedValue = count
            borderScanSnapshot.wrappedValue.tracePointCount = count
            if count >= 3,
               let first = borderTraceBuilder.observations.first,
               simd_distance(first.localPosition.simd, candidate.localPosition)
                    <= BorderTraceConfiguration.standard.closureDistanceMetres {
                borderScanSnapshot.wrappedValue.state = .boundaryNearlyClosed
                borderScanSnapshot.wrappedValue.status = "Boundary nearly closed"
                borderScanSnapshot.wrappedValue.canFinish = true
            } else {
                borderScanSnapshot.wrappedValue.canFinish = false
                syncSectionedSnapshot(status: sectionedBoundary.proposedCorner == nil
                    ? "Measure edge \(sectionedBoundary.sections.count + 1) from another view where possible."
                    : "Confirm the proposed physical corner, continue, or rescan this edge.")
            }
            showBorderTrace()
        }

        private func viewingDiversity(at point: SIMD2<Double>) -> Double {
            let nearby = borderTraceBuilder.observations.filter {
                simd_distance($0.localPosition.simd, point) <= 0.04
            }
            guard nearby.count >= 2 else { return 0 }
            let first = nearby[0].viewingDirection.simd
            return nearby.dropFirst().map {
                let dot = max(-1.0, min(1.0, simd_dot(first, $0.viewingDirection.simd)))
                return acos(dot)
            }.max() ?? 0
        }

        private func possibleCorner(in observations: [BorderObservation]) -> Bool {
            guard observations.count >= 5 else { return false }
            let a = observations[observations.count - 5].localPosition.simd
            let b = observations[observations.count - 3].localPosition.simd
            let c = observations[observations.count - 1].localPosition.simd
            let first = simd_normalize(b - a)
            let second = simd_normalize(c - b)
            let angle = acos(max(-1.0, min(1.0, simd_dot(first, second)))) * 180 / .pi
            return angle >= BorderTraceConfiguration.standard.cornerAngleDegrees
        }

        private func syncSectionedSnapshot(status: String) {
            borderScanSnapshot.wrappedValue.acquisitionPhase = sectionedBoundary.phase
            borderScanSnapshot.wrappedValue.currentEdgeIndex = sectionedBoundary.sections.count
            borderScanSnapshot.wrappedValue.confirmedEdgeCount = sectionedBoundary.sections.filter(\.isConfirmed).count
            borderScanSnapshot.wrappedValue.hasCornerProposal = sectionedBoundary.proposedCorner != nil
            borderScanSnapshot.wrappedValue.currentEdgeUncertaintyMetres = sectionedBoundary.sections.last?.fittedLine?.uncertaintyMetres
            borderScanSnapshot.wrappedValue.status = status
            if sectionedBoundary.proposedCorner != nil {
                borderScanSnapshot.wrappedValue.state = .confirmingProposedCorner
            }
        }

        @MainActor
        private func finishBorderTrace() {
            guard geometryType == .openSpace,
                  measurementStage.wrappedValue == .boundary else { return }
            let observations = borderTraceBuilder.observations
            guard observations.count >= 3, let plane = selectedPlane else {
                borderScanSnapshot.wrappedValue.state = .failed(.insufficientBorderData)
                borderScanSnapshot.wrappedValue.status = "Scan more of the edge"
                borderScanSnapshot.wrappedValue.lastError = .insufficientBorderData
                return
            }
            guard borderScanSnapshot.wrappedValue.state == .boundaryNearlyClosed else {
                borderScanSnapshot.wrappedValue.state = .failed(.boundaryNotClosed)
                borderScanSnapshot.wrappedValue.status = "Boundary not closed"
                borderScanSnapshot.wrappedValue.lastError = .boundaryNotClosed
                return
            }
            borderScanSnapshot.wrappedValue.state = .processingBoundary
            borderScanSnapshot.wrappedValue.status = "Processing boundary"
            guard sectionedBoundary.closeBoundary() else {
                borderScanSnapshot.wrappedValue.state = .failed(.insufficientBorderData)
                borderScanSnapshot.wrappedValue.status = "Each edge needs enough distributed samples and reliable fitted-line intersections."
                borderScanSnapshot.wrappedValue.lastError = .insufficientBorderData
                return
            }
            let fittedPolygon = sectionedBoundary.confirmedCorners.map(\.position)
            let fittedObservations: [BorderObservation] = fittedPolygon.enumerated().map { index, point in
                var value = observations[min(index, observations.count - 1)]
                value.id = UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index + 1))!
                value.localPosition = point
                return value
            }
            let result = boundaryProcessor.process(
                observations: fittedObservations,
                configuration: .standard
            )
            guard result.validationState == .valid else {
                let error: OpenSpaceScanError = result.validationState == .selfIntersecting
                    ? .selfIntersectingPolygon
                    : result.validationState == .zeroArea ? .zeroAreaPolygon : .boundaryNotClosed
                borderScanSnapshot.wrappedValue.state = .failed(error)
                borderScanSnapshot.wrappedValue.status = error.errorDescription ?? "Invalid boundary"
                borderScanSnapshot.wrappedValue.lastError = error
                return
            }
            mappedPoints = result.simplified.map { SIMD3(Float($0.x), 0, Float($0.y)) }
            mappedPointCount.wrappedValue = mappedPoints.count
            updateMeasurement(on: plane)
            guard let surface = measuredSurfaces.wrappedValue.first,
                  let analysis = surface.boundaryAnalysis else {
                borderScanSnapshot.wrappedValue.state = .failed(.insufficientBorderData)
                return
            }
            let origin = plane.transform.columns.3
            let normal = plane.transform.columns.1
            let boundary = ScannedStorageBoundary(
                id: plane.identifier,
                basePlane: CodablePlane(
                    origin: Vector3D(Double(origin.x), Double(origin.y), Double(origin.z)),
                    normal: Vector3D(Double(normal.x), Double(normal.y), Double(normal.z))
                ),
                surfaceType: surfaceType,
                rawTrace: observations,
                detectedSegments: result.segments,
                detectedCorners: result.corners,
                simplifiedPolygon: result.simplified,
                approvedPolygon: [],
                suggestedPolygon: analysis.suggestedBoundary?.map { Vector2D($0.x, $0.z) },
                geometryConfidence: result.confidence,
                validationState: result.validationState,
                processingMetrics: result.metrics,
                measurementMethod: .lidarSectionedEdgeScan,
                deviceHasLiDAR: hasLiDAR,
                schemaVersion: 5,
                createdAt: .now,
                updatedAt: .now,
                shapeIntent: .straightSidedPolygon,
                acquisitionSections: sectionedBoundary.sections,
                circleFit: nil,
                dimensionUncertainties: sectionedBoundary.sections.compactMap { section in
                    guard let fit = section.fittedLine else { return nil }
                    return DimensionUncertainty(
                        measuredMetres: fit.physicalLengthMetres,
                        estimatedUncertaintyMetres: fit.uncertaintyMetres,
                        robustFitResidualMetres: fit.rmsResidualMetres,
                        repeatabilityMetres: fit.uncertaintyMetres,
                        spatialCoverage: fit.spatialCoverage,
                        viewingDiversityRadians: fit.viewingAngleDiversityRadians,
                        closureErrorMetres: 0,
                        inferencePenaltyMetres: section.isInferred ? 0.02 : 0,
                        correctionDisplacementMetres: result.metrics.maximumSimplificationDisplacementMetres,
                        correlatedSampleFraction: section.rawObservations.isEmpty ? 1
                            : 1 - Double(section.acceptedObservations.count) / Double(section.rawObservations.count)
                    )
                },
                approvalState: .proposed,
                globalMapUncertaintyMetres: sectionedBoundary.confirmedCorners.map(\.uncertaintyMetres).max(),
                localPlacementUncertaintyMetres: nil
            )
            measuredSurfaces.wrappedValue = [surface.replacingScannedBoundary(boundary)]
            borderScanSnapshot.wrappedValue.state = .reviewingBoundary
            borderScanSnapshot.wrappedValue.status = "Ready to review"
            measurementStage.wrappedValue = .review
        }

        @MainActor
        private func showBorderTrace() {
            guard let arView, let plane = selectedPlane else { return }
            borderAnchor?.removeFromParent()
            let anchor = AnchorEntity(world: plane.transform)
            let points = borderTraceBuilder.observations.map {
                SIMD3<Float>(Float($0.localPosition.x), 0.004, Float($0.localPosition.y))
            }
            for pair in zip(points, points.dropFirst()) {
                anchor.addChild(spatialLine(from: pair.0, to: pair.1, color: .systemCyan))
            }
            arView.scene.addAnchor(anchor)
            borderAnchor = anchor
        }

        private func depthEdgeCandidate(
            frame: ARFrame,
            plane: ARPlaneAnchor
        ) -> DepthEdgeCandidate? {
            guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
            let buffer = depthData.depthMap
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            guard width > 24, height > 24 else { return nil }
            let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float32>.size
            let values = base.assumingMemoryBound(to: Float32.self)
            let cx = width / 2, cy = height / 2
            let radius = 10, separation = 3
            var valid: [Double] = []
            var missing = 0
            for y in (cy - radius)...(cy + radius) {
                for x in (cx - radius)...(cx + radius) {
                    let value = values[y * stride + x]
                    if value.isFinite, value >= 0.10, value <= 5 { valid.append(Double(value)) }
                    else { missing += 1 }
                }
            }
            guard valid.count >= 6 else { return nil }
            var best: (first: (Int, Int, Float), second: (Int, Int, Float), score: Float)?
            for offset in -radius...radius {
                for horizontal in [true, false] {
                    let x1 = horizontal ? cx - separation : cx + offset
                    let y1 = horizontal ? cy + offset : cy - separation
                    let x2 = horizontal ? cx + separation : cx + offset
                    let y2 = horizontal ? cy + offset : cy + separation
                    let d1 = values[y1 * stride + x1], d2 = values[y2 * stride + x2]
                    let valid1 = d1.isFinite && d1 >= 0.10 && d1 <= 5
                    let valid2 = d2.isFinite && d2 >= 0.10 && d2 <= 5
                    guard valid1 || valid2 else { continue }
                    let score: Float = valid1 && valid2 ? abs(d1 - d2) : 0.10
                    if best.map({ score > $0.score }) ?? true {
                        best = ((x1, y1, d1), (x2, y2, d2), score)
                    }
                }
            }
            guard let best else { return nil }
            let candidates = [best.first, best.second].compactMap { pixel -> (SIMD3<Float>, Double)? in
                guard pixel.2.isFinite, pixel.2 >= 0.10, pixel.2 <= 5,
                      let world = worldPoint(depthPixelX: pixel.0, y: pixel.1, depth: pixel.2,
                                             depthWidth: width, depthHeight: height, frame: frame)
                else { return nil }
                let local = simd_inverse(plane.transform) * SIMD4<Float>(world.x, world.y, world.z, 1)
                return (world, abs(Double(local.y)))
            }
            guard let baseCandidate = candidates.min(by: { $0.1 < $1.1 }),
                  baseCandidate.1 <= 0.05 else { return nil }
            let projected = simd_inverse(plane.transform) * SIMD4<Float>(
                baseCandidate.0.x, baseCandidate.0.y, baseCandidate.0.z, 1
            )
            let otherIsAboveBase = candidates.contains { candidate in
                let local = simd_inverse(plane.transform) * SIMD4<Float>(
                    candidate.0.x, candidate.0.y, candidate.0.z, 1
                )
                return Double(local.y) > 0.04
            }
            let sortedDepth = valid.sorted()
            let medianDepth = sortedDepth[sortedDepth.count / 2]
            let stableDepthCluster = valid.filter { abs($0 - medianDepth) <= 0.06 }
            guard stableDepthCluster.count >= 6 else { return nil }
            let mean = stableDepthCluster.reduce(0, +) / Double(stableDepthCluster.count)
            let variance = stableDepthCluster.reduce(0) {
                $0 + pow($1 - mean, 2)
            } / Double(stableDepthCluster.count)
            let total = (radius * 2 + 1) * (radius * 2 + 1)
            return DepthEdgeCandidate(
                worldPosition: baseCandidate.0,
                localPosition: SIMD2(Double(projected.x), Double(projected.z)),
                depthGradient: Double(best.score),
                normalDifference: min(Double(best.score) / 0.08, 1),
                basePlaneDistance: baseCandidate.1,
                measurementDistance: medianDepth,
                validSampleCount: stableDepthCluster.count,
                depthVariance: variance,
                missingDepthFraction: Double(missing) / Double(total),
                surfaceContinuesBeyondEdge: otherIsAboveBase,
                source: frame.smoothedSceneDepth == nil ? .sceneDepth : .smoothedSceneDepth
            )
        }

        private func worldPoint(
            depthPixelX x: Int, y: Int, depth: Float,
            depthWidth: Int, depthHeight: Int, frame: ARFrame
        ) -> SIMD3<Float>? {
            let resolution = frame.camera.imageResolution
            let scaleX = Float(depthWidth) / Float(resolution.width)
            let scaleY = Float(depthHeight) / Float(resolution.height)
            let intrinsics = frame.camera.intrinsics
            let fx = intrinsics.columns.0.x * scaleX
            let fy = intrinsics.columns.1.y * scaleY
            guard fx > 0, fy > 0 else { return nil }
            let cx = intrinsics.columns.2.x * scaleX
            let cy = intrinsics.columns.2.y * scaleY
            let camera = SIMD4<Float>(
                (Float(x) - cx) * depth / fx,
                -(Float(y) - cy) * depth / fy,
                -depth, 1
            )
            let world = frame.camera.transform * camera
            let point = SIMD3<Float>(world.x, world.y, world.z)
            return point.x.isFinite && point.y.isFinite && point.z.isFinite ? point : nil
        }

        @MainActor
        private func collectReticleSample(
            timestamp: TimeInterval,
            trackingState: ARCamera.TrackingState
        ) {
            guard timestamp > lastFrameTimestamp else { return }
            lastFrameTimestamp = timestamp
            guard case .normal = trackingState else {
                rollingSamples.removeAll()
                currentPointEstimate = nil
                pointStability.wrappedValue = .lowConfidence
                if case .limited(.relocalizing) = trackingState, !mappedPoints.isEmpty {
                    coordinateEpochInvalid = true
                    pointGuidance.wrappedValue = "Tracking relocalized after points were placed. Reset and rescan to avoid mixed coordinates."
                } else if case .limited(.excessiveMotion) = trackingState {
                    pointGuidance.wrappedValue = "Tracking is unstable. Move the device more slowly."
                } else {
                    pointGuidance.wrappedValue = "Tracking is unstable. Hold still until measurement resumes."
                }
                canPlacePoint.wrappedValue = false
                cornerTelemetry.wrappedValue.tracking = .limited
                updateTargetAppearance(isValid: false)
                return
            }
            guard measurementStage.wrappedValue == .boundary,
                  !coordinateEpochInvalid,
                  let result = centreRaycast(),
                  let frame = arView?.session.currentFrame
            else {
                updateTargetAvailability()
                return
            }
            let raycastPosition = worldPosition(of: result)
            let depthPosition = hasLiDAR ? visibleSurfacePointAtCentre() : nil
            let position: SIMD3<Float>
            let usedDepth: Bool
            let source: CornerMeasurementSource
            if let depthPosition,
               simd_distance(depthPosition, raycastPosition) <= 0.05 {
                position = depthPosition
                usedDepth = true
                source = frame.smoothedSceneDepth != nil ? .smoothedSceneDepth : .sceneDepth
            } else {
                position = raycastPosition
                usedDepth = false
                source = .existingPlaneRaycast
            }
            let camera = SIMD3<Float>(
                frame.camera.transform.columns.3.x,
                frame.camera.transform.columns.3.y,
                frame.camera.transform.columns.3.z
            )
            rollingSamples.append(ShelfPointSample(
                position: SIMD3<Double>(position),
                cameraDistanceMetres: Double(simd_distance(camera, position)),
                timestamp: timestamp,
                trackingConfidence: 0.9,
                hasLiDARDepth: usedDepth,
                source: source
            ))
            rollingSamples = rollingSamples.filter {
                timestamp - $0.timestamp
                    <= ShelfPointSamplingConfiguration.shelf.windowSeconds
            }
            let estimate = ShelfPointEstimator.estimate(
                samples: rollingSamples,
                hasLiDAR: hasLiDAR
            )
            currentPointEstimate = estimate
            pointStability.wrappedValue = estimate.stability
            pointGuidance.wrappedValue = estimate.message
            canPlacePoint.wrappedValue = estimate.canPlace
            let planeDifference: Double? = selectedPlane.map {
                let local = simd_inverse($0.transform) * SIMD4<Float>(position.x, position.y, position.z, 1)
                return abs(Double(local.y))
            }
            cornerTelemetry.wrappedValue = CornerMeasurementTelemetry(
                source: estimate.source,
                tracking: .normal,
                distanceMetres: estimate.measurementDistanceMetres.isFinite
                    ? estimate.measurementDistanceMetres : nil,
                surfaceHeightDifferenceMetres: planeDifference,
                sampleCount: estimate.validSampleCount,
                confidence: estimate.confidence
            )
            updateTargetAppearance(isValid: estimate.canPlace)
        }

        @MainActor
        private func updateTargetAvailability() {
            let isValid: Bool
            switch measurementStage.wrappedValue {
            case .boundary:
                if geometryType == .openSpace, !manualBorderCorrection.wrappedValue {
                    isValid = !coordinateEpochInvalid
                        && surfaceCaptureStartedAt == nil && surfaceCandidate == nil
                } else {
                    isValid = !coordinateEpochInvalid && currentPointEstimate?.canPlace == true
                }
            case .review:
                isValid = false
            case .bottom:
                isValid = centreRaycast() != nil
            case .top:
                if let top = visibleSurfacePointAtCentre(),
                   let bottomPoint,
                   let boundaryMeasurement {
                    isValid = (try? ManualMeasurementGeometry.height(
                        top: top,
                        bottom: bottomPoint,
                        boundary: boundaryMeasurement
                    )) != nil
                } else {
                    isValid = false
                }
            case .frontSelection:
                isValid = validCameraFrontDirection() != nil
            case .frontConfirmation, .complete:
                isValid = false
            }
            if canPlacePoint.wrappedValue != isValid {
                canPlacePoint.wrappedValue = isValid
            }
            updateTargetAppearance(isValid: isValid)
        }

        @MainActor
        private func updateTargetAppearance(isValid: Bool) {
            let color = isValid ? UIColor.systemGreen : UIColor.white
            targetView?.layer.borderColor = color.cgColor
            targetView?.accessibilityLabel = isValid
                ? "Valid shelf point"
                : "No shelf surface detected"
            targetDot?.backgroundColor = color
        }

        @MainActor
        private func centreRaycast() -> ARRaycastResult? {
            guard let arView, arView.bounds.width > 0, arView.bounds.height > 0,
                  let result = arView.raycast(
                    from: CGPoint(x: arView.bounds.midX, y: arView.bounds.midY),
                    allowing: .existingPlaneGeometry,
                    alignment: .horizontal
                  ).first,
                  let plane = result.anchor as? ARPlaneAnchor,
                  selectedPlaneID == nil || selectedPlaneID == plane.identifier
            else { return nil }
            return result
        }

        private func worldPosition(of result: ARRaycastResult) -> SIMD3<Float> {
            SIMD3<Float>(
                result.worldTransform.columns.3.x,
                result.worldTransform.columns.3.y,
                result.worldTransform.columns.3.z
            )
        }

        private func updateMeasurement(on plane: ARPlaneAnchor) {
            guard mappedPoints.count >= 3 else {
                measuredSurfaces.wrappedValue = []
                return
            }
            let xValues = mappedPoints.map(\.x)
            let zValues = mappedPoints.map(\.z)
            guard let minX = xValues.min(),
                  let maxX = xValues.max(),
                  let minZ = zValues.min(),
                  let maxZ = zValues.max()
            else { return }

            let worldBoundary = mappedPoints.map { point -> SIMD3<Float> in
                let world = plane.transform * SIMD4<Float>(point.x, point.y, point.z, 1)
                return SIMD3<Float>(world.x, world.y, world.z)
            }
            guard let boundary = try? ManualMeasurementGeometry.measureBoundary(worldBoundary) else {
                boundaryMeasurement = nil
                measuredSurfaces.wrappedValue = []
                return
            }
            boundaryMeasurement = boundary

            let analysis = analyzeBoundary()
            measuredSurfaces.wrappedValue = [
                MeasuredShelfSurface(
                    id: plane.identifier,
                    widthCM: Double((maxX - minX) * 100),
                    depthCM: Double((maxZ - minZ) * 100),
                    measuredFreeHeightCM: nil,
                    frontDirectionLocal: nil,
                    originLocal: nil,
                    scanConfidence: analysis?.scanConfidence
                        ?? (selectedPlane?.classification == .none ? 0.75 : 0.9),
                    boundaryClosed: true,
                    geometry: analysis.flatMap { geometryDraft(from: $0) },
                    boundaryAnalysis: analysis,
                    cornerMetadata: cornerMetadata,
                    measuredSpaceCorners: measuredSpaceCorners,
                    scannedBoundary: nil
                )
            ]
        }

        private func analyzeBoundary() -> ShelfBoundaryAnalysis? {
            try? ShelfBoundaryAnalyzer.analyze(
                points: mappedPoints.map(SIMD3<Double>.init),
                cornerConfidence: cornerMetadata.map {
                    max(0, 1 - $0.spreadMetres / 0.012)
                },
                intent: .automatic
            )
        }

        private func geometryDraft(
            from analysis: ShelfBoundaryAnalysis
        ) -> ShelfGeometryRecord {
            return ShelfBoundaryAnalyzer.geometryRecord(
                from: analysis,
                approvedBoundary: [],
                approval: .draft,
                intent: .automatic,
                meaning: .innerUsable,
                cornerMetadata: cornerMetadata,
                expectedWidthCM: nil,
                expectedDepthCM: nil,
                deviceModel: ObjectScannerCapabilities.deviceModelIdentifier,
                hasLiDAR: hasLiDAR
            )
        }

        private func replaceMeasuredHeight(_ heightCM: Double?) {
            guard let surface = measuredSurfaces.wrappedValue.first else { return }
            measuredSurfaces.wrappedValue = [
                MeasuredShelfSurface(
                    id: surface.id,
                    widthCM: surface.widthCM,
                    depthCM: surface.depthCM,
                    measuredFreeHeightCM: heightCM,
                    frontDirectionLocal: surface.frontDirectionLocal,
                    originLocal: surface.originLocal,
                    scanConfidence: surface.scanConfidence,
                    boundaryClosed: surface.boundaryClosed,
                    geometry: surface.geometry,
                    boundaryAnalysis: surface.boundaryAnalysis,
                    cornerMetadata: surface.cornerMetadata,
                    measuredSpaceCorners: surface.measuredSpaceCorners,
                    scannedBoundary: surface.scannedBoundary
                )
            ]
        }

        @MainActor
        private func validCameraFrontDirection() -> SIMD3<Float>? {
            guard let frame = arView?.session.currentFrame, let plane = selectedPlane else { return nil }
            let cameraForwardWorld = -SIMD3<Float>(frame.camera.transform.columns.2.x,
                                                   frame.camera.transform.columns.2.y,
                                                   frame.camera.transform.columns.2.z)
            let local4 = simd_inverse(plane.transform) * SIMD4<Float>(cameraForwardWorld.x, cameraForwardWorld.y, cameraForwardWorld.z, 0)
            var local = SIMD3<Float>(local4.x, 0, local4.z)
            guard simd_length(local) > 0.2 else { return nil }
            local = simd_normalize(local)
            guard abs(local4.y) < 0.65 else { return nil }
            return local
        }

        @MainActor
        private func setFrontFromCamera() {
            guard let direction = validCameraFrontDirection() else { return }
            replaceFrontDirection(Vector3D(Double(direction.x), 0, Double(direction.z)))
            showFrontArrow(direction: direction)
            measurementStage.wrappedValue = .frontConfirmation
            updateTargetAvailability()
        }

        @MainActor
        private func reverseFront() {
            guard let surface = measuredSurfaces.wrappedValue.first,
                  let front = surface.frontDirectionLocal else { return }
            let reversed = Vector3D(-front.x, 0, -front.z)
            replaceFrontDirection(reversed)
            showFrontArrow(direction: SIMD3(Float(reversed.x), 0, Float(reversed.z)))
        }

        private func replaceFrontDirection(_ direction: Vector3D?) {
            guard let surface = measuredSurfaces.wrappedValue.first else { return }
            var widthCM = surface.widthCM
            var depthCM = surface.depthCM
            var origin: Vector3D?
            if let direction, !mappedPoints.isEmpty {
                let depth = direction.normalized.simd
                let width = SIMD3<Double>(depth.z, 0, -depth.x)
                let points: [SIMD3<Double>]
                if let geometry = surface.geometry, geometry.isApproved {
                    points = geometry.approvedBoundary.map(\.simd)
                } else {
                    points = mappedPoints.map(SIMD3<Double>.init)
                }
                let widths = points.map { simd_dot($0, width) }
                let depths = points.map { simd_dot($0, depth) }
                if let minWidth = widths.min(), let maxWidth = widths.max(),
                   let minDepth = depths.min(), let maxDepth = depths.max() {
                    widthCM = (maxWidth - minWidth) * 100
                    depthCM = (maxDepth - minDepth) * 100
                    origin = Vector3D(width * minWidth + depth * minDepth)
                }
            }
            measuredSurfaces.wrappedValue = [
                MeasuredShelfSurface(
                    id: surface.id, widthCM: widthCM, depthCM: depthCM,
                    measuredFreeHeightCM: surface.measuredFreeHeightCM,
                    frontDirectionLocal: direction, originLocal: origin,
                    scanConfidence: surface.scanConfidence,
                    boundaryClosed: surface.boundaryClosed,
                    geometry: surface.geometry,
                    boundaryAnalysis: surface.boundaryAnalysis,
                    cornerMetadata: surface.cornerMetadata,
                    measuredSpaceCorners: surface.measuredSpaceCorners,
                    scannedBoundary: surface.scannedBoundary
                )
            ]
        }

        @MainActor
        private func clearFrontSelection() {
            replaceFrontDirection(nil)
            frontAnchor?.removeFromParent()
            frontAnchor = nil
        }

        @MainActor
        private func showFrontArrow(direction: SIMD3<Float>) {
            guard let arView, let plane = selectedPlane, !mappedPoints.isEmpty else { return }
            frontAnchor?.removeFromParent()
            let anchor = AnchorEntity(world: plane.transform)
            let centre = mappedPoints.reduce(SIMD3<Float>.zero, +) / Float(mappedPoints.count)
            let start = centre - direction * 0.12 + SIMD3<Float>(0, 0.035, 0)
            let end = centre + direction * 0.12 + SIMD3<Float>(0, 0.035, 0)
            anchor.addChild(line(from: start, to: end))
            var material = UnlitMaterial()
            material.color = .init(tint: .systemYellow, texture: nil)
            let head = ModelEntity(
                mesh: .generateBox(width: 0.055, height: 0.025, depth: 0.055),
                materials: [material]
            )
            head.position = end
            head.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)
            anchor.addChild(head)
            arView.scene.addAnchor(anchor)
            frontAnchor = anchor
        }

        @MainActor
        private func showGuidance(_ result: ProductPlacementResult?) {
            guidanceAnchor?.removeFromParent()
            guidanceAnchor = nil
            guard let result, let arView, let plane = selectedPlane,
                  let surface = measuredSurfaces.wrappedValue.first,
                  let front = surface.frontDirectionLocal,
                  let origin = surface.originLocal else { return }
            let depth = SIMD3<Float>(Float(front.x), 0, Float(front.z))
            let width = SIMD3<Float>(depth.z, 0, -depth.x)
            let localOrigin = SIMD3<Float>(Float(origin.x), Float(origin.y), Float(origin.z))
            let targetMin = localOrigin + width * Float(result.position.x / 100) +
                depth * Float(result.position.z / 100) + SIMD3<Float>(0, Float(result.position.y / 100), 0)
            let centre = targetMin + width * Float(result.orientedDimensions.widthCM / 200) +
                depth * Float(result.orientedDimensions.depthCM / 200) +
                SIMD3<Float>(0, Float(result.orientedDimensions.heightCM / 200), 0)
            var material = SimpleMaterial()
            material.color = .init(tint: UIColor.systemGreen.withAlphaComponent(0.28), texture: nil)
            let box = ModelEntity(
                mesh: .generateBox(width: Float(result.orientedDimensions.widthCM / 100),
                                   height: Float(result.orientedDimensions.heightCM / 100),
                                   depth: Float(result.orientedDimensions.depthCM / 100)),
                materials: [material]
            )
            box.position = centre
            box.orientation = simd_quatf(angle: atan2(-depth.x, depth.z), axis: SIMD3<Float>(0, 1, 0))
            let anchor = AnchorEntity(world: plane.transform)
            anchor.addChild(box)
            let arrowStart = localOrigin - depth * 0.18 + width * Float(result.position.x / 100)
            let arrowEnd = targetMin + width * Float(result.orientedDimensions.widthCM / 2 / 100)
            anchor.addChild(spatialLine(from: arrowStart + SIMD3<Float>(0, 0.06, 0),
                                        to: arrowEnd + SIMD3<Float>(0, 0.06, 0), color: .systemYellow))
            arView.scene.addAnchor(anchor)
            guidanceAnchor = anchor
        }

        /// Returns the visible surface under the reticle. LiDAR depth is
        /// preferred so the query stops on the shelf or product instead of
        /// selecting an infinite plane behind it.
        @MainActor
        private func visibleSurfacePointAtCentre() -> SIMD3<Float>? {
            guard let arView,
                  arView.bounds.width > 0,
                  arView.bounds.height > 0
            else { return nil }
            if let frame = arView.session.currentFrame,
               frame.smoothedSceneDepth != nil || frame.sceneDepth != nil {
                return depthPointAtCentre(frame: frame)
            }

            let centre = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            for target in [
                ARRaycastQuery.Target.estimatedPlane,
                .existingPlaneGeometry
            ] {
                if let result = arView.raycast(
                    from: centre,
                    allowing: target,
                    alignment: .any
                ).first {
                    let position = worldPosition(of: result)
                    if position.x.isFinite, position.y.isFinite, position.z.isFinite {
                        return position
                    }
                }
            }
            return nil
        }

        private func depthPointAtCentre(frame: ARFrame) -> SIMD3<Float>? {
            guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else {
                return nil
            }
            let depthMap = depthData.depthMap
            let confidenceMap = depthData.confidenceMap
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            if let confidenceMap {
                CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            }
            defer {
                CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
                if let confidenceMap {
                    CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
                }
            }
            guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
            let width = CVPixelBufferGetWidth(depthMap)
            let height = CVPixelBufferGetHeight(depthMap)
            let stride = CVPixelBufferGetBytesPerRow(depthMap)
                / MemoryLayout<Float32>.size
            let depths = depthBase.assumingMemoryBound(to: Float32.self)
            let confidence = confidenceMap
                .flatMap(CVPixelBufferGetBaseAddress)?
                .assumingMemoryBound(to: UInt8.self)
            let confidenceStride = confidenceMap.map(CVPixelBufferGetBytesPerRow) ?? 0
            let centreX = width / 2
            let centreY = height / 2
            let minimumConfidence = UInt8(ARConfidenceLevel.medium.rawValue)
            var candidates: [(depth: Float, x: Int, y: Int)] = []
            for y in max(0, centreY - 2)...min(height - 1, centreY + 2) {
                for x in max(0, centreX - 2)...min(width - 1, centreX + 2) {
                    let depth = depths[y * stride + x]
                    let level = confidence.map { $0[y * confidenceStride + x] }
                        ?? minimumConfidence
                    guard depth.isFinite, depth >= 0.10, depth <= 5,
                          level >= minimumConfidence
                    else { continue }
                    candidates.append((depth, x, y))
                }
            }
            guard !candidates.isEmpty else { return nil }
            candidates.sort { $0.depth < $1.depth }
            let candidate = candidates[candidates.count / 4]

            let resolution = frame.camera.imageResolution
            let scaleX = Float(width) / Float(resolution.width)
            let scaleY = Float(height) / Float(resolution.height)
            let intrinsics = frame.camera.intrinsics
            let fx = intrinsics.columns.0.x * scaleX
            let fy = intrinsics.columns.1.y * scaleY
            let cx = intrinsics.columns.2.x * scaleX
            let cy = intrinsics.columns.2.y * scaleY
            let cameraPoint = SIMD4<Float>(
                (Float(candidate.x) - cx) * candidate.depth / fx,
                -(Float(candidate.y) - cy) * candidate.depth / fy,
                -candidate.depth,
                1
            )
            let world = frame.camera.transform * cameraPoint
            let position = SIMD3<Float>(world.x, world.y, world.z)
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
                return nil
            }
            return position
        }

        private func showHeightMarkers() {
            guard let arView else { return }
            heightAnchor?.removeFromParent()
            let anchor = AnchorEntity(world: matrix_identity_float4x4)
            if let bottomPoint {
                anchor.addChild(heightMarker(at: bottomPoint, color: .systemGreen))
            }
            if let topPoint, let bottomPoint {
                anchor.addChild(heightMarker(at: topPoint, color: .systemPink))
                let verticalTop = SIMD3<Float>(bottomPoint.x, topPoint.y, bottomPoint.z)
                anchor.addChild(spatialLine(from: bottomPoint, to: verticalTop, color: .systemPink))
                if simd_distance(verticalTop, topPoint) > 0.002 {
                    anchor.addChild(spatialLine(from: verticalTop, to: topPoint, color: .systemPink))
                }
                addScanningPrism(to: anchor, bottomY: bottomPoint.y, topY: topPoint.y)
            }
            arView.scene.addAnchor(anchor)
            heightAnchor = anchor
        }

        private func heightMarker(at position: SIMD3<Float>, color: UIColor) -> ModelEntity {
            var material = UnlitMaterial()
            material.color = .init(tint: color, texture: nil)
            let marker = ModelEntity(
                mesh: .generateSphere(radius: 0.014),
                materials: [material]
            )
            marker.position = position
            return marker
        }

        private func spatialLine(
            from start: SIMD3<Float>,
            to end: SIMD3<Float>,
            color: UIColor
        ) -> ModelEntity {
            let delta = end - start
            let length = simd_length(delta)
            var material = UnlitMaterial()
            material.color = .init(tint: color, texture: nil)
            let entity = ModelEntity(
                mesh: .generateBox(width: 0.008, height: length, depth: 0.008),
                materials: [material]
            )
            entity.position = (start + end) / 2
            if length > 0 {
                entity.orientation = simd_quatf(
                    from: SIMD3<Float>(0, 1, 0),
                    to: delta / length
                )
            }
            return entity
        }

        /// Mirrors the product scanner's cyan scanning prism so the user can
        /// see the entire measured shelf space between the two height limits.
        private func addScanningPrism(
            to anchor: AnchorEntity,
            bottomY: Float,
            topY: Float
        ) {
            guard let boundaryMeasurement else { return }
            let plane = boundaryMeasurement.plane
            let base = boundaryMeasurement.projectedBoundary.map {
                SIMD3<Float>(plane.origin + plane.axisU * $0.x + plane.axisV * $0.y)
            }
            let lower = base.map { SIMD3<Float>($0.x, bottomY, $0.z) }
            let upper = base.map { SIMD3<Float>($0.x, topY, $0.z) }
            guard lower.count >= 3, lower.count == upper.count else { return }
            for index in lower.indices {
                let next = (index + 1) % lower.count
                anchor.addChild(spatialLine(
                    from: lower[index],
                    to: lower[next],
                    color: .systemCyan
                ))
                anchor.addChild(spatialLine(
                    from: upper[index],
                    to: upper[next],
                    color: .systemCyan
                ))
                anchor.addChild(spatialLine(
                    from: lower[index],
                    to: upper[index],
                    color: UIColor.systemCyan.withAlphaComponent(0.65)
                ))
            }
        }

        /// Draws the shelf footprint using the same cyan boundary language as
        /// the product scanner.
        private func showMappedArea(on plane: ARPlaneAnchor) {
            guard let arView else { return }
            selectionAnchor?.removeFromParent()

            let anchor = AnchorEntity(world: plane.transform)

            for point in mappedPoints {
                var pointMaterial = UnlitMaterial()
                pointMaterial.color = .init(tint: .systemCyan, texture: nil)
                let marker = ModelEntity(
                    mesh: .generateSphere(radius: 0.012),
                    materials: [pointMaterial]
                )
                marker.position = point
                anchor.addChild(marker)
            }

            for index in 1..<mappedPoints.count {
                anchor.addChild(line(from: mappedPoints[index - 1], to: mappedPoints[index]))
            }

            if mappedPoints.count >= 3, let last = mappedPoints.last,
               let first = mappedPoints.first {
                anchor.addChild(line(from: last, to: first))
                if let fill = polygonFill() {
                    anchor.addChild(fill)
                }
            }

            arView.scene.addAnchor(anchor)
            selectionAnchor = anchor
        }

        private func line(from start: SIMD3<Float>, to end: SIMD3<Float>) -> ModelEntity {
            let delta = end - start
            let length = simd_length(SIMD2<Float>(delta.x, delta.z))
            var material = UnlitMaterial()
            material.color = .init(tint: .systemCyan, texture: nil)
            let entity = ModelEntity(
                mesh: .generateBox(width: length, height: 0.006, depth: 0.008),
                materials: [material]
            )
            entity.position = (start + end) / 2
            entity.orientation = simd_quatf(
                angle: atan2(-delta.z, delta.x),
                axis: SIMD3<Float>(0, 1, 0)
            )
            return entity
        }

        private func polygonFill() -> ModelEntity? {
            var descriptor = MeshDescriptor(name: "Mapped shelf area")
            descriptor.positions = MeshBuffers.Positions(
                mappedPoints.map { SIMD3<Float>($0.x, 0.002, $0.z) }
            )

            var indices: [UInt32] = []
            for index in 1..<(mappedPoints.count - 1) {
                let current = UInt32(index)
                let next = UInt32(index + 1)
                // Include both windings so the surface is visible from either side.
                indices.append(contentsOf: [0, current, next, 0, next, current])
            }
            descriptor.primitives = .triangles(indices)

            guard let mesh = try? MeshResource.generate(from: [descriptor]) else {
                return nil
            }
            var material = UnlitMaterial()
            material.color = .init(
                tint: UIColor.systemCyan.withAlphaComponent(0.22),
                texture: nil
            )
            return ModelEntity(mesh: mesh, materials: [material])
        }
    }
}
