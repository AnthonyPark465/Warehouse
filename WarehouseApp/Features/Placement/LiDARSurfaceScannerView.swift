import ARKit
import RealityKit
import SwiftUI
import UIKit

struct MeasuredShelfSurface: Equatable {
    let id: UUID
    let widthCM: Double
    let depthCM: Double
}

struct LiDARSurfaceScannerView: UIViewRepresentable {
    @Binding var measuredSurfaces: [MeasuredShelfSurface]
    @Binding var mappedPointCount: Int
    let resetToken: Int

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            measuredSurfaces: $measuredSurfaces,
            mappedPointCount: $mappedPointCount,
            resetToken: resetToken
        )
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        if Self.isSupported {
            configuration.sceneReconstruction = .mesh
        }
        configuration.environmentTexturing = .automatic
        view.session.delegate = context.coordinator
        view.session.run(configuration)
        context.coordinator.arView = view
        view.addGestureRecognizer(
            UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.selectSurface(_:))
            )
        )

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
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.resetIfRequested(resetToken)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        weak var arView: ARView?
        private var measuredSurfaces: Binding<[MeasuredShelfSurface]>
        private var mappedPointCount: Binding<Int>
        private var mappedPoints: [SIMD3<Float>] = []
        private var selectedPlaneID: UUID?
        private var selectionAnchor: AnchorEntity?
        private var lastResetToken: Int

        init(
            measuredSurfaces: Binding<[MeasuredShelfSurface]>,
            mappedPointCount: Binding<Int>,
            resetToken: Int
        ) {
            self.measuredSurfaces = measuredSurfaces
            self.mappedPointCount = mappedPointCount
            self.lastResetToken = resetToken
        }

        func resetIfRequested(_ token: Int) {
            guard token != lastResetToken else { return }
            lastResetToken = token
            mappedPoints.removeAll()
            selectedPlaneID = nil
            selectionAnchor?.removeFromParent()
            selectionAnchor = nil
            measuredSurfaces.wrappedValue = []
            mappedPointCount.wrappedValue = 0
        }

        @objc func selectSurface(_ gesture: UITapGestureRecognizer) {
            guard let arView,
                  let result = arView.raycast(
                    from: gesture.location(in: arView),
                    allowing: .existingPlaneGeometry,
                    alignment: .horizontal
                  ).first,
                  let plane = result.anchor as? ARPlaneAnchor
            else { return }

            if let selectedPlaneID, selectedPlaneID != plane.identifier {
                return
            }

            if selectedPlaneID == nil {
                selectedPlaneID = plane.identifier
            }

            let worldPosition = SIMD4<Float>(
                result.worldTransform.columns.3.x,
                result.worldTransform.columns.3.y,
                result.worldTransform.columns.3.z,
                1
            )
            let localPosition = simd_inverse(plane.transform) * worldPosition
            mappedPoints.append(SIMD3<Float>(localPosition.x, 0.006, localPosition.z))
            mappedPointCount.wrappedValue = mappedPoints.count
            updateMeasurement(planeID: plane.identifier)
            showMappedArea(on: plane)
        }

        private func updateMeasurement(planeID: UUID) {
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

            measuredSurfaces.wrappedValue = [
                MeasuredShelfSurface(
                    id: planeID,
                    widthCM: Double((maxX - minX) * 100),
                    depthCM: Double((maxZ - minZ) * 100)
                )
            ]
        }

        /// Draws the user's control points, joins them with white lines, and
        /// fills the enclosed polygon at 40% opacity once three points exist.
        private func showMappedArea(on plane: ARPlaneAnchor) {
            guard let arView else { return }
            selectionAnchor?.removeFromParent()

            let anchor = AnchorEntity(world: plane.transform)

            for point in mappedPoints {
                var pointMaterial = UnlitMaterial()
                pointMaterial.color = .init(tint: .white, texture: nil)
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
            material.color = .init(tint: .white, texture: nil)
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
            // 40% opacity is approximately 60% transparent.
            material.color = .init(tint: UIColor.white.withAlphaComponent(0.40), texture: nil)
            return ModelEntity(mesh: mesh, materials: [material])
        }
    }
}
