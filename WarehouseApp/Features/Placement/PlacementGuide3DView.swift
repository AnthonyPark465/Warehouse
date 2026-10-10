import SceneKit
import SwiftUI

/// Rotatable 3D guide: the recommended product pose drawn inside the storage
/// volume, as seen by someone standing at the front of the storage area.
struct PlacementGuide3DView: View {
    let shelf: ShelfState
    let placement: ProductPlacementResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlacementGuideSceneView(shelf: shelf, placement: placement)
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Three dimensional view of the product position inside \(shelf.displayLabel)")
            HStack(spacing: 14) {
                legendItem("This product", PlacementGuideScene.productColor)
                legendItem("Storage space", PlacementGuideScene.storageColor)
                legendItem("Front edge", PlacementGuideScene.frontColor)
                if !shelf.products.isEmpty || !shelf.obstacles.isEmpty {
                    legendItem("Already there", PlacementGuideScene.occupiedColor)
                }
            }
            .font(.caption)
            Text("Drag to rotate, pinch to zoom. The front edge is the side the storage area was measured from.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func legendItem(_ title: String, _ color: UIColor) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(uiColor: color))
                .frame(width: 12, height: 12)
            Text(title)
        }
    }
}

private struct PlacementGuideSceneView: UIViewRepresentable {
    let shelf: ShelfState
    let placement: ProductPlacementResult

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor.secondarySystemBackground
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        update(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        update(uiView, coordinator: context.coordinator)
    }

    final class Coordinator {
        var renderedPlacementID: String?
        var renderedShelfVersion: Int?
    }

    private func update(_ view: SCNView, coordinator: Coordinator) {
        guard coordinator.renderedPlacementID != placement.id
            || coordinator.renderedShelfVersion != shelf.version else { return }
        let scene = PlacementGuideScene.make(shelf: shelf, placement: placement)
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(
            withName: PlacementGuideScene.cameraName, recursively: true
        )
        coordinator.renderedPlacementID = placement.id
        coordinator.renderedShelfVersion = shelf.version
    }
}

enum PlacementGuideScene {
    static let productColor = UIColor.systemOrange
    static let storageColor = UIColor.systemBlue
    static let frontColor = UIColor.systemGreen
    static let occupiedColor = UIColor.systemGray
    static let cameraName = "guideCamera"
    static let productName = "guideProduct"

    static func make(shelf: ShelfState, placement: ProductPlacementResult) -> SCNScene {
        let scene = SCNScene()
        let root = scene.rootNode
        let bounds = shelf.boundary
        let centre = SIMD3<Double>(
            bounds.minimum.x + bounds.dimensions.widthCM / 2,
            bounds.minimum.y,
            bounds.minimum.z + bounds.dimensions.depthCM / 2
        )
        // Shelf-local width runs right to left for someone facing in from the
        // front, so the scene is the local frame turned half a turn about the
        // vertical axis: the front edge ends up nearest the camera.
        func point(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Float> {
            SIMD3<Float>(
                Float(-(x - centre.x) / 100),
                Float((y - centre.y) / 100),
                Float(-(z - centre.z) / 100)
            )
        }
        let height = bounds.dimensions.heightCM
        let extent = Float(max(bounds.dimensions.widthCM, bounds.dimensions.depthCM, height) / 100)
        let lineRadius = CGFloat(max(extent * 0.004, 0.0015))

        let footprint = shelf.footprintPolygon
        let opening = shelf.footprintOpeningEdgeIndices
        let base = footprint.map { point($0.x, bounds.minimum.y, $0.y) }
        let top = footprint.map { point($0.x, bounds.minimum.y + height, $0.y) }
        root.addChildNode(floorFill(base))
        for index in base.indices {
            let next = (index + 1) % base.count
            let isFront = opening.contains(index)
            root.addChildNode(edge(
                from: base[index], to: base[next],
                radius: isFront ? lineRadius * 2.5 : lineRadius,
                color: isFront ? frontColor : storageColor
            ))
            root.addChildNode(edge(from: top[index], to: top[next], radius: lineRadius, color: storageColor))
            root.addChildNode(edge(from: base[index], to: top[index], radius: lineRadius, color: storageColor))
        }
        if let front = opening.min() {
            let middle = (base[front] + base[(front + 1) % base.count]) / 2
            root.addChildNode(label(
                "FRONT", at: middle + SIMD3<Float>(0, 0, extent * 0.09), extent: extent, color: frontColor
            ))
        }

        for volume in shelf.products.map(\.volume) + shelf.obstacles.map(\.volume) {
            root.addChildNode(box(
                volume, point: point, color: occupiedColor, opacity: 0.55, outlineRadius: lineRadius
            ))
        }
        let product = box(
            AxisAlignedVolume(id: placement.id, minimum: placement.position, dimensions: placement.orientedDimensions),
            point: point, color: productColor, opacity: 0.9, outlineRadius: lineRadius * 1.5
        )
        product.name = productName
        root.addChildNode(product)

        let camera = SCNNode()
        camera.name = cameraName
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        camera.camera?.zFar = Double(extent) * 40
        let distance = max(extent * 1.4, 0.6)
        let target = SIMD3<Float>(0, Float(height / 200), 0)
        camera.simdPosition = target + SIMD3<Float>(distance * 0.45, distance * 0.7, distance)
        camera.simdLook(at: target)
        root.addChildNode(camera)
        return scene
    }

    private static func material(_ color: UIColor, opacity: CGFloat = 1) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .constant
        material.transparency = opacity
        material.isDoubleSided = true
        material.writesToDepthBuffer = opacity >= 1
        return material
    }

