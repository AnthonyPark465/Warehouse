import ARKit
import RealityKit
import SwiftUI

struct MeasuredShelfSurface: Equatable {
    let id: UUID
    let widthCM: Double
    let depthCM: Double
}

struct LiDARSurfaceScannerView: UIViewRepresentable {
    @Binding var measuredSurfaces: [MeasuredShelfSurface]

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(measuredSurfaces: $measuredSurfaces)
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

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        weak var arView: ARView?
        private var measuredSurfaces: Binding<[MeasuredShelfSurface]>

        init(measuredSurfaces: Binding<[MeasuredShelfSurface]>) {
            self.measuredSurfaces = measuredSurfaces
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            guard let selectedID = measuredSurfaces.wrappedValue.first?.id,
                  let plane = anchors
                    .compactMap({ $0 as? ARPlaneAnchor })
                    .first(where: { $0.identifier == selectedID }),
                  let measurement = measurement(for: plane)
            else { return }
            DispatchQueue.main.async {
                self.measuredSurfaces.wrappedValue = [measurement]
            }
        }

        @objc func selectSurface(_ gesture: UITapGestureRecognizer) {
            guard let arView,
                  let result = arView.raycast(
                    from: gesture.location(in: arView),
                    allowing: .existingPlaneGeometry,
                    alignment: .horizontal
                  ).first,
                  let plane = result.anchor as? ARPlaneAnchor,
                  let measurement = measurement(for: plane)
            else { return }
            measuredSurfaces.wrappedValue = [measurement]
        }

        private func measurement(for plane: ARPlaneAnchor) -> MeasuredShelfSurface? {
            let width = plane.planeExtent.width
            let depth = plane.planeExtent.height
            guard width >= 0.15, depth >= 0.15 else { return nil }
            return MeasuredShelfSurface(
                id: plane.identifier,
                widthCM: Double(width * 100),
                depthCM: Double(depth * 100)
            )
        }
    }
}
