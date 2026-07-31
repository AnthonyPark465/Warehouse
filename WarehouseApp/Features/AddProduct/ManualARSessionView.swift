import ARKit
import AVFoundation
import os
import SceneKit
import SwiftUI

/// ARKit/SceneKit bridge for manual product measurement.
///
/// The targeting dot is SwiftUI screen-space UI. This view owns only the AR
/// camera, centre raycasts, real-world anchors, and lightweight scene geometry.
struct ManualARSessionView: UIViewRepresentable {
    @ObservedObject var state: ManualARMeasurementState

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.handle(
            placementRequestID: state.placementRequestID,
            renderRevision: state.renderRevision,
            productScanStartRequestID: state.productScanStartRequestID,
            productScanStopRequestID: state.productScanStopRequestID
        )
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, ARSessionDelegate, ARSCNViewDelegate {
        private weak var sceneView: ARSCNView?
        private let state: ManualARMeasurementState
        private let previewNode = SCNNode()
        private let measurementGeometryNode = SCNNode()
        private var markerAnchors: [ARAnchor] = []
        private var renderedMarkerPositions: [SIMD3<Float>] = []
        private var lastPreviewUpdate: TimeInterval = 0
        private var handledPlacementRequestID = 0
        private var renderedRevision = -1
        private var handledProductScanStartRequestID = 0
        private var handledProductScanStopRequestID = 0
        private let fusionConfiguration = LiDARFusionConfiguration.smallObject
        private var fusion = LiDARVoxelFusionEngine()
        private var stabilizer = LiDARMeasurementStabilizer()
        private var stableProductMeasurement: LiDARFusionMeasurement?
        private var latestProductStatus = ManualProductScanStatus()
        private var fusionFrameCount = 0
        private var rejectedOutsideRegionCount = 0
        // Read on the ARKit delegate thread and the fusion queue, written on
        // the main actor — must be lock-protected, not a plain Bool.
        private let productScanIsActive = OSAllocatedUnfairLock(initialState: false)
        private let fusionQueue = DispatchQueue(
            label: "com.tetris.warehouse.manual-region-fusion",
            qos: .userInitiated
        )

        init(state: ManualARMeasurementState) {
            self.state = state
            super.init()
        }

        @MainActor
        func attach(to view: ARSCNView) {
            sceneView = view
            view.scene = SCNScene()
            view.delegate = self
            view.session.delegate = self
            view.automaticallyUpdatesLighting = false
            view.preferredFramesPerSecond = 60
            view.scene.rootNode.addChildNode(measurementGeometryNode)
            installPreviewNode(in: view)

            guard ARWorldTrackingConfiguration.isSupported else {
                state.errorMessage = "This device does not support AR world tracking. Enter dimensions manually."
                return
            }

            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                startSession(resetTracking: true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    Task { @MainActor in
                        guard let self else { return }
                        if granted {
                            self.startSession(resetTracking: true)
                        } else {
                            self.state.errorMessage = "Camera access is required for AR measurement. Enable Camera in Settings or enter dimensions manually."
                        }
                    }
                }
            case .denied, .restricted:
                state.errorMessage = "Camera access is disabled. Enable Camera in Settings or enter dimensions manually."
            @unknown default:
                state.errorMessage = "Camera access could not be determined. Enter dimensions manually."
            }
        }

        @MainActor
        func stop() {
            guard let sceneView else { return }
            markerAnchors.forEach { sceneView.session.remove(anchor: $0) }
            markerAnchors.removeAll()
            renderedMarkerPositions.removeAll()
            sceneView.session.delegate = nil
            sceneView.delegate = nil
            sceneView.session.pause()
        }

