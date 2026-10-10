import ARKit
import simd

/// Camera constants for unprojecting one frame's depth samples to world
/// coordinates, read from the frame once rather than once per sample.
struct ARDepthProjection {
    private let fx: Float
    private let fy: Float
    private let cx: Float
    private let cy: Float
    private let cameraTransform: simd_float4x4

    init(frame: ARFrame, depthWidth: Int, depthHeight: Int) {
        let resolution = frame.camera.imageResolution
        let scaleX = Float(depthWidth) / Float(resolution.width)
        let scaleY = Float(depthHeight) / Float(resolution.height)
        let intrinsics = frame.camera.intrinsics
        fx = intrinsics.columns.0.x * scaleX
        fy = intrinsics.columns.1.y * scaleY
        cx = intrinsics.columns.2.x * scaleX
        cy = intrinsics.columns.2.y * scaleY
        cameraTransform = frame.camera.transform
    }

    func worldPoint(x: Int, y: Int, depth: Float) -> SIMD3<Float> {
        let cameraPoint = SIMD4<Float>(
            (Float(x) - cx) * depth / fx,
            -(Float(y) - cy) * depth / fy,
            -depth,
            1
        )
        let world = cameraTransform * cameraPoint
        return SIMD3<Float>(world.x, world.y, world.z)
    }
}
