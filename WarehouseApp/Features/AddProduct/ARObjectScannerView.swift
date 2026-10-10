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
        // The session is configured here; RealityKit must not reconfigure it.
        view.automaticallyConfigureSession = false
        // Only the unlit selection box is drawn over the camera image.
        view.renderOptions = [
            .disableMotionBlur, .disableDepthOfField, .disableHDR, .disableCameraGrain,
            .disableGroundingShadows, .disableAREnvironmentLighting,
            .disablePersonOcclusion, .disableFaceMesh
        ]
        // The measurement reads depth maps only. Mesh reconstruction and
        // plane detection are never consulted, so they are left off.
        let configuration = ARWorldTrackingConfiguration()
        configuration.environmentTexturing = .none
        configuration.frameSemantics.insert(.smoothedSceneDepth)
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

        /// The shared pipeline defaults, with the depth range narrowed to
        /// the arm's-length distance this capture mode is used at.
        private let configuration: LiDARFusionConfiguration = {
            var configuration = LiDARFusionConfiguration.smallObject
            configuration.minimumDepthMetres = 0.15
            configuration.maximumDepthMetres = 1.20
            return configuration
        }()
        private let onStatus: (ObjectScanLiveStatus) -> Void
        private let onCapture: (ObjectScanCapture?, String?) -> Void
        private var isScanning: Bool
        private var resetToken: Int
        private var selectionSettings: ObjectScanSelectionSettings
        private let measurementSession: LiDARMeasurementSession
        private var latestReport = LiDARMeasurementReport()
        /// Incremented when the session's world coordinate system may have
        /// changed, so the pipeline discards evidence from the old one.
        private var coordinateEpoch = 0
        private var currentStatus = ObjectScanLiveStatus()
        private var publishedStatus: ObjectScanLiveStatus?
        private var lastProcessedTime: TimeInterval = 0
        private var awaitingSelectionLock = false
        private var selectionAnchorEntity: AnchorEntity?
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
            measurementSession = LiDARMeasurementSession(configuration: configuration)
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
            guard frame.timestamp - lastProcessedTime >= configuration.frameIntervalSeconds else {
                return
            }
            lastProcessedTime = frame.timestamp
            let cameraColumn = frame.camera.transform.columns.3
            var depthFrame = LiDARDepthFrame(
                points: [],
                timestamp: frame.timestamp,
                tracking: trackingQuality(frame.camera.trackingState),
                coordinateEpoch: coordinateEpoch,
                cameraPosition: SIMD3<Float>(cameraColumn.x, cameraColumn.y, cameraColumn.z),
                source: .sceneDepth
            )
            guard trackingIsNormal else {
                // Let the pipeline see the degraded frame so it can decide
                // whether the evidence gathered so far is still valid.
                if !awaitingSelectionLock {
                    let report = measurementSession.process(depthFrame)
                    if report.frame?.evidenceWasInvalidated == true {
                        restartAfterTrackingReset()
                        return
                    }
                    apply(report)
                }
                currentStatus.message = trackingMessage(frame.camera.trackingState)
                publishStatus()
                return
            }

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
                    measurementSession.begin(volume: volume, seed: seed)
                    awaitingSelectionLock = false
                    currentStatus.selectionIsLocked = true
                    currentStatus.message = "Selection locked. Move slowly around the object."
                    showLockedVolume(volume)
                    publishStatus()
                    return
                }

                guard isScanning else { return }
                // An empty frame is still processed: the pipeline must know
                // the object is no longer in view.
                extractSelectedDepthPoints(from: frame, into: &depthFrame)
                let report = measurementSession.process(depthFrame)
                if report.frame?.evidenceWasInvalidated == true {
                    restartAfterTrackingReset()
                    return
                }
                apply(report)
                if depthFrame.points.isEmpty {
                    currentStatus.message = "No medium/high-confidence depth inside the scan box."
                }
                publishStatus()
            }
        }

        /// Delivered on the fusion queue. The locked volume was placed in
        /// the old coordinate system, so the scan starts over and re-locks.
        func sessionWasInterrupted(_ session: ARSession) {
            coordinateEpoch += 1
            if isScanning { restartAfterTrackingReset() }
        }

        private func restartAfterTrackingReset() {
            reset()
            currentStatus.message =
                "Tracking was lost, so the scan restarted. Aim at the object to lock it again."
            publishStatus()
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            DispatchQueue.main.async {
                self.onCapture(nil, "LiDAR tracking failed: \(error.localizedDescription)")
            }
        }

        /// Runs on the fusion queue; RealityKit entities are touched on main.
        private func reset() {
            measurementSession.reset()
            latestReport = LiDARMeasurementReport()
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

        /// Copies the pipeline's report into the published status. Finishing
        /// is offered only when the acceptance stage did not refuse.
        private func apply(_ report: LiDARMeasurementReport) {
            latestReport = report
            let frames = report.evidence.frames
            currentStatus.integratedFrameCount = frames.acceptedFrameCountSinceReset
            currentStatus.rejectedPointCount = frames.outsideRegionSampleCount
            currentStatus.dimensionsCM = report.reportedDimensionsCM
            currentStatus.measurementIsStable = report.dimensionsAreStable
            currentStatus.pointCount = report.measurement?.fusedVoxelCount ?? 0
            currentStatus.confidence = report.coverageScore
            currentStatus.canFinish =
                currentStatus.selectionIsLocked
                && report.measurement != nil
                && report.decision.allowsFinish
                && report.coverageScore >= ObjectScanValidation.minimumConfidence
            switch report.decision.status {
            case .accepted:
                currentStatus.message = "All scan checks passed. You can finish."
            case .qualified:
                currentStatus.message = report.guidance.first
                    .map { "You can finish, with a caution: \($0)" }
                    ?? "You can finish, with cautions."
            case .refused:
                currentStatus.message = report.guidance.first
                    ?? "Fusing selected object… capture the front, sides, top, and back."
            }
        }

        private func finishCapture() {
            // Re-run the geometric stages on everything fused so far before
            // deciding; this runs on the fusion queue.
            if currentStatus.selectionIsLocked {
                apply(measurementSession.refresh())
            }
            let report = latestReport
            guard currentStatus.canFinish,
                  let measurement = report.measurement,
                  let dimensions = report.reportedDimensionsCM
            else {
                let reason = report.guidance.first
                    ?? "Coverage or stability is incomplete. Continue until Finish Scan is enabled."
                DispatchQueue.main.async { self.onCapture(nil, reason) }
                return
            }
            if let validation = ObjectScanValidation.message(
                dimensions: dimensions,
                confidence: report.coverageScore,
                pointCount: measurement.fusedVoxelCount
            ) {
                DispatchQueue.main.async { self.onCapture(nil, validation) }
                return
            }

            let capture = ObjectScanCapture(
                id: UUID(),
                rawDimensionsCM: dimensions,
                pointsInMetres: measurement.centredPointsInMetres,
                scanMethod: .lidar,
                deviceModel: ObjectScannerCapabilities.deviceModelIdentifier,
                hasLiDAR: true,
                confidence: report.coverageScore,
                timestamp: .now,
                measurementEvidence: report.evidence
            )
            DispatchQueue.main.async { self.onCapture(capture, nil) }
        }

        private func trackingQuality(
            _ state: ARCamera.TrackingState
        ) -> LiDARTrackingQuality {
            switch state {
            case .normal: .normal
            case .notAvailable: .notAvailable
            case .limited(.relocalizing): .relocalizing
            case .limited: .limited
            }
        }

        private var lastPublishedStatus: ObjectScanLiveStatus?
        private var lastPublishUptime: UInt64 = 0

        /// Called for every camera frame while idle; only a changed status
        /// is worth a main-queue hop and a SwiftUI update.
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
            guard status != publishedStatus else { return }
            publishedStatus = status
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
                return ARDepthProjection(frame: frame, depthWidth: width, depthHeight: height)
                    .worldPoint(x: centreX, y: centreY, depth: depth)
            }
        }

        /// Reads the screen selection through the shared per-sample filter,
        /// recording how many samples it examined and rejected.
        private func extractSelectedDepthPoints(
            from frame: ARFrame,
            into depthFrame: inout LiDARDepthFrame
        ) {
            guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
            let depthMap = depthData.depthMap
            let confidenceMap = depthData.confidenceMap
            let extracted: LiDARDepthFrame? = withLockedDepthMaps(
                depthMap: depthMap,
                confidenceMap: confidenceMap
            ) { depths, depthStride, confidence, confidenceStride, width, height in
                let crop = DepthCropping.cropRect(
                    screenWidthFraction: self.selectionSettings.screenWidthFraction,
                    screenHeightFraction: self.selectionSettings.screenHeightFraction,
                    depthWidth: width,
                    depthHeight: height
                )
                let pixelStride = max(1, self.configuration.depthPixelStride)
                let projection = ARDepthProjection(frame: frame, depthWidth: width, depthHeight: height)

                var result = LiDARDepthFrame(points: [], timestamp: frame.timestamp)
                result.points.reserveCapacity(2_000)
                for y in stride(from: crop.minY, to: crop.maxY, by: pixelStride) {
                    for x in stride(from: crop.minX, to: crop.maxX, by: pixelStride) {
                        let depth = depths[y * depthStride + x]
                        result.examinedSampleCount += 1
                        switch LiDARDepthSampleFilter.classify(
                            depth: depth,
                            confidenceLevel: confidence.map { Int($0[y * confidenceStride + x]) },
                            configuration: self.configuration
                        ) {
                        case .outOfRange:
                            result.outOfRangeSampleCount += 1
                            continue
                        case .lowConfidence:
                            result.lowConfidenceSampleCount += 1
                            continue
                        case .accepted(let isHighConfidence):
                            if isHighConfidence { result.highConfidenceSampleCount += 1 }
                        }
                        result.points.append(projection.worldPoint(x: x, y: y, depth: depth))
                    }
                }
                return result
            }
            guard let extracted else { return }
            depthFrame.points = extracted.points
            depthFrame.examinedSampleCount = extracted.examinedSampleCount
            depthFrame.outOfRangeSampleCount = extracted.outOfRangeSampleCount
            depthFrame.lowConfidenceSampleCount = extracted.lowConfidenceSampleCount
            depthFrame.highConfidenceSampleCount = extracted.highConfidenceSampleCount
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
