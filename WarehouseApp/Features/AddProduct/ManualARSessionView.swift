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
            detectedProductRevision: state.detectedProductRevision,
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
        /// Scan results change several times a second; the markers, boundary
        /// and scan region around them do not. Each has its own node so a new
        /// result does not rebuild the rest.
        private let detectedProductNode = SCNNode()
        private var renderedDetectedProductRevision = -1
        private var dimensionLabelGeometry: [String: SCNText] = [:]
        /// Read and written on the main queue only.
        private var cornerPatchIsNeeded = true
        private var markerAnchors: [ARAnchor] = []
        private var renderedMarkerPositions: [SIMD3<Float>] = []
        private var lastPreviewUpdate: TimeInterval = 0
        private var handledPlacementRequestID = 0
        private var renderedRevision = -1
        private var handledProductScanStartRequestID = 0
        private var handledProductScanStopRequestID = 0
        private let fusionConfiguration = LiDARFusionConfiguration.smallObject
        /// Confined to `fusionQueue`.
        private let measurementSession = LiDARMeasurementSession(configuration: .smallObject)
        private struct ScanState {
            var isActive = false
            /// Incremented for every started scan so work queued by an
            /// earlier scan can never publish into a later one.
            var generation = 0
        }
        // Read on the ARKit delegate thread and the fusion queue, written on
        // the main actor — must be lock-protected.
        private let scanState = OSAllocatedUnfairLock(initialState: ScanState())
        /// Incremented whenever the session's world coordinate system may
        /// have changed. Delegate callbacks arrive on the main queue.
        private var coordinateEpoch = 0
        // Corner recognition: rolling reticle patch + current lock (main actor).
        private var cornerLockWindow = ObjectCornerLockWindow()
        private var lockedCorner: ObjectCornerLockWindow.Lock?
        private var lastCornerRecognitionAt: TimeInterval = 0
        private var previewIsLockedOnCorner = false
        private let fusionQueue = DispatchQueue(
            label: "com.tetris.warehouse.manual-region-fusion",
            qos: .userInitiated
        )
        /// Validation recording of the scan in progress. Fusion queue only.
        private var recorder: LiDARScanRecorder?

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
            view.scene.rootNode.addChildNode(detectedProductNode)
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
            // Closing the recording must not depend on the view still existing.
            scanState.withLock { $0.isActive = false }
            let shown = shownResult()
            fusionQueue.sync { finishRecording(shown: shown) }
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
            detectedProductRevision: Int,
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
                    self.state.place(self.placementSample())
                }
            }
            if renderRevision != renderedRevision {
                renderedRevision = renderRevision
                renderedDetectedProductRevision = detectedProductRevision
                rebuildPermanentGeometry()
                rebuildDetectedProduct()
            } else if detectedProductRevision != renderedDetectedProductRevision {
                renderedDetectedProductRevision = detectedProductRevision
                rebuildDetectedProduct()
            }
            if productScanStopRequestID != handledProductScanStopRequestID {
                handledProductScanStopRequestID = productScanStopRequestID
                scanState.withLock { $0.isActive = false }
                let shown = shownResult()
                fusionQueue.async { [weak self] in self?.finishRecording(shown: shown) }
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
            guard now - lastPreviewUpdate >= fusionConfiguration.frameIntervalSeconds else {
                return
            }
            lastPreviewUpdate = now
            let trackingState = frame.camera.trackingState
            let scan = scanState.withLock { $0 }
            // Frames with degraded tracking are still handed to the pipeline,
            // without points, so it can reject them and decide whether the
            // evidence gathered so far is still valid.
            let depthFrame = scan.isActive ? makeDepthFrame(from: frame) : nil
            // Corners are only recognised while boundary markers are placed.
            let cornerPatch = cornerPatchIsNeeded ? extractCornerPatch(from: frame) : nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                cornerPatchIsNeeded = state.stage == .boundary
                state.updateTracking(trackingState)
                let sample = raycastAtCentre()
                state.updatePreview(sample)
                updateCornerLock(sample: sample, patch: cornerPatch, timestamp: now)
                updatePreview(sample)
            }
            guard let depthFrame else { return }
            fusionQueue.async { [weak self] in
                self?.integrateProductFrame(depthFrame, generation: scan.generation)
            }
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            Task { @MainActor [weak self] in
                self?.state.errorMessage = "AR session failed: \(error.localizedDescription) Restart measurement or enter dimensions manually."
            }
        }

        func sessionWasInterrupted(_ session: ARSession) {
            // The camera stopped; ARKit may resume with a different world
            // origin, so everything fused so far is in a stale frame.
            coordinateEpoch += 1
            // Delegate callbacks arrive on the main queue. Revoke the scan
            // here, not in a later task, so Finish cannot be pressed on
            // evidence from before the interruption.
            scanState.withLock { $0.isActive = false }
            MainActor.assumeIsolated {
                if state.productScanIsActive {
                    state.handleTrackingReset()
                } else {
                    state.errorMessage = "Measurement was interrupted. Verify that every marker is still aligned before continuing."
                }
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
            coordinateEpoch += 1
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
            scanState.withLock { $0.isActive = false }
            let recordingHeader = makeRecordingHeader(region: .polygonalPrism(region), seed: seed)
            fusionQueue.sync {
                finishRecording(shown: nil)
                measurementSession.begin(region: .polygonalPrism(region), seed: seed)
                recorder = recordingHeader.flatMap {
                    startRecording(header: $0, region: .polygonalPrism(region))
                }
            }
            scanState.withLock {
                $0.generation += 1
                $0.isActive = true
            }
        }

        private func integrateProductFrame(_ frame: LiDARDepthFrame, generation: Int) {
            guard scanState.withLock({ $0.isActive && $0.generation == generation }) else {
                return
            }
            record(frame)
            let report = measurementSession.process(frame)
            if report.frame?.evidenceWasInvalidated == true {
                // The pipeline found the coordinate system unreliable
                // (relocalization, prolonged limited tracking, a pose jump).
                scanState.withLock {
                    if $0.generation == generation { $0.isActive = false }
                }
                DispatchQueue.main.async { [weak self] in
                    self?.state.handleTrackingReset()
                }
                return
            }
            let status = ManualProductScanStatus(report: report)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.scanState.withLock({ $0.isActive && $0.generation == generation })
                else { return }
                self.state.updateProductScan(status)
            }
        }

        // MARK: Validation recording

        /// Nil unless recording was switched on (debug builds only).
        @MainActor
        private func makeRecordingHeader(
            region: LiDARSpatialRegion,
            seed: SIMD3<Float>
        ) -> LiDARScanRecording.Header? {
            #if DEBUG
            let defaults = UserDefaults.standard
            guard defaults.bool(forKey: LiDARScanRecordingSettings.enabledKey) else { return nil }
            var systemInfo = utsname()
            uname(&systemInfo)
            let machine = withUnsafeBytes(of: &systemInfo.machine) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            return LiDARScanRecording.Header(
                label: defaults.string(forKey: LiDARScanRecordingSettings.productKey) ?? "",
                step: defaults.string(forKey: LiDARScanRecordingSettings.stepKey) ?? "",
                createdAt: ISO8601DateFormatter().string(from: Date()),
                deviceModel: machine,
                systemVersion: UIDevice.current.systemVersion,
                region: LiDARScanRecording.Region(region),
                seed: [seed.x, seed.y, seed.z]
            )
            #else
            return nil
            #endif
        }

        /// Fusion queue.
        private func startRecording(
            header: LiDARScanRecording.Header,
            region: LiDARSpatialRegion
        ) -> LiDARScanRecorder? {
            let directory = LiDARScanRecordingSettings.directory
            let date = Date()
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                // A second scan within the same second gets its own name.
                var attempt = 0
                var url: URL
                repeat {
                    url = directory.appendingPathComponent(LiDARScanRecordingSettings.fileName(
                        product: header.label,
                        step: header.step,
                        date: date,
                        attempt: attempt
                    ))
                    attempt += 1
                } while FileManager.default.fileExists(atPath: url.path) && attempt < 100
                return try LiDARScanRecorder(
                    url: url,
                    header: header,
                    region: region,
                    margin: fusionConfiguration.cropMargin + 2 * fusionConfiguration.voxelSize
                )
            } catch {
                noteRecording("Scan recording could not be started: \(error.localizedDescription)")
                return nil
            }
        }

        /// Fusion queue.
        private func record(_ frame: LiDARDepthFrame) {
            guard let recorder else { return }
            guard !recorder.didFail,
                  recorder.frameCount < LiDARScanRecordingSettings.maximumFrameCount
            else {
                if recorder.didFail {
                    finishRecording(shown: nil)
                    return
                }
                recorder.finish(result: nil)
                try? FileManager.default.removeItem(at: recorder.url)
                self.recorder = nil
                noteRecording("Scan recording was dropped: the scan ran longer than five minutes.")
                return
            }
            recorder.append(frame)
        }

        /// What the screen shows now, to store beside the pipeline's report.
        @MainActor
        private func shownResult() -> (dimensions: ObjectDimensions?, status: String) {
            (
                state.productScanStatus.detectedDimensionsCM,
                state.productScanStatus.decision.status.rawValue
            )
        }

        /// Fusion queue. Closes the recording with the app's own result.
        private func finishRecording(shown: (dimensions: ObjectDimensions?, status: String)?) {
            guard let recorder else { return }
            self.recorder = nil
            let report = measurementSession.report
            let isComplete = recorder.finish(result: LiDARScanRecording.LiveResult(
                reportedDimensionsCM: report.reportedDimensionsCM,
                decision: report.decision,
                evidence: report.evidence,
                shownDimensionsCM: shown?.dimensions,
                shownStatus: shown?.status
            ))
            guard isComplete else {
                // An incomplete file would be replayed as a shorter scan.
                try? FileManager.default.removeItem(at: recorder.url)
                noteRecording("Scan recording failed and was deleted. Check free storage.")
                return
            }
            noteRecording("Saved \(recorder.url.lastPathComponent) (\(recorder.frameCount) frames)")
        }

        private func noteRecording(_ message: String) {
            DispatchQueue.main.async { [weak self] in
                self?.state.noteRecording(message)
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

        private struct CornerPatch {
            let points: [SIMD3<Float>]
            let cameraWorld: SIMD3<Float>
            let depthConfidence: Double
        }

        /// Depth points in a small patch around the screen centre, used to
        /// recognise an object corner near the reticle. Nil without LiDAR.
        private func extractCornerPatch(from frame: ARFrame) -> CornerPatch? {
            guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else {
                return nil
            }
            let depthMap = depthData.depthMap
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
            let width = CVPixelBufferGetWidth(depthMap)
            let height = CVPixelBufferGetHeight(depthMap)
            let rowStride = CVPixelBufferGetBytesPerRow(depthMap)
                / MemoryLayout<Float32>.size
            let depths = base.assumingMemoryBound(to: Float32.self)
            let centreX = width / 2
            let centreY = height / 2
            var points: [SIMD3<Float>] = []
            points.reserveCapacity(240)
            let projection = ARDepthProjection(frame: frame, depthWidth: width, depthHeight: height)
            for y in stride(from: centreY - 14, through: centreY + 14, by: 2) {
                for x in stride(from: centreX - 14, through: centreX + 14, by: 2) {
                    guard x >= 0, x < width, y >= 0, y < height else { continue }
                    let depth = depths[y * rowStride + x]
                    guard depth.isFinite, depth >= 0.10, depth <= 3 else { continue }
                    points.append(projection.worldPoint(x: x, y: y, depth: depth))
                }
            }
            guard !points.isEmpty else { return nil }
            let camera = frame.camera.transform.columns.3
            return CornerPatch(
                points: points,
                cameraWorld: SIMD3<Float>(camera.x, camera.y, camera.z),
                depthConfidence: frame.smoothedSceneDepth == nil ? 0.85 : 0.95
            )
        }

        @MainActor
        private func updateCornerLock(
            sample: CentreRaycastSample?,
            patch: CornerPatch?,
            timestamp: TimeInterval
        ) {
            guard state.stage == .boundary, let sample, let patch else {
                if lockedCorner != nil || state.stage != .boundary {
                    cornerLockWindow.reset()
                    lockedCorner = nil
                }
                return
            }
            cornerLockWindow.integrate(
                reticleWorld: sample.position,
                patchWorldPoints: patch.points,
                cameraWorld: patch.cameraWorld,
                timestamp: timestamp,
                depthConfidence: patch.depthConfidence
            )
            guard timestamp - lastCornerRecognitionAt >= 0.3 else { return }
            lastCornerRecognitionAt = timestamp
            // Recognition runs on the fusion queue (the window is a value
            // copy) so estimator cost never blocks the main thread.
            let window = cornerLockWindow
            let reticleWorld = sample.position
            fusionQueue.async { [weak self] in
                let lock = window.recognisedCorner(
                    reticleWorld: reticleWorld,
                    at: timestamp
                )
                DispatchQueue.main.async { self?.lockedCorner = lock }
            }
        }

        /// The sample used for Place: the recognised corner when one is
        /// locked, otherwise the raw centre raycast.
        @MainActor
        private func placementSample() -> CentreRaycastSample? {
            let raw = raycastAtCentre()
            guard state.stage == .boundary, let lockedCorner, let raw else {
                return raw
            }
            cornerLockWindow.reset()
            self.lockedCorner = nil
            return CentreRaycastSample(
                position: lockedCorner.worldPosition,
                raycastType: "recognisedCorner",
                surfaceAlignment: raw.surfaceAlignment,
                confidence: max(
                    raw.confidence,
                    min(1, 1 - lockedCorner.uncertaintyMetres / 0.05)
                ),
                cameraDistanceMetres: raw.cameraDistanceMetres
            )
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

        private func makeDepthFrame(from frame: ARFrame) -> LiDARDepthFrame {
            let camera = frame.camera.transform.columns.3
            var depthFrame = LiDARDepthFrame(
                points: [],
                timestamp: frame.timestamp,
                tracking: trackingQuality(frame.camera.trackingState),
                coordinateEpoch: coordinateEpoch,
                cameraPosition: SIMD3<Float>(camera.x, camera.y, camera.z)
            )
            guard depthFrame.tracking == .normal else { return depthFrame }
            if let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth {
                depthFrame.source = .sceneDepth
                extractDepthPoints(depthData, frame: frame, into: &depthFrame)
            } else {
                // Non-LiDAR fallback: feature points remain spatially filtered
                // by the same polygonal prism before entering fusion.
                depthFrame.source = .featurePoints
                depthFrame.points = frame.rawFeaturePoints.map { Array($0.points) } ?? []
            }
            return depthFrame
        }

        private func extractDepthPoints(
            _ depthData: ARDepthData,
            frame: ARFrame,
            into depthFrame: inout LiDARDepthFrame
        ) {
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
            guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return }
            let width = CVPixelBufferGetWidth(depthMap)
            let height = CVPixelBufferGetHeight(depthMap)
            let depthStride = CVPixelBufferGetBytesPerRow(depthMap)
                / MemoryLayout<Float32>.size
            let depths = depthBase.assumingMemoryBound(to: Float32.self)
            let confidence = confidenceMap
                .flatMap(CVPixelBufferGetBaseAddress)?
                .assumingMemoryBound(to: UInt8.self)
            let confidenceStride = confidenceMap.map(CVPixelBufferGetBytesPerRow) ?? 0
            let pixelStride = max(1, fusionConfiguration.depthPixelStride)
            var points: [SIMD3<Float>] = []
            points.reserveCapacity(width * height / (pixelStride * pixelStride))
            let projection = ARDepthProjection(frame: frame, depthWidth: width, depthHeight: height)
            for y in stride(from: 0, to: height, by: pixelStride) {
                for x in stride(from: 0, to: width, by: pixelStride) {
                    let depth = depths[y * depthStride + x]
                    depthFrame.examinedSampleCount += 1
                    switch LiDARDepthSampleFilter.classify(
                        depth: depth,
                        confidenceLevel: confidence.map { Int($0[y * confidenceStride + x]) },
                        configuration: fusionConfiguration
                    ) {
                    case .outOfRange:
                        depthFrame.outOfRangeSampleCount += 1
                        continue
                    case .lowConfidence:
                        depthFrame.lowConfidenceSampleCount += 1
                        continue
                    case .accepted(let isHighConfidence):
                        if isHighConfidence { depthFrame.highConfidenceSampleCount += 1 }
                    }
                    points.append(projection.worldPoint(x: x, y: y, depth: depth))
                }
            }
            depthFrame.points = points
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
                    guard depth.isFinite,
                          depth >= fusionConfiguration.minimumDepthMetres,
                          depth <= fusionConfiguration.maximumDepthMetres,
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
            // Snap onto a recognised corner; fall back to the raw raycast.
            previewNode.simdWorldPosition = lockedCorner?.worldPosition ?? sample.position
            setPreviewLocked(lockedCorner != nil)
            previewNode.isHidden = false
        }

        @MainActor
        private func setPreviewLocked(_ isLocked: Bool) {
            guard isLocked != previewIsLockedOnCorner else { return }
            previewIsLockedOnCorner = isLocked
            previewNode.geometry?.firstMaterial = material(
                color: isLocked
                    ? UIColor.systemGreen.withAlphaComponent(0.9)
                    : UIColor.systemYellow.withAlphaComponent(0.65)
            )
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
        }

        @MainActor
        private func rebuildDetectedProduct() {
            detectedProductNode.childNodes.forEach { $0.removeFromParentNode() }
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
            color: UIColor,
            in parent: SCNNode? = nil
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
            (parent ?? measurementGeometryNode).addChildNode(line)
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
                detectedProductNode.addChildNode(SCNNode(geometry: geometry))
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
                    color: .systemOrange,
                    in: detectedProductNode
                )
            }
            if let dimensions = status.detectedDimensionsCM {
                let firstHorizontalIsLength =
                    simd_distance(corners[0], corners[1])
                    >= simd_distance(corners[1], corners[2])
                addDimensionLabel(
                    "\(firstHorizontalIsLength ? "Length" : "Width"): \((firstHorizontalIsLength ? dimensions.length : dimensions.width).formatted(.number.precision(.fractionLength(1)))) cm",
                    at: (corners[0] + corners[1]) / 2
                )
                addDimensionLabel(
                    "\(firstHorizontalIsLength ? "Width" : "Length"): \((firstHorizontalIsLength ? dimensions.width : dimensions.length).formatted(.number.precision(.fractionLength(1)))) cm",
                    at: (corners[1] + corners[2]) / 2
                )
                addDimensionLabel(
                    "Height: \(dimensions.height.formatted(.number.precision(.fractionLength(1)))) cm",
                    at: (corners[0] + corners[4]) / 2
                )
            }
        }

        @MainActor
        private func addDimensionLabel(_ text: String, at position: SIMD3<Float>) {
            // Text is tessellated when created; a reading shown to one decimal
            // place repeats across most updates, so its geometry is kept.
            let textGeometry: SCNText
            if let cached = dimensionLabelGeometry[text] {
                textGeometry = cached
            } else {
                textGeometry = SCNText(string: text, extrusionDepth: 0)
                textGeometry.font = .systemFont(ofSize: 8, weight: .semibold)
                textGeometry.flatness = 0.2
                textGeometry.firstMaterial = material(color: .white)
                if dimensionLabelGeometry.count >= 24 { dimensionLabelGeometry.removeAll() }
                dimensionLabelGeometry[text] = textGeometry
            }
            let node = SCNNode(geometry: textGeometry)
            node.scale = SCNVector3(0.002, 0.002, 0.002)
            node.simdPosition = position + SIMD3<Float>(0, 0.015, 0)
            node.constraints = [SCNBillboardConstraint()]
            detectedProductNode.addChildNode(node)
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
