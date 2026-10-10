import ARKit
import RealityKit
import SwiftUI
import UIKit

struct StorageMarkerScannerView: UIViewRepresentable {
    @Binding var stage: StorageMarkerStage
    @Binding var draft: StorageMarkerDraft?
    @Binding var markerCount: Int
    @Binding var canPlace: Bool
    @Binding var guidance: String
    @Binding var errorMessage: String?

    let placementRequestID: Int
    let undoRequestID: Int
    let resetRequestID: Int
    let previewRequestID: Int
    let useCorrectedFootprint: Bool
    let previewHeightCM: Double?

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }
    static var hasLiDAR: Bool { ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// Plane detection and the LiDAR mesh are only consulted while a surface
    /// or wall is being picked. Review and height entry need nothing beyond
    /// world tracking, so they run without either. Depth maps and mesh
    /// classification are never read here and are not requested at all.
    static func configuration(measuring: Bool) -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        if measuring {
            configuration.planeDetection = [.horizontal, .vertical]
            if hasLiDAR { configuration.sceneReconstruction = .mesh }
        }
        return configuration
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        // The session is configured here; RealityKit must not reconfigure it.
        view.automaticallyConfigureSession = false
        // Only unlit markers and lines are drawn over the camera image.
        view.renderOptions = [
            .disableMotionBlur, .disableDepthOfField, .disableHDR, .disableCameraGrain,
            .disableGroundingShadows, .disableAREnvironmentLighting,
            .disablePersonOcclusion, .disableFaceMesh
        ]
        view.session.delegate = context.coordinator
        view.session.run(Self.configuration(measuring: true))
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

        let reticle = UIView()
        reticle.translatesAutoresizingMaskIntoConstraints = false
        reticle.isUserInteractionEnabled = false
        reticle.layer.cornerRadius = 14
        reticle.layer.borderWidth = 2
        reticle.layer.borderColor = UIColor.systemOrange.cgColor
        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = .white
        dot.layer.cornerRadius = 3
        reticle.addSubview(dot)
        view.addSubview(reticle)
        NSLayoutConstraint.activate([
            reticle.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            reticle.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            reticle.widthAnchor.constraint(equalToConstant: 28),
            reticle.heightAnchor.constraint(equalToConstant: 28),
            dot.centerXAnchor.constraint(equalTo: reticle.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: reticle.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6)
        ])
        context.coordinator.reticle = reticle
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.update(parent: self)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        private struct SurfaceBasis {
            var planeID: UUID
            var origin: SIMD3<Double>
            var widthAxis: SIMD3<Double>
            var depthAxis: SIMD3<Double>
            var verticalAxis: SIMD3<Double>
            var horizontalDeviationDegrees: Double
        }

        private struct BaseRaycastSample {
            var position: SIMD3<Double>
            var normal: SIMD3<Double>
            var plane: ARPlaneAnchor
            var horizontalDeviationDegrees: Double
            var timestamp: TimeInterval
        }

        private struct WallObservation {
            var hitPosition: SIMD3<Double>
            var normal: SIMD3<Double>
            var source: StorageBoundarySource
            var confidence: Double
        }

        private struct LocalMeshTriangle {
            var first: SIMD3<Double>
            var second: SIMD3<Double>
            var third: SIMD3<Double>
            var normal: SIMD3<Double>
            var centre: SIMD3<Double>
            var area: Double
        }

        private struct PreviewSignature: Equatable {
            var footprint: [Vector2D]
            var heightCM: Double?
        }

        weak var arView: ARView?
        weak var reticle: UIView?
        private var parent: StorageMarkerScannerView
        private var basis: SurfaceBasis?
        private var baseSamples: [BaseRaycastSample] = []
        private var baseCandidate: BaseRaycastSample?
        private var baseConfidence = 0.0
        private var boundaries: [StorageBoundary] = []
        private var markerAnchors: [AnchorEntity] = []
        private var basePlaneAnchor: AnchorEntity?
        private var previewAnchor: AnchorEntity?
        private var renderedPreviewSignature: PreviewSignature?
        private var handledPlacementRequestID: Int
        private var handledUndoRequestID: Int
        private var handledResetRequestID: Int
        private var handledPreviewRequestID: Int
        private var sessionIsMeasuring = true
        private var lastReticleUpdate: TimeInterval = 0
        private var reticleUpdateIsPending = false
        private var reticleIsReady = false

        init(parent: StorageMarkerScannerView) {
            self.parent = parent
            handledPlacementRequestID = parent.placementRequestID
            handledUndoRequestID = parent.undoRequestID
            handledResetRequestID = parent.resetRequestID
            handledPreviewRequestID = parent.previewRequestID
        }

        @MainActor
        func update(parent: StorageMarkerScannerView) {
            self.parent = parent
            let placementRequested = parent.placementRequestID != handledPlacementRequestID
            let undoRequested = parent.undoRequestID != handledUndoRequestID
            let resetRequested = parent.resetRequestID != handledResetRequestID
            handledPlacementRequestID = parent.placementRequestID
            handledUndoRequestID = parent.undoRequestID
            handledResetRequestID = parent.resetRequestID
            if placementRequested || undoRequested || resetRequested {
                // These write the stage, guidance and draft bindings. SwiftUI
                // drops or delays state written during a representable
                // update, so run them once this update has finished.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if placementRequested { self.performPlacement() }
                    if undoRequested { self.undo() }
                    if resetRequested { self.reset() }
                    self.updateSessionConfiguration()
                }
            }
            if parent.previewRequestID != handledPreviewRequestID {
                handledPreviewRequestID = parent.previewRequestID
                renderPreview(includeHeight: true)
            } else if parent.stage == .review {
                renderPreview(includeHeight: false)
            }
            updateSessionConfiguration()
        }

        /// Switches plane detection and mesh reconstruction off once all four
        /// walls are placed, and back on if the worker returns to placing.
        /// Running without reset options keeps the world origin and anchors.
        @MainActor
        private func updateSessionConfiguration() {
            let measuring = parent.stage == .selectSurface || parent.stage == .placeBoundaries
            guard measuring != sessionIsMeasuring, let arView else { return }
            sessionIsMeasuring = measuring
            arView.session.run(StorageMarkerScannerView.configuration(measuring: measuring))
        }

        /// Delivered on the main queue for every camera frame. The frame itself
        /// is never kept: it owns the camera buffers. Base-surface samples are
        /// averaged into the measurement, so that stage still takes every
        /// frame; the wall reticle is only a hint and needs far fewer.
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let timestamp = frame.timestamp
            let interval: TimeInterval
            switch parent.stage {
            case .selectSurface: interval = 0
            case .placeBoundaries: interval = 0.1
            case .review, .enterHeight, .preview, .complete: interval = 0.5
            }
            guard !reticleUpdateIsPending, timestamp - lastReticleUpdate >= interval else { return }
            lastReticleUpdate = timestamp
            reticleUpdateIsPending = true
            let trackingIsNormal: Bool
            if case .normal = frame.camera.trackingState {
                trackingIsNormal = true
            } else {
                trackingIsNormal = false
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reticleUpdateIsPending = false
                self.updateReticle(timestamp: timestamp, trackingIsNormal: trackingIsNormal)
            }
        }

        /// Writes a binding only when its value changes, so an unchanged
        /// reticle does not invalidate the Place screen.
        @MainActor
        private func setCanPlace(_ value: Bool) {
            if parent.canPlace != value { parent.canPlace = value }
        }

        @MainActor
        private func setGuidance(_ value: String) {
            if parent.guidance != value { parent.guidance = value }
        }

        @MainActor
        private func updateReticle(timestamp: TimeInterval, trackingIsNormal: Bool) {
            guard parent.stage == .selectSurface || parent.stage == .placeBoundaries else {
                setCanPlace(false)
                return
            }
            guard trackingIsNormal else {
                baseSamples.removeAll()
                baseCandidate = nil
                setCanPlace(false)
                setGuidance("AR tracking is limited. Hold still and keep the measured surfaces visible.")
                setReticle(ready: false)
                return
            }
            if parent.stage == .selectSurface {
                updateBaseSurfaceCandidate(timestamp: timestamp)
            } else {
                updateWallReadiness()
            }
        }

        @MainActor
        private func updateBaseSurfaceCandidate(timestamp: TimeInterval) {
            guard let result = horizontalPlaneRaycast(), let plane = result.anchor as? ARPlaneAnchor else {
                baseSamples.removeAll()
                baseCandidate = nil
                setCanPlace(false)
                setGuidance("Stand at the front of the storage area, facing in, and aim at the surface where products will sit.")
                setReticle(ready: false)
                return
            }
            var normal = normalized(worldNormal(of: result))
            if simd_dot(normal, SIMD3(0, 1, 0)) < 0 { normal = -normal }
            let deviation = acos(min(max(abs(simd_dot(normal, SIMD3(0, 1, 0))), -1), 1)) * 180 / .pi
            guard deviation <= StorageMarkerGeometryBuilder.maximumHorizontalDeviationDegrees else {
                baseSamples.removeAll()
                baseCandidate = nil
                setCanPlace(false)
                setGuidance("This surface is tilted by \(String(format: "%.1f", deviation))°. Choose a horizontal surface.")
                setReticle(ready: false)
                return
            }
            let sample = BaseRaycastSample(
                position: worldPosition(of: result), normal: normal, plane: plane,
                horizontalDeviationDegrees: deviation, timestamp: timestamp
            )
            baseSamples.append(sample)
            baseSamples = baseSamples.filter {
                timestamp - $0.timestamp <= 0.8 && $0.plane.identifier == plane.identifier
            }
            let required = StorageMarkerScannerView.hasLiDAR ? 7 : 10
            guard baseSamples.count >= required else {
                baseCandidate = nil
                setCanPlace(false)
                setGuidance("Hold still while the base surface stabilizes (\(baseSamples.count)/\(required)).")
                setReticle(ready: false)
                return
            }
            let centre = baseSamples.map(\.position).reduce(.zero, +) / Double(baseSamples.count)
            let spread = sqrt(baseSamples.reduce(0.0) {
                $0 + simd_distance_squared($1.position, centre)
            } / Double(baseSamples.count))
            let maximumSpread = StorageMarkerScannerView.hasLiDAR ? 0.01 : 0.015
            guard spread <= maximumSpread else {
                baseCandidate = nil
                setCanPlace(false)
                setGuidance("Hold still. The base estimate is moving by \(String(format: "%.1f", spread * 100)) cm.")
                setReticle(ready: false)
                return
            }
            baseCandidate = BaseRaycastSample(
                position: centre, normal: normal, plane: plane,
                horizontalDeviationDegrees: deviation, timestamp: timestamp
            )
            baseConfidence = min(
                0.62 + min(Double(baseSamples.count) / Double(required * 2), 1) * 0.28
                    + (StorageMarkerScannerView.hasLiDAR ? 0.08 : 0),
                0.98
            )
            setCanPlace(true)
            setGuidance("Horizontal storage surface ready. Select this surface.")
            setReticle(ready: true)
        }

        @MainActor
        private func updateWallReadiness() {
            if existingVerticalPlaneRaycast() != nil {
                setCanPlace(true)
                setGuidance("Ready to place boundary \(boundaries.count + 1) of 4 on this wall.")
                setReticle(ready: true)
            } else if StorageMarkerScannerView.hasLiDAR, estimatedWallSeedRaycast() != nil {
                setCanPlace(true)
                setGuidance("Potential wall detected. Place Boundary to verify the local LiDAR surface.")
                setReticle(ready: true)
            } else {
                setCanPlace(false)
                setGuidance("Aim at a wall or vertical limiting surface—not the selected base plane.")
                setReticle(ready: false)
            }
        }

        @MainActor
        private func performPlacement() {
            parent.errorMessage = nil
            switch parent.stage {
            case .selectSurface:
                selectBaseSurface()
            case .placeBoundaries:
                placeWallBoundary()
            case .review, .enterHeight, .preview, .complete:
                break
            }
        }

        @MainActor
        private func selectBaseSurface() {
            guard parent.canPlace, let candidate = baseCandidate,
                  let frame = arView?.session.currentFrame else { return }
            let vertical = candidate.normal
            let camera = SIMD3<Double>(
                Double(frame.camera.transform.columns.3.x),
                Double(frame.camera.transform.columns.3.y),
                Double(frame.camera.transform.columns.3.z)
            )
            var depth = candidate.position - camera
            depth -= vertical * simd_dot(depth, vertical)
            if simd_length(depth) < 0.05 {
                depth = SIMD3<Double>(
                    Double(candidate.plane.transform.columns.2.x),
                    Double(candidate.plane.transform.columns.2.y),
                    Double(candidate.plane.transform.columns.2.z)
                )
            }
            depth = normalized(depth)
            let width = normalized(simd_cross(vertical, depth))
            depth = normalized(simd_cross(width, vertical))
            basis = SurfaceBasis(
                planeID: candidate.plane.identifier,
                origin: candidate.position,
                widthAxis: width, depthAxis: depth, verticalAxis: vertical,
                horizontalDeviationDegrees: candidate.horizontalDeviationDegrees
            )
            showSelectedBasePoint(
                candidate.position,
                surfaceNormal: candidate.normal
            )
            baseSamples.removeAll()
            baseCandidate = nil
            parent.markerCount = 0
            parent.canPlace = false
            parent.stage = .placeBoundaries
            parent.guidance = "The cyan dot marks the base height only. Aim at physical wall 1 of 4."
        }

        @MainActor
        private func placeWallBoundary() {
            guard parent.canPlace, let basis else { return }
            guard let wall = resolveWallAtReticle(basis: basis) else {
                parent.errorMessage = "No reliable vertical wall was found. Aim at a physical wall and try again."
                parent.canPlace = false
                setReticle(ready: false)
                return
            }
            guard let boundary = boundaryFromWall(wall, basis: basis) else {
                parent.errorMessage = "The selected surface is not sufficiently vertical to define a storage boundary."
                return
            }
            do {
                try validateNewBoundary(boundary)
            } catch {
                parent.errorMessage = error.localizedDescription
                return
            }
            boundaries.append(boundary)
            addBoundaryEvidence(boundary, basis: basis)
            logBoundaryPlacement(boundary, rawWallNormal: wall.normal, baseNormal: basis.verticalAxis)
            parent.markerCount = boundaries.count
            parent.canPlace = false
            if boundaries.count == StorageMarkerGeometryBuilder.requiredBoundaryCount {
                finishBoundaryGeometry()
            } else {
                parent.guidance = "Boundary \(boundaries.count) of 4 saved. Aim at physical wall \(boundaries.count + 1)."
            }
        }

        private func resolveWallAtReticle(basis: SurfaceBasis) -> WallObservation? {
            if let result = existingVerticalPlaneRaycast() {
                var normal = normalized(worldNormal(of: result))
                if let frame = arView?.session.currentFrame {
                    let camera = SIMD3<Double>(
                        Double(frame.camera.transform.columns.3.x),
                        Double(frame.camera.transform.columns.3.y),
                        Double(frame.camera.transform.columns.3.z)
                    )
                    if simd_dot(normal, camera - worldPosition(of: result)) < 0 { normal = -normal }
                }
                return WallObservation(
                    hitPosition: worldPosition(of: result), normal: normal,
                    source: .verticalPlaneAnchor, confidence: 0.94
                )
            }
            guard StorageMarkerScannerView.hasLiDAR else { return nil }
            return localMeshWallObservation(basis: basis)
        }

        /// Event-driven fallback: an estimated raycast supplies a seed, then only
        /// nearby mesh anchors and triangles in a 35 cm neighborhood are inspected.
        private func localMeshWallObservation(basis: SurfaceBasis) -> WallObservation? {
            guard let arView, let frame = arView.session.currentFrame,
                  let seedResult = estimatedWallSeedRaycast() else { return nil }
            let seed = worldPosition(of: seedResult)
            let rayOrigin = SIMD3<Double>(
                Double(frame.camera.transform.columns.3.x),
                Double(frame.camera.transform.columns.3.y),
                Double(frame.camera.transform.columns.3.z)
            )
            let rayDirection = normalized(seed - rayOrigin)
            var localTriangles: [LocalMeshTriangle] = []
            localTriangles.reserveCapacity(512)
            let seedWorld = SIMD4<Float>(Float(seed.x), Float(seed.y), Float(seed.z), 1)
            // Slightly wider than the 35 cm limit: this single-precision test
            // only discards faces; the exact test below decides what is kept.
            let earlyRejectSquared: Float = 0.36 * 0.36
            for anchor in frame.anchors.compactMap({ $0 as? ARMeshAnchor }) {
                guard localTriangles.count < 12_000 else { break }
                let anchorOrigin = SIMD3<Double>(
                    Double(anchor.transform.columns.3.x),
                    Double(anchor.transform.columns.3.y),
                    Double(anchor.transform.columns.3.z)
                )
                guard simd_distance(anchorOrigin, seed) <= 1.5 else { continue }
                let faces = anchor.geometry.faces
                let vertices = anchor.geometry.vertices
                guard faces.indexCountPerPrimitive == 3 else { continue }
                let faceBuffer = faces.buffer.contents()
                let vertexBuffer = vertices.buffer.contents().advanced(by: vertices.offset)
                let vertexStride = vertices.stride
                let indicesAreNarrow = faces.bytesPerIndex == MemoryLayout<UInt16>.size
                let transform = anchor.transform
                // An anchor transform is rigid, so distance from the seed can be
                // tested in the anchor's own coordinates. Almost every face
                // fails, and those are never converted to world coordinates.
                let seedInAnchor4 = transform.inverse * seedWorld
                let seedInAnchor = SIMD3<Float>(seedInAnchor4.x, seedInAnchor4.y, seedInAnchor4.z)
                func vertexIndex(_ position: Int) -> Int {
                    indicesAreNarrow
                        ? Int(faceBuffer.load(fromByteOffset: position * 2, as: UInt16.self))
                        : Int(faceBuffer.load(fromByteOffset: position * 4, as: UInt32.self))
                }
                func vertex(_ index: Int) -> SIMD3<Float> {
                    let pointer = vertexBuffer.advanced(by: vertexStride * index)
                        .assumingMemoryBound(to: Float.self)
                    return SIMD3<Float>(pointer[0], pointer[1], pointer[2])
                }
                func world(_ local: SIMD3<Float>) -> SIMD3<Double> {
                    let value = transform * SIMD4(local.x, local.y, local.z, 1)
                    return SIMD3(Double(value.x), Double(value.y), Double(value.z))
                }
                for face in 0..<faces.count {
                    guard localTriangles.count < 12_000 else { break }
                    let a = vertex(vertexIndex(face * 3))
                    let b = vertex(vertexIndex(face * 3 + 1))
                    let c = vertex(vertexIndex(face * 3 + 2))
                    guard simd_distance_squared((a + b + c) / 3, seedInAnchor) <= earlyRejectSquared
                    else { continue }
                    let first = world(a), second = world(b), third = world(c)
                    let centre = (first + second + third) / 3
                    guard simd_distance(centre, seed) <= 0.35 else { continue }
                    let cross = simd_cross(second - first, third - first)
                    let doubledArea = simd_length(cross)
                    guard doubledArea > 0.000_001 else { continue }
                    let normal = cross / doubledArea
                    guard abs(simd_dot(normal, basis.verticalAxis))
                        <= StorageWallGeometry.maximumWallBaseNormalAlignment else { continue }
                    localTriangles.append(.init(
                        first: first, second: second, third: third,
                        normal: normal, centre: centre, area: doubledArea / 2
                    ))
                }
            }
            var best: (triangle: LocalMeshTriangle, distance: Double, position: SIMD3<Double>)?
            for triangle in localTriangles {
                guard let distance = rayTriangleDistance(
                    origin: rayOrigin, direction: rayDirection,
                    first: triangle.first, second: triangle.second, third: triangle.third
                ), distance > 0, distance < 5 else { continue }
                let position = rayOrigin + rayDirection * distance
                guard simd_distance(position, seed) <= 0.35 else { continue }
                if best == nil || distance < best!.distance {
                    best = (triangle, distance, position)
                }
            }
            guard let best else { return nil }
            let neighborhood = localTriangles.filter {
                simd_distance($0.centre, best.position) <= 0.12
                    && abs(simd_dot($0.normal, best.triangle.normal)) >= cos(20 * .pi / 180)
            }
            var summedNormal = SIMD3<Double>.zero
            var totalArea = 0.0
            for triangle in neighborhood {
                let aligned = simd_dot(triangle.normal, best.triangle.normal) >= 0
                    ? triangle.normal : -triangle.normal
                summedNormal += aligned * triangle.area
                totalArea += triangle.area
            }
            guard totalArea > 0, simd_length(summedNormal) > 0 else { return nil }
            var normal = normalized(summedNormal)
            if simd_dot(normal, rayOrigin - best.position) < 0 { normal = -normal }
            let confidence = min(0.62 + min(Double(neighborhood.count) / 20, 1) * 0.28, 0.90)
            return WallObservation(
                hitPosition: best.position, normal: normal,
                source: .localLiDARMesh, confidence: confidence
            )
        }

        private func boundaryFromWall(
            _ wall: WallObservation, basis: SurfaceBasis
        ) -> StorageBoundary? {
            StorageWallGeometry.boundary(
                hitPositionWorld: Vector3D(wall.hitPosition),
                wallNormalWorld: Vector3D(wall.normal),
                source: wall.source,
                confidence: wall.confidence,
                base: StorageBasePlaneCoordinateSystem(
                    originWorld: Vector3D(basis.origin),
                    widthAxisWorld: Vector3D(basis.widthAxis),
                    depthAxisWorld: Vector3D(basis.depthAxis),
                    verticalAxisWorld: Vector3D(basis.verticalAxis)
                )
            )
        }

        @MainActor
        private func addBoundaryEvidence(_ boundary: StorageBoundary, basis: SurfaceBasis) {
            guard let arView, let hit = boundary.hitPositionWorld?.simd,
                  let planeNormal = boundary.wallPlane?.normal,
                  let visualBasis = StorageWallGeometry.visualBasis(
                    boundaryNormalWorld: planeNormal,
                    baseNormalWorld: Vector3D(basis.verticalAxis)
                  ) else { return }
            let anchor = AnchorEntity(world: matrix_identity_float4x4)

            var markerMaterial = UnlitMaterial()
            markerMaterial.color = .init(tint: .systemOrange, texture: nil)
            let marker = ModelEntity(
                mesh: .generateSphere(radius: 0.009), materials: [markerMaterial]
            )
            marker.position = SIMD3<Float>(hit)
            anchor.addChild(marker)

            var planeMaterial = UnlitMaterial()
            planeMaterial.color = .init(
                tint: UIColor.systemOrange.withAlphaComponent(0.18), texture: nil
            )
            let sheet = ModelEntity(
                mesh: .generatePlane(width: 0.32, depth: 0.32),
                materials: [planeMaterial]
            )
            let right = SIMD3<Float>(visualBasis.rightAxisWorld.simd)
            let normal = SIMD3<Float>(visualBasis.normalAxisWorld.simd)
            let up = SIMD3<Float>(visualBasis.upAxisWorld.simd)
            sheet.transform = Transform(matrix: simd_float4x4(columns: (
                SIMD4(right, 0), SIMD4(normal, 0), SIMD4(up, 0), SIMD4(SIMD3<Float>(hit), 1)
            )))
            anchor.addChild(sheet)

            #if DEBUG
            addLine(
                from: hit, to: hit + visualBasis.normalAxisWorld.simd * 0.12,
                color: .systemPink, to: anchor
            )
            #endif
            arView.scene.addAnchor(anchor)
            markerAnchors.append(anchor)
        }

        private func logBoundaryPlacement(
            _ boundary: StorageBoundary,
            rawWallNormal: SIMD3<Double>,
            baseNormal: SIMD3<Double>
        ) {
            #if DEBUG
            guard let hit = boundary.hitPositionWorld?.simd,
                  let plane = boundary.wallPlane else { return }
            let alignment = simd_dot(normalized(rawWallNormal), normalized(baseNormal))
            let constant = simd_dot(plane.normal.simd, plane.origin.simd)
            let source = boundary.source == .verticalPlaneAnchor ? "ARPlane" : "LiDAR mesh"
            print("""
            Storage boundary placed
              hitPosition: \(format(hit))
              raw wallNormal: \(format(rawWallNormal))
              baseNormal: \(format(baseNormal))
              projected boundaryNormal: \(format(plane.normal.simd))
              dot(wallNormal, baseNormal): \(String(format: "%.4f", alignment))
              boundary plane: n=\(format(plane.normal.simd)), n·x=\(String(format: "%.4f", constant))
              boundary source: \(source)
            """)
            #endif
        }

        private func format(_ value: SIMD3<Double>) -> String {
            String(format: "(%.4f, %.4f, %.4f)", value.x, value.y, value.z)
        }

        private func validateNewBoundary(_ candidate: StorageBoundary) throws {
            for existing in boundaries {
                let first = existing.rawNormal2D.simd
                let second = candidate.rawNormal2D.simd
                guard abs(simd_dot(first, second)) >= cos(15 * .pi / 180) else { continue }
                let separation = abs(simd_dot(
                    first, candidate.rawPoint2D.simd - existing.rawPoint2D.simd
                ))
                if separation < 0.005 { throw StorageMarkerGeometryError.duplicateBoundary }
                if separation < StorageMarkerGeometryBuilder.minimumBoundarySpacingMetres {
                    throw StorageMarkerGeometryError.boundaryTooClose
                }
            }
        }

        @MainActor
        private func finishBoundaryGeometry() {
            guard let basis else { return }
            do {
                let result = try StorageMarkerGeometryBuilder.build(boundaries: boundaries)
                boundaries = result.boundaries
                let confidenceValues = [baseConfidence] + boundaries.compactMap(\.confidence)
                parent.draft = StorageMarkerDraft(
                    id: UUID(), selectedPlaneIdentifier: basis.planeID,
                    basePlaneOriginWorld: Vector3D(basis.origin),
                    localXAxisWorld: Vector3D(basis.widthAxis),
                    localDepthAxisWorld: Vector3D(basis.depthAxis),
                    verticalAxisWorld: Vector3D(basis.verticalAxis),
                    horizontalDeviationDegrees: basis.horizontalDeviationDegrees,
                    boundaries: result.boundaries,
                    rawFootprint2D: result.raw.map(Vector2D.init),
                    correctedFootprint2D: result.corrected?.map(Vector2D.init),
                    correctionAppliedAutomatically: false,
                    correctionMaximumMovementMetres: result.maximumCorrection,
                    confidence: confidenceValues.reduce(0, +) / Double(confidenceValues.count),
                    deviceHasLiDAR: StorageMarkerScannerView.hasLiDAR
                )
                parent.errorMessage = nil
                parent.stage = .review
                parent.guidance = result.corrected == nil
                    ? "Review the footprint calculated from the four physical wall planes."
                    : "The wall geometry is close to rectangular. Review the measured and corrected outlines."
                renderPreview(includeHeight: false)
            } catch {
                parent.errorMessage = error.localizedDescription
                boundaries.removeLast()
                markerAnchors.removeLast().removeFromParent()
                parent.markerCount = boundaries.count
                parent.guidance = "Reposition the fourth wall boundary and try again."
            }
        }

        @MainActor
        private func undo() {
            previewAnchor?.removeFromParent()
            previewAnchor = nil
            renderedPreviewSignature = nil
            parent.errorMessage = nil
            parent.draft = nil
            if !boundaries.isEmpty {
                boundaries.removeLast()
                markerAnchors.removeLast().removeFromParent()
                parent.markerCount = boundaries.count
                parent.stage = .placeBoundaries
                parent.guidance = "Last boundary removed. Aim at wall \(boundaries.count + 1) of 4."
            } else if basis != nil {
                basis = nil
                baseSamples.removeAll()
                baseCandidate = nil
                baseConfidence = 0
                basePlaneAnchor?.removeFromParent()
                basePlaneAnchor = nil
                parent.markerCount = 0
                parent.stage = .selectSurface
                parent.guidance = "Stand at the front of the storage area, facing in, and aim at the surface where products will sit."
            }
            parent.canPlace = false
        }

        @MainActor
        private func reset() {
            basis = nil
            baseSamples.removeAll()
            baseCandidate = nil
            baseConfidence = 0
            boundaries.removeAll()
            markerAnchors.forEach { $0.removeFromParent() }
            markerAnchors.removeAll()
            basePlaneAnchor?.removeFromParent()
            basePlaneAnchor = nil
            previewAnchor?.removeFromParent()
            previewAnchor = nil
            renderedPreviewSignature = nil
            parent.draft = nil
            parent.markerCount = 0
            parent.canPlace = false
            parent.errorMessage = nil
            parent.stage = .selectSurface
            parent.guidance = "Stand at the front of the storage area, facing in, and aim at the surface where products will sit."
        }

        @MainActor
        private func renderPreview(includeHeight: Bool) {
            guard let arView, let basis, let draft = parent.draft else { return }
            let footprint = parent.useCorrectedFootprint
                ? draft.correctedFootprint2D ?? draft.rawFootprint2D
                : draft.rawFootprint2D
            let heightCM = includeHeight ? parent.previewHeightCM : nil
            let signature = PreviewSignature(footprint: footprint, heightCM: heightCM)
            guard signature != renderedPreviewSignature else { return }

            let bottom: [SIMD3<Double>]
            let top: [SIMD3<Double>]?
            if includeHeight {
                guard let heightCM,
                      let outline = draft.volumeOutline(
                        useCorrectedFootprint: parent.useCorrectedFootprint,
                        heightCM: heightCM
                      ) else { return }
                bottom = outline.bottomVerticesWorld.map(\.simd)
                top = outline.topVerticesWorld.map(\.simd)
            } else {
                bottom = footprint.map { worldPoint($0.simd, heightMetres: 0, basis: basis) }
                top = nil
            }

            previewAnchor?.removeFromParent()
            let anchor = AnchorEntity(world: matrix_identity_float4x4)
            for index in bottom.indices {
                addLine(
                    from: bottom[index], to: bottom[(index + 1) % bottom.count],
                    color: parent.useCorrectedFootprint ? .systemGreen : .systemOrange,
                    to: anchor
                )
            }
            if let top {
                for index in top.indices {
                    addLine(from: top[index], to: top[(index + 1) % top.count], color: .systemGreen, to: anchor)
                    addLine(from: bottom[index], to: top[index], color: .systemGreen, to: anchor)
                }
            }
            arView.scene.addAnchor(anchor)
            previewAnchor = anchor
            renderedPreviewSignature = signature
        }

        private func horizontalPlaneRaycast() -> ARRaycastResult? {
            guard let arView else { return nil }
            let centre = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            return arView.raycast(
                from: centre, allowing: .existingPlaneGeometry, alignment: .horizontal
            ).first ?? arView.raycast(
                from: centre, allowing: .existingPlaneInfinite, alignment: .horizontal
            ).first
        }

        private func existingVerticalPlaneRaycast() -> ARRaycastResult? {
            guard let arView else { return nil }
            let centre = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            return arView.raycast(
                from: centre, allowing: .existingPlaneGeometry, alignment: .vertical
            ).first
        }

        private func estimatedWallSeedRaycast() -> ARRaycastResult? {
            guard let arView else { return nil }
            let centre = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            return arView.raycast(
                from: centre, allowing: .estimatedPlane, alignment: .vertical
            ).first
        }

        @MainActor
        private func showSelectedBasePoint(
            _ selectedPoint: SIMD3<Double>,
            surfaceNormal: SIMD3<Double>
        ) {
            guard let arView else { return }
            basePlaneAnchor?.removeFromParent()
            let anchor = AnchorEntity(world: matrix_identity_float4x4)

            var dotMaterial = UnlitMaterial()
            dotMaterial.color = .init(tint: .systemCyan, texture: nil)
            let dotRadius = 0.012
            let referenceDot = ModelEntity(
                mesh: .generateSphere(radius: Float(dotRadius)),
                materials: [dotMaterial]
            )
            // Keep the marker's bottom at the measured base height while lifting
            // its centre above the surface so the dot remains fully visible.
            let visiblePosition = selectedPoint + normalized(surfaceNormal) * dotRadius
            referenceDot.position = SIMD3<Float>(visiblePosition)
            anchor.addChild(referenceDot)

            arView.scene.addAnchor(anchor)
            basePlaneAnchor = anchor
        }

        @MainActor
        private func setReticle(ready: Bool) {
            guard ready != reticleIsReady else { return }
            reticleIsReady = ready
            reticle?.layer.borderColor = (ready ? UIColor.systemGreen : UIColor.systemOrange).cgColor
        }

        private func addLine(
            from start: SIMD3<Double>, to end: SIMD3<Double>, color: UIColor, to anchor: AnchorEntity
        ) {
            let direction = SIMD3<Float>(end - start)
            let length = simd_length(direction)
            guard length > 0.0001 else { return }
            var material = UnlitMaterial()
            material.color = .init(tint: color.withAlphaComponent(0.85), texture: nil)
            let line = ModelEntity(
                mesh: .generateBox(width: 0.004, height: 0.004, depth: length),
                materials: [material]
            )
            line.position = SIMD3<Float>((start + end) / 2)
            line.orientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: simd_normalize(direction))
            anchor.addChild(line)
        }

        private func worldPoint(
            _ point: SIMD2<Double>, heightMetres: Double, basis: SurfaceBasis
        ) -> SIMD3<Double> {
            basis.origin + basis.widthAxis * point.x + basis.depthAxis * point.y
                + basis.verticalAxis * heightMetres
        }

        private func worldPosition(of result: ARRaycastResult) -> SIMD3<Double> {
            SIMD3(
                Double(result.worldTransform.columns.3.x),
                Double(result.worldTransform.columns.3.y),
                Double(result.worldTransform.columns.3.z)
            )
        }

        private func worldNormal(of result: ARRaycastResult) -> SIMD3<Double> {
            SIMD3(
                Double(result.worldTransform.columns.1.x),
                Double(result.worldTransform.columns.1.y),
                Double(result.worldTransform.columns.1.z)
            )
        }

        private func rayTriangleDistance(
            origin: SIMD3<Double>, direction: SIMD3<Double>,
            first: SIMD3<Double>, second: SIMD3<Double>, third: SIMD3<Double>
        ) -> Double? {
            let epsilon = 0.000_001
            let edge1 = second - first, edge2 = third - first
            let h = simd_cross(direction, edge2)
            let determinant = simd_dot(edge1, h)
            guard abs(determinant) > epsilon else { return nil }
            let inverse = 1 / determinant
            let s = origin - first
            let u = inverse * simd_dot(s, h)
            guard u >= 0, u <= 1 else { return nil }
            let q = simd_cross(s, edge1)
            let v = inverse * simd_dot(direction, q)
            guard v >= 0, u + v <= 1 else { return nil }
            let distance = inverse * simd_dot(edge2, q)
            return distance > epsilon ? distance : nil
        }

        private func normalized(_ value: SIMD3<Double>) -> SIMD3<Double> {
            let length = simd_length(value)
            return length > 0 ? value / length : SIMD3(0, 1, 0)
        }
    }
}
