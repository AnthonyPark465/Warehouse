import ARKit
import RealityKit
import SwiftUI
import UIKit

enum ShelfMeasurementStage: Equatable {
    case boundary
    case bottom
    case top
    case complete
}

struct MeasuredShelfSurface: Equatable {
    let id: UUID
    let widthCM: Double
    let depthCM: Double
    /// nil when no obstruction was found above (open-topped shelf).
    let measuredFreeHeightCM: Double?
}

struct LiDARSurfaceScannerView: UIViewRepresentable {
    @Binding var measuredSurfaces: [MeasuredShelfSurface]
    @Binding var mappedPointCount: Int
    @Binding var canPlacePoint: Bool
    @Binding var measurementStage: ShelfMeasurementStage
    let resetToken: Int
    let placementRequestID: Int
    let undoRequestID: Int

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            measuredSurfaces: $measuredSurfaces,
            mappedPointCount: $mappedPointCount,
            canPlacePoint: $canPlacePoint,
            measurementStage: $measurementStage,
            resetToken: resetToken,
            placementRequestID: placementRequestID,
            undoRequestID: undoRequestID
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
        if Self.isSupported {
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

        // Keep the visible reticle inside ARView so it uses the exact same
        // bounds and centre pixel as `centreRaycast()`.
        let target = UIView()
        target.translatesAutoresizingMaskIntoConstraints = false
        target.isUserInteractionEnabled = false
        target.isAccessibilityElement = true
        target.accessibilityLabel = "No shelf surface detected"
        target.layer.cornerRadius = 14
        target.layer.borderWidth = 3
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
            target.widthAnchor.constraint(equalToConstant: 28),
            target.heightAnchor.constraint(equalToConstant: 28),
            dot.centerXAnchor.constraint(equalTo: target.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: target.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6)
        ])
        context.coordinator.attachTarget(target, dot: dot)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.handle(
            resetToken: resetToken,
            placementRequestID: placementRequestID,
            undoRequestID: undoRequestID
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
        private var mappedPoints: [SIMD3<Float>] = []
        private var selectedPlaneID: UUID?
        private var selectedPlane: ARPlaneAnchor?
        private var boundaryMeasurement: BoundaryMeasurement?
        private var bottomPoint: SIMD3<Float>?
        private var topPoint: SIMD3<Float>?
        private var selectionAnchor: AnchorEntity?
        private var heightAnchor: AnchorEntity?
        private weak var targetView: UIView?
        private weak var targetDot: UIView?
        private var lastResetToken: Int
        private var handledPlacementRequestID: Int
        private var handledUndoRequestID: Int

        init(
            measuredSurfaces: Binding<[MeasuredShelfSurface]>,
            mappedPointCount: Binding<Int>,
            canPlacePoint: Binding<Bool>,
            measurementStage: Binding<ShelfMeasurementStage>,
            resetToken: Int,
            placementRequestID: Int,
            undoRequestID: Int
        ) {
            self.measuredSurfaces = measuredSurfaces
            self.mappedPointCount = mappedPointCount
            self.canPlacePoint = canPlacePoint
            self.measurementStage = measurementStage
            self.lastResetToken = resetToken
            self.handledPlacementRequestID = placementRequestID
            self.handledUndoRequestID = undoRequestID
        }

        @MainActor
        func attachTarget(_ target: UIView, dot: UIView) {
            targetView = target
            targetDot = dot
            updateTargetAppearance(isValid: false)
        }

        @MainActor
        func handle(resetToken: Int, placementRequestID: Int, undoRequestID: Int) {
            if resetToken != lastResetToken {
                lastResetToken = resetToken
                DispatchQueue.main.async { [weak self] in self?.resetSelection() }
            }
            if placementRequestID != handledPlacementRequestID {
                handledPlacementRequestID = placementRequestID
                DispatchQueue.main.async { [weak self] in self?.performPlacementAtCentre() }
            }
            if undoRequestID != handledUndoRequestID {
                handledUndoRequestID = undoRequestID
                DispatchQueue.main.async { [weak self] in self?.undoLastMarker() }
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
            measuredSurfaces.wrappedValue = []
            mappedPointCount.wrappedValue = 0
            measurementStage.wrappedValue = .boundary
            updateTargetAvailability()
        }

        @MainActor
        private func undoLastMarker() {
            switch measurementStage.wrappedValue {
            case .boundary, .bottom:
                undoBoundaryMarker()
            case .top:
                bottomPoint = nil
                topPoint = nil
                replaceMeasuredHeight(nil)
                heightAnchor?.removeFromParent()
                heightAnchor = nil
                measurementStage.wrappedValue = .bottom
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
            case .bottom:
                placeBottomPointAtCentre()
            case .top:
                placeTopPointAtCentre()
            case .complete:
                break
            }
        }

        @MainActor
        private func placeBoundaryPointAtCentre() {
            guard let result = centreRaycast(),
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
                result.worldTransform.columns.3.x,
                result.worldTransform.columns.3.y,
                result.worldTransform.columns.3.z,
                1
            )
            let localPosition = simd_inverse(plane.transform) * worldPosition
            mappedPoints.append(SIMD3<Float>(localPosition.x, 0.006, localPosition.z))
            mappedPointCount.wrappedValue = mappedPoints.count
            updateMeasurement(on: plane)
            showMappedArea(on: plane)
            updateTargetAvailability()
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
            measurementStage.wrappedValue = .complete
            showHeightMarkers()
            updateTargetAvailability()
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            Task { @MainActor [weak self] in
                self?.updateTargetAvailability()
            }
        }

        @MainActor
        private func updateTargetAvailability() {
            let isValid: Bool
            switch measurementStage.wrappedValue {
            case .boundary, .bottom:
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
            case .complete:
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
                let world = plane.transform * SIMD4<Float>(point.x, 0, point.z, 1)
                return SIMD3<Float>(world.x, world.y, world.z)
            }
            guard let boundary = try? ManualMeasurementGeometry.measureBoundary(worldBoundary) else {
                boundaryMeasurement = nil
                measuredSurfaces.wrappedValue = []
                return
            }
            boundaryMeasurement = boundary

            measuredSurfaces.wrappedValue = [
                MeasuredShelfSurface(
                    id: plane.identifier,
                    widthCM: Double((maxX - minX) * 100),
                    depthCM: Double((maxZ - minZ) * 100),
                    measuredFreeHeightCM: nil
                )
            ]
        }

        private func replaceMeasuredHeight(_ heightCM: Double?) {
            guard let surface = measuredSurfaces.wrappedValue.first else { return }
            measuredSurfaces.wrappedValue = [
                MeasuredShelfSurface(
                    id: surface.id,
                    widthCM: surface.widthCM,
                    depthCM: surface.depthCM,
                    measuredFreeHeightCM: heightCM
                )
            ]
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

            if mappedPoints.count >= 3 {
                anchor.addChild(line(from: mappedPoints.last!, to: mappedPoints[0]))
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