        @MainActor
        func handle(
            placementRequestID: Int,
            renderRevision: Int,
            productScanStartRequestID: Int,
            productScanStopRequestID: Int
        ) {
            if placementRequestID != handledPlacementRequestID {
                handledPlacementRequestID = placementRequestID
                // Defer published state changes until after SwiftUI finishes
                // this representable update. The placement still performs a
                // fresh surface query rather than promoting the preview.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.state.place(self.raycastAtCentre())
                }
            }
            if renderRevision != renderedRevision {
                renderedRevision = renderRevision
                rebuildPermanentGeometry()
            }
            if productScanStopRequestID != handledProductScanStopRequestID {
                handledProductScanStopRequestID = productScanStopRequestID
                productScanIsActive.withLock { $0 = false }
            }
            if productScanStartRequestID != handledProductScanStartRequestID {
                handledProductScanStartRequestID = productScanStartRequestID
                DispatchQueue.main.async { [weak self] in
                    self?.startProductFusion()
                }
            }
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // Throttle before crossing to the main actor. Do not capture the
            // ARFrame in the Task because it owns large camera buffers.
            let now = frame.timestamp
            guard now - lastPreviewUpdate >= 0.1 else { return }
            lastPreviewUpdate = now
            let trackingState = frame.camera.trackingState
            let shouldIntegrate: Bool
            if case .normal = trackingState {
                shouldIntegrate = productScanIsActive.withLock { $0 }
            } else {
                shouldIntegrate = false
            }
            let scanPoints = shouldIntegrate ? extractMeasurementPoints(from: frame) : []
            Task { @MainActor [weak self] in
                guard let self else { return }
                state.updateTracking(trackingState)
                let sample = raycastAtCentre()
                state.updatePreview(sample)
                updatePreview(sample)
            }
            guard !scanPoints.isEmpty else { return }
            fusionQueue.async { [weak self] in
                self?.integrateProductPoints(scanPoints)
            }
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            Task { @MainActor [weak self] in
                self?.state.errorMessage = "AR session failed: \(error.localizedDescription) Restart measurement or enter dimensions manually."
            }
        }

        func sessionWasInterrupted(_ session: ARSession) {
            Task { @MainActor [weak self] in
                self?.state.errorMessage = "Measurement was interrupted. Keep the product in view while tracking recovers."
            }
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            Task { @MainActor [weak self] in
                self?.startSession(resetTracking: false)
            }
        }

        func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
            true
        }

        func renderer(
            _ renderer: SCNSceneRenderer,
            didAdd node: SCNNode,
            for anchor: ARAnchor
        ) {
            guard let name = anchor.name else { return }
            let color: UIColor
            switch name {
            case AnchorName.boundary:
                color = .systemCyan
            case AnchorName.bottom:
                color = .systemGreen
            case AnchorName.top:
                color = .systemPink
            default:
                return
            }
            node.addChildNode(makeSphere(radius: 0.009, color: color))
        }

        @MainActor
        private func startSession(resetTracking: Bool) {
            guard let sceneView else { return }
            let options: ARSession.RunOptions = resetTracking
                ? [.resetTracking, .removeExistingAnchors]
                : []
            sceneView.session.run(makeConfiguration(), options: options)
        }

        @MainActor
        private func startProductFusion() {
            guard let region = state.productScanRegion,
                  let seed = state.productSeed
            else {
                state.errorMessage = "The scanning region is incomplete. Set the polygon, bottom limit, and top limit again."
                return
            }
            productScanIsActive.withLock { $0 = false }
            fusionQueue.sync {
                fusion.reset()
                fusion.lockSelection(region: .polygonalPrism(region), seed: seed)
                stabilizer.reset()
                stableProductMeasurement = nil
                latestProductStatus = ManualProductScanStatus()
                fusionFrameCount = 0
                rejectedOutsideRegionCount = 0
            }
            productScanIsActive.withLock { $0 = true }
        }

        private func integrateProductPoints(_ points: [SIMD3<Float>]) {
            guard productScanIsActive.withLock({ $0 }) else { return }
            let result = fusion.integrate(framePoints: points)
            fusionFrameCount += 1
            rejectedOutsideRegionCount += result.rejectedOutsideVolumeCount

            guard fusionFrameCount.isMultiple(of: 4),
                  let measurement = fusion.measurement()
            else {
                var progress = latestProductStatus
                progress.updateCaptureProgress(
                    message: "Collecting product surfaces inside the scanning region…",
                    integratedFrameCount: fusionFrameCount,
                    capturedPointCount: fusion.voxelCount,
                    rejectedOutsideRegionCount: rejectedOutsideRegionCount
                )
                publishProductStatus(progress)
                return
            }

            let decision = stabilizer.consider(measurement.dimensionsCM)
            let dimensions: ObjectDimensions?
            let isStable: Bool
            let message: String
            switch decision {
            case .warmingUp:
                dimensions = measurement.dimensionsCM
                isStable = false
                message = "Product detected. Scan more sides while dimensions stabilise."
            case .accepted(let accepted):
                dimensions = accepted
                isStable = true
                stableProductMeasurement = measurement
                message = measurement.touchesRegionBoundary
                    ? "The detected product touches the scanning limit. Expand the region."
                    : "Detected product is stable. Scan the top and any unseen side."
            case .frozen(let frozen, let reason):
                dimensions = frozen
                isStable = false
                message = reason
            }

            let displayMeasurement = stableProductMeasurement ?? measurement
            let confidence = productConfidence(
                measurement: displayMeasurement,
                dimensionsAreStable: isStable
            )
            // A complete orange product box means fusion has already retained
            // enough repeated, connected surface points to form valid bounds.
            // Let the user finish at that point; stability still improves the
            // result but is no longer required to enable the button.
            let canFinish = ManualProductScanStatus.finishIsAvailable(
                dimensions: dimensions,
                stablePointCount: displayMeasurement.fusedVoxelCount,
                boundingBoxCornersWorld: displayMeasurement.boundingBoxCornersWorld,
                touchesBoundary: displayMeasurement.touchesRegionBoundary
            )
            publishProductStatus(ManualProductScanStatus(
                message: message,
                integratedFrameCount: fusionFrameCount,
                capturedPointCount: fusion.voxelCount,
                stablePointCount: displayMeasurement.fusedVoxelCount,
                rejectedOutsideRegionCount: rejectedOutsideRegionCount,
                detectedDimensionsCM: dimensions,
                detectedWorldPoints: displayMeasurement.worldPointsInMetres,
                centredDisplayPoints: displayMeasurement.centredPointsInMetres,
                boundingBoxCornersWorld: displayMeasurement.boundingBoxCornersWorld,
                confidence: confidence,
                dimensionsAreStable: isStable,
                touchesBoundary: displayMeasurement.touchesRegionBoundary,
                canFinish: canFinish
            ))
        }

        private func productConfidence(
            measurement: LiDARFusionMeasurement,
            dimensionsAreStable: Bool
        ) -> Double {
            let frameScore = min(
                Double(fusionFrameCount)
                    / Double(fusionConfiguration.minimumFusedFrameCount * 2),
                1
            )
            let voxelScore = min(
                Double(measurement.fusedVoxelCount)
                    / Double(fusionConfiguration.minimumStableVoxelCount * 6),
                1
            )
            let observationScore = min(measurement.averageObservationsPerVoxel / 8, 1)
            let stabilityScore = dimensionsAreStable ? 1.0 : 0.25
            return min(
                frameScore * 0.25
                    + voxelScore * 0.25
                    + observationScore * 0.20
                    + stabilityScore * 0.30,
                0.95
            )
        }

        private func publishProductStatus(_ status: ManualProductScanStatus) {
            latestProductStatus = status
            DispatchQueue.main.async { [weak self] in
                guard let self, self.productScanIsActive.withLock({ $0 }) else { return }
                self.state.updateProductScan(status)
            }
        }

        private func makeConfiguration() -> ARWorldTrackingConfiguration {
            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity
            configuration.planeDetection = [.horizontal, .vertical]
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
            return configuration
        }

        private func extractMeasurementPoints(from frame: ARFrame) -> [SIMD3<Float>] {
            if let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth {
                return extractDepthPoints(depthData, frame: frame)
            }
            // Non-LiDAR fallback: feature points remain spatially filtered by
            // the same polygonal prism before entering fusion.
            return frame.rawFeaturePoints.map { Array($0.points) } ?? []
        }

        private func extractDepthPoints(
            _ depthData: ARDepthData,
            frame: ARFrame
        ) -> [SIMD3<Float>] {
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
            guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return [] }
            let width = CVPixelBufferGetWidth(depthMap)
            let height = CVPixelBufferGetHeight(depthMap)
            let depthStride = CVPixelBufferGetBytesPerRow(depthMap)
                / MemoryLayout<Float32>.size
            let depths = depthBase.assumingMemoryBound(to: Float32.self)
            let confidence = confidenceMap
                .flatMap(CVPixelBufferGetBaseAddress)?
                .assumingMemoryBound(to: UInt8.self)
            let confidenceStride = confidenceMap.map(CVPixelBufferGetBytesPerRow) ?? 0
            var points: [SIMD3<Float>] = []
            points.reserveCapacity(width * height / 4)
            for y in stride(from: 0, to: height, by: 2) {
                for x in stride(from: 0, to: width, by: 2) {
                    let depth = depths[y * depthStride + x]
                    guard depth.isFinite, depth >= 0.10, depth <= 5 else { continue }
                    if let confidence,
                       confidence[y * confidenceStride + x]
                        < ARConfidenceLevel.medium.rawValue {
                        continue
                    }
                    points.append(worldPoint(
                        x: x,
                        y: y,
                        depth: depth,
                        depthWidth: width,
                        depthHeight: height,
                        frame: frame
                    ))
                }
            }
            return points
        }

        private func worldPoint(
            x: Int,
            y: Int,
            depth: Float,
            depthWidth: Int,
            depthHeight: Int,
            frame: ARFrame
        ) -> SIMD3<Float> {
            let resolution = frame.camera.imageResolution
            let scaleX = Float(depthWidth) / Float(resolution.width)
            let scaleY = Float(depthHeight) / Float(resolution.height)
            let intrinsics = frame.camera.intrinsics
            let fx = intrinsics.columns.0.x * scaleX
            let fy = intrinsics.columns.1.y * scaleY
            let cx = intrinsics.columns.2.x * scaleX
            let cy = intrinsics.columns.2.y * scaleY
            let cameraPoint = SIMD4<Float>(
                (Float(x) - cx) * depth / fx,
                -(Float(y) - cy) * depth / fy,
                -depth,
                1
            )
            let world = frame.camera.transform * cameraPoint
            return SIMD3(world.x, world.y, world.z)
        }

        @MainActor
        private func raycastAtCentre() -> CentreRaycastSample? {
            guard let sceneView,
                  sceneView.bounds.width > 0,
                  sceneView.bounds.height > 0
            else { return nil }
            let centre = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)

            if state.stage == .topLimit {
                // Plane raycasts do not understand visual occlusion and an
                // infinite floor plane can therefore be returned through the
                // product. On LiDAR devices, use the nearest foreground depth
                // sample at the reticle and fail closed if it is not above the
                // selected bottom. Do not fall back through the object.
                if let frame = sceneView.session.currentFrame,
                   frame.smoothedSceneDepth != nil || frame.sceneDepth != nil {
                    guard let sample = depthSampleAtCentre(frame: frame),
                          isUsableTopSample(sample)
                    else { return nil }
                    return sample
                }

                // Non-LiDAR fallback: use only finite/estimated surfaces.
                // Infinite planes are deliberately excluded for the top marker.
                for target in [
                    ARRaycastQuery.Target.estimatedPlane,
                    .existingPlaneGeometry
                ] {
                    if let result = raycast(from: centre, target: target, in: sceneView),
                       let sample = sample(from: result, target: target, in: sceneView),
                       isUsableTopSample(sample) {
                        return sample
                    }
                }
                return nil
            }

            let existing = raycast(
                from: centre,
                target: .existingPlaneGeometry,
                in: sceneView
            )
            let infinite = existing == nil
                ? raycast(from: centre, target: .existingPlaneInfinite, in: sceneView)
                : nil
            let estimated = existing == nil && infinite == nil
                ? raycast(from: centre, target: .estimatedPlane, in: sceneView)
                : nil
            let result = existing ?? infinite ?? estimated
            guard let result else { return nil }

            let target: ARRaycastQuery.Target = existing != nil
                ? .existingPlaneGeometry
                : (infinite != nil ? .existingPlaneInfinite : .estimatedPlane)
            return sample(from: result, target: target, in: sceneView)
        }

        @MainActor
        private func sample(
            from result: ARRaycastResult,
            target: ARRaycastQuery.Target,
            in sceneView: ARSCNView
        ) -> CentreRaycastSample? {

            let position = SIMD3<Float>(
                result.worldTransform.columns.3.x,
                result.worldTransform.columns.3.y,
                result.worldTransform.columns.3.z
            )
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
                return nil
            }

            let cameraPosition: SIMD3<Float>
            if let frame = sceneView.session.currentFrame {
                cameraPosition = SIMD3(
                    frame.camera.transform.columns.3.x,
                    frame.camera.transform.columns.3.y,
                    frame.camera.transform.columns.3.z
                )
            } else {
                cameraPosition = position
            }
            let alignment: String
            if let plane = result.anchor as? ARPlaneAnchor {
                alignment = plane.alignment == .horizontal ? "horizontal plane" : "vertical plane"
            } else {
                alignment = "estimated surface"
            }
            let raycastType: String
            if target == .existingPlaneGeometry {
                raycastType = "existingPlaneGeometry"
            } else if target == .existingPlaneInfinite {
                raycastType = "existingPlaneInfinite"
            } else {
                raycastType = "estimatedPlane"
            }
            let distance = Double(simd_distance(cameraPosition, position))
            let distanceScore = max(0.4, 1 - abs(distance - 0.6) / 2)
            let surfaceScore = target == .existingPlaneGeometry ? 0.88 : 0.70
            return CentreRaycastSample(
                position: position,
                raycastType: raycastType,
                surfaceAlignment: alignment,
                confidence: min(surfaceScore * distanceScore, 0.95),
                cameraDistanceMetres: distance
            )
        }

        @MainActor
        private func depthSampleAtCentre(frame: ARFrame) -> CentreRaycastSample? {
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
            var candidates: [(depth: Float, x: Int, y: Int, confidence: UInt8)] = []
            for y in max(0, centreY - 2)...min(height - 1, centreY + 2) {
                for x in max(0, centreX - 2)...min(width - 1, centreX + 2) {
                    let depth = depths[y * stride + x]
                    let level = confidence.map { $0[y * confidenceStride + x] }
                        ?? minimumConfidence
                    guard depth.isFinite, depth >= 0.10, depth <= 5,
                          level >= minimumConfidence
                    else { continue }
                    candidates.append((depth, x, y, level))
                }
            }
            guard !candidates.isEmpty else { return nil }
            candidates.sort { $0.depth < $1.depth }
            // Prefer the foreground quartile so an edge reticle does not pick
            // the floor/background visible beside the product.
            let candidate = candidates[candidates.count / 4]
            let position = worldPoint(
                x: candidate.x,
                y: candidate.y,
                depth: candidate.depth,
                depthWidth: width,
                depthHeight: height,
                frame: frame
            )
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
                return nil
            }
            let cameraPosition = SIMD3<Float>(
                frame.camera.transform.columns.3.x,
                frame.camera.transform.columns.3.y,
                frame.camera.transform.columns.3.z
            )
            let distance = Double(simd_distance(cameraPosition, position))
            let surfaceScore = candidate.confidence
                    == UInt8(ARConfidenceLevel.high.rawValue)
                ? 0.92
                : 0.82
            return CentreRaycastSample(
                position: position,
                raycastType: "sceneDepth",
                surfaceAlignment: "visible depth surface",
                confidence: surfaceScore,
                cameraDistanceMetres: distance
            )
        }

        @MainActor
        private func isUsableTopSample(_ sample: CentreRaycastSample) -> Bool {
            guard let bottom = state.bottomMarker,
                  let boundary = state.boundaryMeasurement,
                  sample.position.y - bottom.position.simd.y
                    >= Float(ManualMeasurementGeometry.minimumHeightMetres)
            else { return false }
            return (try? ManualMeasurementGeometry.height(
                top: sample.position,
                bottom: bottom.position.simd,
                boundary: boundary
            )) != nil
        }

        @MainActor
        private func raycast(
            from point: CGPoint,
            target: ARRaycastQuery.Target,
            in view: ARSCNView
        ) -> ARRaycastResult? {
            guard let query = view.raycastQuery(
                from: point,
                allowing: target,
                alignment: .any
            ) else { return nil }
            return view.session.raycast(query).first
        }

        @MainActor
        private func installPreviewNode(in view: ARSCNView) {
            previewNode.geometry = SCNSphere(radius: 0.006)
            previewNode.geometry?.firstMaterial = material(
                color: UIColor.systemYellow.withAlphaComponent(0.65)
            )
            previewNode.isHidden = true
            view.scene.rootNode.addChildNode(previewNode)
        }

        @MainActor
        private func updatePreview(_ sample: CentreRaycastSample?) {
            guard let sample else {
                previewNode.isHidden = true
                return
            }
            previewNode.simdWorldPosition = sample.position
            previewNode.isHidden = false
        }

        @MainActor
        private func rebuildPermanentGeometry() {
            guard let sceneView else { return }

            measurementGeometryNode.childNodes.forEach { $0.removeFromParentNode() }

            let boundary = state.boundaryMarkers.map { $0.position.simd }
            let bottom = state.bottomMarker?.position.simd
            let top = state.topMarker?.position.simd
            let markerPositions = boundary + [bottom, top].compactMap { $0 }
            if markerPositions != renderedMarkerPositions {
                markerAnchors.forEach { sceneView.session.remove(anchor: $0) }
                markerAnchors.removeAll()
                boundary.forEach {
                    addMarkerAnchor(at: $0, name: AnchorName.boundary)
                }
                if let bottom {
                    addMarkerAnchor(at: bottom, name: AnchorName.bottom)
                }
                if let top {
                    addMarkerAnchor(at: top, name: AnchorName.top)
                }
                renderedMarkerPositions = markerPositions
            }
            for (start, end) in zip(boundary, boundary.dropFirst()) {
                addLine(from: start, to: end, color: .systemCyan)
            }
            if state.boundaryMeasurement != nil,
               boundary.count >= 3,
               let first = boundary.first,
               let last = boundary.last {
                addLine(from: last, to: first, color: .systemCyan)
                addBoundarySurface()
            }
            if let top {
                if let bottom {
                    addLine(from: bottom, to: top, color: .systemPink)
                }
            }
            if state.productScanRegion != nil {
                addScanningPrism()
            }
            addDetectedProduct()
        }

        @MainActor
        private func addMarkerAnchor(at position: SIMD3<Float>, name: String) {
            guard let sceneView else { return }
            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4(position.x, position.y, position.z, 1)
            let anchor = ARAnchor(name: name, transform: transform)
            markerAnchors.append(anchor)
            sceneView.session.add(anchor: anchor)
        }

        @MainActor
        private func addLine(
            from start: SIMD3<Float>,
            to end: SIMD3<Float>,
            color: UIColor
        ) {
            let vector = end - start
            let length = simd_length(vector)
            guard length.isFinite, length > 0.000_1 else { return }
            let line = SCNNode(geometry: SCNCylinder(radius: 0.0025, height: CGFloat(length)))
            line.geometry?.firstMaterial = material(color: color)
            line.simdPosition = (start + end) / 2
            line.simdOrientation = simd_quatf(
                from: SIMD3<Float>(0, 1, 0),
                to: simd_normalize(vector)
            )
            measurementGeometryNode.addChildNode(line)
        }

        @MainActor
        private func addBoundarySurface() {
            guard let measurement = state.boundaryMeasurement else { return }
            let plane = measurement.plane
            let positions = measurement.projectedBoundary.map {
                SIMD3<Float>(plane.origin + plane.axisU * $0.x + plane.axisV * $0.y)
            }
            let indices = ManualMeasurementGeometry.triangulationIndices(
                for: measurement.projectedBoundary
            )
            guard positions.count >= 3, !indices.isEmpty else { return }

            let source = SCNGeometrySource(vertices: positions.map {
                SCNVector3($0.x, $0.y, $0.z)
            })
            let indexData = indices.withUnsafeBytes { Data($0) }
            let element = SCNGeometryElement(
                data: indexData,
                primitiveType: .triangles,
                primitiveCount: indices.count / 3,
                bytesPerIndex: MemoryLayout<UInt32>.size
            )
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let surfaceMaterial = material(
                color: UIColor.systemCyan.withAlphaComponent(0.22)
            )
            surfaceMaterial.isDoubleSided = true
            geometry.materials = [surfaceMaterial]
            measurementGeometryNode.addChildNode(SCNNode(geometry: geometry))
        }

        @MainActor
        private func addScanningPrism() {
            guard let region = state.productScanRegion else { return }
            let lower = region.polygon.map {
                region.origin
                    + region.axisU * $0.x
                    + region.axisV * $0.y
                    + region.normal * region.lowerOffset
            }
            let upper = region.polygon.map {
                region.origin
                    + region.axisU * $0.x
                    + region.axisV * $0.y
                    + region.normal * region.upperOffset
            }
            guard lower.count >= 3, lower.count == upper.count else { return }
            for index in lower.indices {
                let next = (index + 1) % lower.count
                addLine(from: lower[index], to: lower[next], color: .systemCyan)
                addLine(from: upper[index], to: upper[next], color: .systemCyan)
                addLine(
                    from: lower[index],
                    to: upper[index],
                    color: UIColor.systemCyan.withAlphaComponent(0.65)
                )
            }
        }

        @MainActor
        private func addDetectedProduct() {
            let status = state.productScanStatus
            if !status.detectedWorldPoints.isEmpty {
                let step = max(1, status.detectedWorldPoints.count / 3_000)
                let points = status.detectedWorldPoints.enumerated().compactMap {
                    $0.offset.isMultiple(of: step) ? $0.element : nil
                }
                let source = SCNGeometrySource(vertices: points.map {
                    SCNVector3($0.x, $0.y, $0.z)
                })
                let indices = points.indices.map(UInt32.init)
                let element = SCNGeometryElement(
                    data: indices.withUnsafeBytes { Data($0) },
                    primitiveType: .point,
                    primitiveCount: indices.count,
                    bytesPerIndex: MemoryLayout<UInt32>.size
                )
                element.pointSize = 5
                element.minimumPointScreenSpaceRadius = 2
                element.maximumPointScreenSpaceRadius = 7
                let geometry = SCNGeometry(sources: [source], elements: [element])
                geometry.firstMaterial = material(
                    color: UIColor.systemGreen.withAlphaComponent(0.9)
                )
                measurementGeometryNode.addChildNode(SCNNode(geometry: geometry))
            }

            let corners = status.boundingBoxCornersWorld
            guard corners.count == 8 else { return }
            let edgePairs = [
                (0, 1), (1, 2), (2, 3), (3, 0),
                (4, 5), (5, 6), (6, 7), (7, 4),
                (0, 4), (1, 5), (2, 6), (3, 7)
            ]
            edgePairs.forEach {
                addLine(
                    from: corners[$0.0],
                    to: corners[$0.1],
                    color: .systemOrange
                )
            }
            if let dimensions = status.detectedDimensionsCM {
                let firstHorizontalIsLength =
                    simd_distance(corners[0], corners[1])
                    >= simd_distance(corners[1], corners[2])
                addDimensionLabel(
                    "\(firstHorizontalIsLength ? "Length" : "Width"): \((firstHorizontalIsLength ? dimensions.length : dimensions.width).formatted(.number.precision(.fractionLength(2)))) cm",
                    at: (corners[0] + corners[1]) / 2
                )
                addDimensionLabel(
                    "\(firstHorizontalIsLength ? "Width" : "Length"): \((firstHorizontalIsLength ? dimensions.width : dimensions.length).formatted(.number.precision(.fractionLength(2)))) cm",
                    at: (corners[1] + corners[2]) / 2
                )
                addDimensionLabel(
                    "Height: \(dimensions.height.formatted(.number.precision(.fractionLength(2)))) cm",
                    at: (corners[0] + corners[4]) / 2
                )
            }
        }

        @MainActor
        private func addDimensionLabel(_ text: String, at position: SIMD3<Float>) {
            let textGeometry = SCNText(string: text, extrusionDepth: 0)
            textGeometry.font = .systemFont(ofSize: 8, weight: .semibold)
            textGeometry.flatness = 0.2
            textGeometry.firstMaterial = material(color: .white)
            let node = SCNNode(geometry: textGeometry)
            node.scale = SCNVector3(0.002, 0.002, 0.002)
            node.simdPosition = position + SIMD3<Float>(0, 0.015, 0)
            node.constraints = [SCNBillboardConstraint()]
            measurementGeometryNode.addChildNode(node)
        }

        private func makeSphere(radius: CGFloat, color: UIColor) -> SCNNode {
            let sphere = SCNSphere(radius: radius)
            sphere.firstMaterial = material(color: color)
            return SCNNode(geometry: sphere)
        }

        private func material(color: UIColor) -> SCNMaterial {
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.lightingModel = .constant
            material.writesToDepthBuffer = true
            return material
        }
    }
}

private enum AnchorName {
    static let boundary = "manualMeasurement.boundary"
    static let bottom = "manualMeasurement.bottom"
    static let top = "manualMeasurement.top"
}
