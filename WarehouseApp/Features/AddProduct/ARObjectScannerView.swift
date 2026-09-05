import ARKit
import RealityKit
import SwiftUI

struct ObjectScanSelectionSettings: Equatable {
    var screenWidthFraction: Float = 0.42
    var screenHeightFraction: Float = 0.52
    var volumeWidth: Float = 0.14
    var volumeHeight: Float = 0.16
    var volumeDepth: Float = 0.14

    static let smallObject = ObjectScanSelectionSettings()
}

struct ObjectScanLiveStatus: Equatable {
    var message = "Adjust the box tightly around the object."
    var pointCount = 0
    var rejectedPointCount = 0
    var dimensionsCM: ObjectDimensions?
    var confidence = 0.0
    var trackingIsNormal = false
    var integratedFrameCount = 0
    var selectionIsLocked = false
    var measurementIsStable = false
    var canFinish = false
}

/// Small-object LiDAR capture. ARFrame and pixel buffers stay inside the
/// callback; only copied world-space SIMD points cross onto the fusion queue.
struct ARObjectScannerView: UIViewRepresentable {
    let isScanning: Bool
    let resetToken: Int
    let selectionSettings: ObjectScanSelectionSettings
    let onStatus: (ObjectScanLiveStatus) -> Void
    let onCapture: (ObjectScanCapture?, String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isScanning: isScanning,
            resetToken: resetToken,
            selectionSettings: selectionSettings,
            onStatus: onStatus,
            onCapture: onCapture
        )
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        context.coordinator.arView = view
        let configuration = ARWorldTrackingConfiguration()
        configuration.environmentTexturing = .none
        configuration.sceneReconstruction = .mesh
        configuration.frameSemantics.insert(.smoothedSceneDepth)
        configuration.planeDetection = [.horizontal]
        view.session.delegate = context.coordinator
        // All coordinator state is confined to the fusion queue; delegate
        // callbacks are delivered there so no state crosses threads.
        view.session.delegateQueue = context.coordinator.fusionQueue
        view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.update(
            isScanning: isScanning,
            resetToken: resetToken,
            selectionSettings: selectionSettings
        )
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.delegate = nil
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        weak var arView: ARView?

        private let configuration = LiDARFusionConfiguration.smallObject
        private let onStatus: (ObjectScanLiveStatus) -> Void
        private let onCapture: (ObjectScanCapture?, String?) -> Void
        private var isScanning: Bool
        private var resetToken: Int
        private var selectionSettings: ObjectScanSelectionSettings
        private var fusion: LiDARVoxelFusionEngine
        private var stabilizer: LiDARMeasurementStabilizer
        private var currentStatus = ObjectScanLiveStatus()
        private var lastProcessedTime: TimeInterval = 0
        private var awaitingSelectionLock = false
        private var selectionAnchorEntity: AnchorEntity?
        private var stableMeasurement: LiDARFusionMeasurement?
        let fusionQueue = DispatchQueue(
            label: "com.tetris.warehouse.lidar-fusion",
            qos: .userInitiated
        )

        init(
            isScanning: Bool,
            resetToken: Int,
            selectionSettings: ObjectScanSelectionSettings,
            onStatus: @escaping (ObjectScanLiveStatus) -> Void,
            onCapture: @escaping (ObjectScanCapture?, String?) -> Void
        ) {
            self.isScanning = isScanning
            self.resetToken = resetToken
            self.selectionSettings = selectionSettings
            self.onStatus = onStatus
            self.onCapture = onCapture
            fusion = LiDARVoxelFusionEngine(configuration: configuration)
            stabilizer = LiDARMeasurementStabilizer(configuration: configuration)
            awaitingSelectionLock = isScanning
        }