    private static func edge(
        from start: SIMD3<Float>, to end: SIMD3<Float>, radius: CGFloat, color: UIColor
    ) -> SCNNode {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0 else { return SCNNode() }
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(length))
        cylinder.radialSegmentCount = 8
        cylinder.materials = [material(color)]
        let node = SCNNode(geometry: cylinder)
        node.simdPosition = (start + end) / 2
        let direction = delta / length
        // A cylinder's axis is +Y; a downward edge is the same segment reversed.
        node.simdOrientation = simd_quatf(
            from: SIMD3<Float>(0, 1, 0), to: direction.y < -0.999 ? -direction : direction
        )
        return node
    }

    private static func floorFill(_ base: [SIMD3<Float>]) -> SCNNode {
        guard let first = base.first else { return SCNNode() }
        let path = UIBezierPath()
        path.move(to: CGPoint(x: CGFloat(first.x), y: CGFloat(-first.z)))
        for vertex in base.dropFirst() {
            path.addLine(to: CGPoint(x: CGFloat(vertex.x), y: CGFloat(-vertex.z)))
        }
        path.close()
        let shape = SCNShape(path: path, extrusionDepth: 0)
        shape.materials = [material(storageColor, opacity: 0.14)]
        let node = SCNNode(geometry: shape)
        // SCNShape is drawn in the XY plane; lay it flat on the storage surface.
        node.eulerAngles.x = -.pi / 2
        node.simdPosition.y = first.y
        return node
    }

    private static func box(
        _ volume: AxisAlignedVolume,
        point: (Double, Double, Double) -> SIMD3<Float>,
        color: UIColor,
        opacity: CGFloat,
        outlineRadius: CGFloat
    ) -> SCNNode {
        let low = volume.minimum, high = volume.maximum
        let geometry = SCNBox(
            width: CGFloat(volume.dimensions.widthCM / 100),
            height: CGFloat(volume.dimensions.heightCM / 100),
            length: CGFloat(volume.dimensions.depthCM / 100),
            chamferRadius: 0
        )
        let fill = SCNMaterial()
        fill.diffuse.contents = color
        fill.transparency = opacity
        geometry.materials = [fill]
        let node = SCNNode(geometry: geometry)
        node.simdPosition = (point(low.x, low.y, low.z) + point(high.x, high.y, high.z)) / 2

        let outline = SCNNode()
        let xs = [low.x, high.x], ys = [low.y, high.y], zs = [low.z, high.z]
        for a in 0..<2 {
            for b in 0..<2 {
                outline.addChildNode(edge(from: point(xs[0], ys[a], zs[b]), to: point(xs[1], ys[a], zs[b]),
                                          radius: outlineRadius, color: color))
                outline.addChildNode(edge(from: point(xs[a], ys[0], zs[b]), to: point(xs[a], ys[1], zs[b]),
                                          radius: outlineRadius, color: color))
                outline.addChildNode(edge(from: point(xs[a], ys[b], zs[0]), to: point(xs[a], ys[b], zs[1]),
                                          radius: outlineRadius, color: color))
            }
        }
        let group = SCNNode()
        group.addChildNode(node)
        group.addChildNode(outline)
        return group
    }

    private static func label(
        _ string: String, at position: SIMD3<Float>, extent: Float, color: UIColor
    ) -> SCNNode {
        let text = SCNText(string: string, extrusionDepth: 0)
        text.font = .systemFont(ofSize: 10, weight: .bold)
        text.flatness = 0.2
        text.materials = [material(color)]
        let node = SCNNode(geometry: text)
        let (low, high) = text.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((low.x + high.x) / 2, low.y, 0)
        let scale = max(extent / 170, 0.0007)
        node.simdScale = SIMD3<Float>(repeating: scale)
        node.simdPosition = position
        node.constraints = [SCNBillboardConstraint()]
        return node
    }
}
