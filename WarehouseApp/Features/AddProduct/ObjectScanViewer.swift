import SceneKit
import SwiftUI

struct ObjectScanViewer: UIViewRepresentable {
    let capture: ObjectScanCapture
    let record: ProductObjectScan
    let displayUnit: DimensionDisplayUnit
    let resetCameraToken: Int

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
        var renderedCaptureID: UUID?
        var renderedUnit: DimensionDisplayUnit?
        var resetCameraToken = -1
    }

    private func update(_ view: SCNView, coordinator: Coordinator) {
        if coordinator.renderedCaptureID != capture.id || coordinator.renderedUnit != displayUnit {
            view.scene = makeScene()
            coordinator.renderedCaptureID = capture.id
            coordinator.renderedUnit = displayUnit
            coordinator.resetCameraToken = resetCameraToken
        } else if coordinator.resetCameraToken != resetCameraToken {
            coordinator.resetCameraToken = resetCameraToken
            resetCamera(in: view)
        }
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        let final = SIMD3<Float>(
            Float(record.finalLength / 100),
            Float(record.finalHeight / 100),
            Float(record.finalWidth / 100)
        )
        let raw = SIMD3<Float>(
            Float(record.rawLength / 100),
            Float(record.rawHeight / 100),
            Float(record.rawWidth / 100)
        )

        scene.rootNode.addChildNode(floorGrid(size: max(final.x, final.z) * 1.8))
        scene.rootNode.addChildNode(storageBox(size: final))
        scene.rootNode.addChildNode(scannedObject(size: raw))
        scene.rootNode.addChildNode(pointCloud(points: capture.pointsInMetres, height: raw.y))
        addLabels(to: scene.rootNode, size: final)
        scene.rootNode.addChildNode(cameraNode(for: final))
        return scene
    }

    private func scannedObject(size: SIMD3<Float>) -> SCNNode {
        let box = SCNBox(
            width: CGFloat(size.x),
            height: CGFloat(size.y),
            length: CGFloat(size.z),
            chamferRadius: min(CGFloat(size.min() * 0.04), 0.012)
        )
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.16)
        material.isDoubleSided = true
        box.materials = [material]
        let node = SCNNode(geometry: box)
        node.position.y = size.y / 2
        return node
    }

    private func pointCloud(points: [SIMD3<Float>], height: Float) -> SCNNode {
        guard !points.isEmpty else { return SCNNode() }
        let data = points.withUnsafeBytes { Data($0) }
        let source = SCNGeometrySource(
            data: data,
            semantic: .vertex,
            vectorCount: points.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let element = SCNGeometryElement(
            data: nil,
            primitiveType: .point,
            primitiveCount: points.count,
            bytesPerIndex: 0
        )
        element.pointSize = 4
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 6
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemTeal
        material.lightingModel = .constant
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.position.y = height / 2
        return node
    }

    private func storageBox(size: SIMD3<Float>) -> SCNNode {
        let root = SCNNode()
        let faces = SCNBox(
            width: CGFloat(size.x),
            height: CGFloat(size.y),
            length: CGFloat(size.z),
            chamferRadius: 0
        )
        let faceMaterial = SCNMaterial()
        faceMaterial.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.08)
        faceMaterial.transparency = 0.22
        faceMaterial.isDoubleSided = true
        faces.materials = [faceMaterial]
        let faceNode = SCNNode(geometry: faces)
        faceNode.position.y = size.y / 2
        root.addChildNode(faceNode)

        let thickness = max(size.max() * 0.006, 0.0015)
        let edgeMaterial = SCNMaterial()
        edgeMaterial.diffuse.contents = UIColor.systemBlue
        for x in [-size.x / 2, size.x / 2] {
            for y in [Float(0), size.y] {
                let edge = edgeNode(length: size.z, thickness: thickness, axis: .z, material: edgeMaterial)
                edge.position = SCNVector3(x, y, 0)
                root.addChildNode(edge)
            }
        }
        for z in [-size.z / 2, size.z / 2] {
            for y in [Float(0), size.y] {
                let edge = edgeNode(length: size.x, thickness: thickness, axis: .x, material: edgeMaterial)
                edge.position = SCNVector3(0, y, z)
                root.addChildNode(edge)
            }
        }
        for x in [-size.x / 2, size.x / 2] {
            for z in [-size.z / 2, size.z / 2] {
                let edge = edgeNode(length: size.y, thickness: thickness, axis: .y, material: edgeMaterial)
                edge.position = SCNVector3(x, size.y / 2, z)
                root.addChildNode(edge)
            }
        }
        return root
    }

    private enum Axis { case x, y, z }

    private func edgeNode(
        length: Float,
        thickness: Float,
        axis: Axis,
        material: SCNMaterial
    ) -> SCNNode {
        let dimensions: (CGFloat, CGFloat, CGFloat)
        switch axis {
        case .x: dimensions = (CGFloat(length), CGFloat(thickness), CGFloat(thickness))
        case .y: dimensions = (CGFloat(thickness), CGFloat(length), CGFloat(thickness))
        case .z: dimensions = (CGFloat(thickness), CGFloat(thickness), CGFloat(length))
        }
        let box = SCNBox(
            width: dimensions.0,
            height: dimensions.1,
            length: dimensions.2,
            chamferRadius: 0
        )
        box.materials = [material]
        return SCNNode(geometry: box)
    }

    private func floorGrid(size: Float) -> SCNNode {
        let root = SCNNode()
        let safeSize = max(size, 0.25)
        let spacing = safeSize / 10
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.tertiaryLabel.withAlphaComponent(0.55)
        for index in -5...5 {
            let offset = Float(index) * spacing
            root.addChildNode(line(
                from: SIMD3<Float>(-safeSize / 2, 0, offset),
                to: SIMD3<Float>(safeSize / 2, 0, offset),
                material: material
            ))
            root.addChildNode(line(
                from: SIMD3<Float>(offset, 0, -safeSize / 2),
                to: SIMD3<Float>(offset, 0, safeSize / 2),
                material: material
            ))
        }
        return root
    }

    private func line(from start: SIMD3<Float>, to end: SIMD3<Float>, material: SCNMaterial) -> SCNNode {
        let source = SCNGeometrySource(vertices: [
            SCNVector3(start.x, start.y, start.z),
            SCNVector3(end.x, end.y, end.z)
        ])
        let element = SCNGeometryElement(indices: [Int32(0), Int32(1)], primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private func addLabels(to root: SCNNode, size: SIMD3<Float>) {
        let labels = [
            (
                DimensionUnitConverter.formatted(record.finalLength, unit: displayUnit),
                SIMD3<Float>(0, -size.max() * 0.06, size.z / 2)
            ),
            (
                DimensionUnitConverter.formatted(record.finalHeight, unit: displayUnit),
                SIMD3<Float>(size.x / 2, size.y / 2, size.z / 2)
            ),
            (
                DimensionUnitConverter.formatted(record.finalWidth, unit: displayUnit),
                SIMD3<Float>(size.x / 2, -size.max() * 0.06, 0)
            )
        ]
        for (value, position) in labels {
            let text = SCNText(string: value, extrusionDepth: 0)
            text.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            text.flatness = 0.2
            text.firstMaterial?.diffuse.contents = UIColor.label
            let node = SCNNode(geometry: text)
            let scale = max(size.max() / 180, 0.0007)
            node.scale = SCNVector3(scale, scale, scale)
            node.position = SCNVector3(position.x, position.y, position.z)
            node.constraints = [SCNBillboardConstraint()]
            root.addChildNode(node)
        }
    }

    private func cameraNode(for size: SIMD3<Float>) -> SCNNode {
        let node = SCNNode()
        node.name = "reviewCamera"
        node.camera = SCNCamera()
        node.camera?.zNear = 0.001
        node.camera?.zFar = 100
        let distance = max(size.max() * 2.2, 0.45)
        node.position = SCNVector3(distance, distance * 0.75, distance)
        node.look(at: SCNVector3(0, size.y * 0.35, 0))
        return node
    }

    private func resetCamera(in view: SCNView) {
        guard let camera = view.scene?.rootNode.childNode(withName: "reviewCamera", recursively: true) else {
            return
        }
        view.pointOfView = camera
    }
}

private extension SIMD3 where Scalar == Float {
    func min() -> Float {
        Swift.min(x, Swift.min(y, z))
    }

    func max() -> Float {
        Swift.max(x, Swift.max(y, z))
    }
}