        func update(
            isScanning newValue: Bool,
            resetToken newResetToken: Int,
            selectionSettings newSettings: ObjectScanSelectionSettings
        ) {
            fusionQueue.async { [weak self] in
                guard let self else { return }
                selectionSettings = newSettings
                if newResetToken != resetToken {
                    resetToken = newResetToken
                    isScanning = newValue
                    reset()
                    return
                }
                guard newValue != isScanning else { return }
                isScanning = newValue
                if newValue {
                    reset()
                } else {
                    finishCapture()
                }
            }
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let trackingIsNormal: Bool
            switch frame.camera.trackingState {
            case .normal: trackingIsNormal = true
            default: trackingIsNormal = false
            }
            currentStatus.trackingIsNormal = trackingIsNormal

            guard isScanning else {
                currentStatus.message = trackingIsNormal
                    ? "Adjust the box tightly, then lock the selection."
                    : trackingMessage(frame.camera.trackingState)
                publishStatus()
                return
            }
            guard trackingIsNormal else {
                currentStatus.message = trackingMessage(frame.camera.trackingState)
                publishStatus()
                return
            }
            guard frame.timestamp - lastProcessedTime >= 0.08 else { return }
            lastProcessedTime = frame.timestamp

            autoreleasepool {
                if awaitingSelectionLock {
                    guard let seed = extractSeed(from: frame) else {
                        currentStatus.message = "Aim the centre marker at the object, then hold still."
                        publishStatus()
                        return
                    }
                    // Highest detected horizontal plane below the aim point:
                    // the volume stretches down to it so the support surface
                    // is always inside the scan region.
                    let floorY = frame.anchors
                        .compactMap { $0 as? ARPlaneAnchor }
                        .filter { $0.alignment == .horizontal }
                        .map { $0.transform.columns.3.y }
                        .filter { $0 < seed.y - 0.02 }
                        .max()
                    let camera = frame.camera.transform
                    let volume = LockedVolumePlanning.volume(
                        seed: seed,
                        cameraRight: SIMD3<Float>(
                            camera.columns.0.x, camera.columns.0.y, camera.columns.0.z
                        ),
                        cameraForward: -SIMD3<Float>(
                            camera.columns.2.x, camera.columns.2.y, camera.columns.2.z
                        ),
                        floorY: floorY,
                        width: selectionSettings.volumeWidth,
                        height: selectionSettings.volumeHeight,
                        depth: selectionSettings.volumeDepth
                    )
                    fusion.lockSelection(volume: volume, seed: seed)
                    awaitingSelectionLock = false
                    currentStatus.selectionIsLocked = true
                    currentStatus.message = "Selection locked. Move slowly around the object."
                    showLockedVolume(volume)
                    publishStatus()
                    return
                }

                guard let points = extractSelectedDepthPoints(from: frame), !points.isEmpty else {
                    currentStatus.message = "No medium/high-confidence depth inside the scan box."
                    publishStatus()
                    return
                }

                guard isScanning else { return }
                let result = fusion.integrate(framePoints: points)
                currentStatus.integratedFrameCount += 1
                currentStatus.rejectedPointCount += result.rejectedOutsideVolumeCount
                if result.rejectedOutsideVolumeCount > 0 {
                    currentStatus.message =
                        "\(result.rejectedOutsideVolumeCount) outside-volume samples rejected this frame."
                } else {
                    currentStatus.message =
                        "Fusing selected object… capture the front, sides, top, and back."
                }
                // After the generic message so convergence guidance, boundary
                // warnings, and freeze explanations win the label.
                updateEstimate()
                publishStatus()
            }
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            DispatchQueue.main.async {
                self.onCapture(nil, "LiDAR tracking failed: \(error.localizedDescription)")
            }
        }

        /// Runs on the fusion queue; RealityKit entities are touched on main.
        private func reset() {
            fusion.reset()
            stabilizer.reset()
            stableMeasurement = nil
            DispatchQueue.main.async { [weak self] in
                self?.selectionAnchorEntity?.removeFromParent()
                self?.selectionAnchorEntity = nil
            }
            awaitingSelectionLock = isScanning
            currentStatus = ObjectScanLiveStatus(
                message: isScanning
                    ? "Hold still while the selected object volume is locked."
                    : "Adjust the box tightly, then lock the selection."
            )
            publishStatus()
        }

        private func updateEstimate() {
            // Segmentation is the expensive part of the pipeline and shares
            // the AR delegate queue; back off as the cloud grows so frames
            // keep draining.
            let cadence = currentStatus.pointCount > 40_000 ? 12 : 4
            guard currentStatus.integratedFrameCount.isMultiple(of: cadence) else { return }

            let measurement: LiDARFusionMeasurement
            switch fusion.evaluateMeasurement() {
            case .failed(let failure):
                // A failing pass must never leave a stale "Finish" enabled,
                // and the user deserves to know WHY it is not converging.
                currentStatus.measurementIsStable = false
                currentStatus.canFinish = false
                currentStatus.message = failure.guidance
                return
            case .measured(let value):
                measurement = value
            }

            switch stabilizer.consider(measurement.dimensionsCM) {
            case .warmingUp:
                currentStatus.measurementIsStable = false
                currentStatus.message = "Verifying measurement stability…"
            case .accepted(let dimensions):
                stableMeasurement = measurement
                currentStatus.dimensionsCM = dimensions
                currentStatus.measurementIsStable = true
            case .frozen(let dimensions, let message):
                currentStatus.dimensionsCM = dimensions
                currentStatus.measurementIsStable = false
                currentStatus.message = message
            }

            if measurement.touchesRegionBoundary {
                currentStatus.message =
                    "The object reaches the edge of the scan box — step back or enlarge the box."
            }

            currentStatus.pointCount = measurement.fusedVoxelCount
            currentStatus.confidence = confidence(
                measurement: measurement,
                frameCount: currentStatus.integratedFrameCount
            )
            currentStatus.canFinish =
                currentStatus.selectionIsLocked
                && currentStatus.measurementIsStable
                && currentStatus.integratedFrameCount >= configuration.minimumFusedFrameCount
                && currentStatus.pointCount >= configuration.minimumStableVoxelCount
                && currentStatus.confidence >= ObjectScanValidation.minimumConfidence
        }

        private func finishCapture() {
            guard currentStatus.canFinish,
                  let measurement = stableMeasurement,
                  let stableDimensions = stabilizer.stable
            else {
                DispatchQueue.main.async {
                    self.onCapture(
                        nil,
                        "Coverage or stability is incomplete. Continue until Finish Scan is enabled."
                    )
                }
                return
            }
            let confidence = confidence(
                measurement: measurement,
                frameCount: currentStatus.integratedFrameCount
            )
            if let validation = ObjectScanValidation.message(
                dimensions: stableDimensions,
                confidence: confidence,
                pointCount: measurement.fusedVoxelCount
            ) {
                DispatchQueue.main.async { self.onCapture(nil, validation) }
                return
            }

            let capture = ObjectScanCapture(
                id: UUID(),
                rawDimensionsCM: stableDimensions,
                pointsInMetres: measurement.centredPointsInMetres,
                scanMethod: .lidar,
                deviceModel: ObjectScannerCapabilities.deviceModelIdentifier,
                hasLiDAR: true,
                confidence: confidence,
                timestamp: .now
            )
            DispatchQueue.main.async { self.onCapture(capture, nil) }
        }

        private func confidence(
            measurement: LiDARFusionMeasurement,
            frameCount: Int
        ) -> Double {
            let frameScore = min(
                Double(frameCount) / Double(configuration.minimumFusedFrameCount * 2),
                1
            )
            let voxelScore = min(
                Double(measurement.fusedVoxelCount)
                    / Double(configuration.minimumStableVoxelCount * 6),
                1
            )
            let observationScore = min(measurement.averageObservationsPerVoxel / 8, 1)
            let stabilityScore = currentStatus.measurementIsStable ? 1.0 : 0.25
            var score = frameScore * 0.25
                + voxelScore * 0.25
                + observationScore * 0.20
                + stabilityScore * 0.30
            // Degraded-path penalties: height measured without a real support
            // plane, connectivity that needed the bridging radius, and clouds
            // pressing against the crop boundary are all less trustworthy.
            if measurement.usedSupportPlaneFallback { score -= 0.15 }
            if measurement.usedWideConnectivity { score -= 0.05 }
            if measurement.touchesRegionBoundary { score -= 0.10 }
            return min(max(score, 0), 0.95)
        }

        private var lastPublishedStatus: ObjectScanLiveStatus?
        private var lastPublishUptime: UInt64 = 0

        private func publishStatus() {
            // SwiftUI re-renders per publish; ~12 Hz of identical statuses
            // just contends with frame processing. Publish immediately on
            // meaningful transitions, at ~6 Hz otherwise.
            let now = DispatchTime.now().uptimeNanoseconds
            let significant = currentStatus.canFinish != lastPublishedStatus?.canFinish
                || currentStatus.selectionIsLocked != lastPublishedStatus?.selectionIsLocked
                || currentStatus.dimensionsCM != lastPublishedStatus?.dimensionsCM
            guard significant
                || lastPublishedStatus == nil
                || now - lastPublishUptime >= 160_000_000 else { return }
            lastPublishUptime = now
            lastPublishedStatus = currentStatus
            let status = currentStatus
            DispatchQueue.main.async { self.onStatus(status) }
        }

        private func trackingMessage(_ state: ARCamera.TrackingState) -> String {
            switch state {
            case .notAvailable:
                "AR tracking is unavailable. Check camera access."
            case .limited(let reason):
                switch reason {
                case .excessiveMotion: "Move the iPhone more slowly."
                case .insufficientFeatures: "Aim at a textured mat around the object."
                case .initializing: "LiDAR tracking is initializing…"
                case .relocalizing: "LiDAR tracking is recovering…"
                @unknown default: "AR tracking is limited."
                }
            case .normal:
                "Ready to lock the selected object."
            }
        }

        private func extractSeed(from frame: ARFrame) -> SIMD3<Float>? {
            guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
            let depthMap = depthData.depthMap
            let confidenceMap = depthData.confidenceMap
            return withLockedDepthMaps(depthMap: depthMap, confidenceMap: confidenceMap) {
                depths, depthStride, confidence, confidenceStride, width, height in
                var centreDepths: [Float] = []
                let centreX = width / 2
                let centreY = height / 2
                for y in (centreY - 3)...(centreY + 3) {
                    for x in (centreX - 3)...(centreX + 3) {
                        let depth = depths[y * depthStride + x]
                        guard depth.isFinite, depth >= 0.15, depth <= 1.20 else { continue }
                        if let confidence,
                           confidence[y * confidenceStride + x]
                            < ARConfidenceLevel.medium.rawValue {
                            continue
                        }
                        centreDepths.append(depth)
                    }
                }
                guard !centreDepths.isEmpty else { return nil }
                centreDepths.sort()
                let depth = centreDepths[centreDepths.count / 2]
                return self.worldPoint(
                    x: centreX,
                    y: centreY,
                    depth: depth,
                    depthWidth: width,
                    depthHeight: height,
                    frame: frame
                )
            }
        }

        private func extractSelectedDepthPoints(from frame: ARFrame) -> [SIMD3<Float>]? {
            guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
            let depthMap = depthData.depthMap
            let confidenceMap = depthData.confidenceMap
            return withLockedDepthMaps(depthMap: depthMap, confidenceMap: confidenceMap) {
                depths, depthStride, confidence, confidenceStride, width, height in
                let crop = DepthCropping.cropRect(
                    screenWidthFraction: self.selectionSettings.screenWidthFraction,
                    screenHeightFraction: self.selectionSettings.screenHeightFraction,
                    depthWidth: width,
                    depthHeight: height
                )

                var points: [SIMD3<Float>] = []
                points.reserveCapacity(2_000)
                for y in stride(from: crop.minY, to: crop.maxY, by: 2) {
                    for x in stride(from: crop.minX, to: crop.maxX, by: 2) {
                        let depth = depths[y * depthStride + x]
                        guard depth.isFinite, depth >= 0.15, depth <= 1.20 else { continue }
                        if let confidence,
                           confidence[y * confidenceStride + x]
                            < ARConfidenceLevel.medium.rawValue {
                            continue
                        }
                        points.append(
                            self.worldPoint(
                                x: x,
                                y: y,
                                depth: depth,
                                depthWidth: width,
                                depthHeight: height,
                                frame: frame
                            )
                        )
                    }
                }
                return points
            }
        }

        private func withLockedDepthMaps<Result>(
            depthMap: CVPixelBuffer,
            confidenceMap: CVPixelBuffer?,
            body: (
                UnsafePointer<Float32>,
                Int,
                UnsafePointer<UInt8>?,
                Int,
                Int,
                Int
            ) -> Result?
        ) -> Result? {
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
            let depthStride =
                CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
            let confidenceBase = confidenceMap.flatMap(CVPixelBufferGetBaseAddress)?
                .assumingMemoryBound(to: UInt8.self)
            let confidenceStride = confidenceMap.map(CVPixelBufferGetBytesPerRow) ?? 0
            return body(
                depthBase.assumingMemoryBound(to: Float32.self),
                depthStride,
                confidenceBase,
                confidenceStride,
                width,
                height
            )
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
            return SIMD3<Float>(world.x, world.y, world.z)
        }

        private func showLockedVolume(_ volume: LiDARScanVolume) {
            DispatchQueue.main.async {
                guard let arView = self.arView else { return }
                self.selectionAnchorEntity?.removeFromParent()
                let anchor = AnchorEntity(world: volume.transform)
                // Green to match the on-screen guide's locked state and docs.
                var material = UnlitMaterial(color: UIColor.green.withAlphaComponent(0.12))
                material.blending = .transparent(opacity: 0.12)
                let size = volume.halfExtents * 2
                let box = ModelEntity(
                    mesh: .generateBox(size: size),
                    materials: [material]
                )
                anchor.addChild(box)
                arView.scene.addAnchor(anchor)
                self.selectionAnchorEntity = anchor
            }
        }
    }
}
