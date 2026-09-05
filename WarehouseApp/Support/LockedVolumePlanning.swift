import simd

/// Pure geometry for placing the locked scan volume around the aim point.
/// The seed sits on the object's camera-facing surface, so a volume centred on
/// it cropped everything deeper than half the depth extent and frequently
/// excluded the support plane below — both mismeasured silently.
enum LockedVolumePlanning {
    static func volume(
        seed: SIMD3<Float>,
        cameraRight: SIMD3<Float>,
        cameraForward: SIMD3<Float>,
        floorY: Float?,
        width: Float,
        height: Float,
        depth: Float,
        frontMargin: Float = 0.02,
        floorMargin: Float = 0.01,
        maximumFloorDrop: Float = 0.6
    ) -> LiDARScanVolume {
        var right = SIMD3<Float>(cameraRight.x, 0, cameraRight.z)
        if simd_length_squared(right) < 0.001 {
            right = SIMD3<Float>(1, 0, 0)
        }
        right = simd_normalize(right)
        let up = SIMD3<Float>(0, 1, 0)
        var sceneward = simd_normalize(simd_cross(right, up))
        let forwardXZ = SIMD3<Float>(cameraForward.x, 0, cameraForward.z)
        if simd_length_squared(forwardXZ) > 0.0001,
           simd_dot(sceneward, forwardXZ) < 0 {
            sceneward = -sceneward
        }

        // Horizontal: front face a small margin in front of the seed, with
        // the remaining depth behind it — the object extends away from the
        // camera, not towards it.
        let horizontalCentre = seed + sceneward * (depth / 2 - frontMargin)

        // Vertical: keep headroom above the aim point, and reach a plausibly
        // close detected floor below it so the support plane is always inside
        // the region regardless of where on the object the user aimed.
        let top = seed.y + height / 2
        let bottom: Float
        if let floorY, floorY < seed.y, seed.y - floorY <= maximumFloorDrop {
            bottom = floorY - floorMargin
        } else {
            bottom = seed.y - height / 2
        }
        return LiDARScanVolume(
            centre: SIMD3<Float>(
                horizontalCentre.x,
                (top + bottom) / 2,
                horizontalCentre.z
            ),
            axisX: right,
            axisY: up,
            axisZ: sceneward,
            halfExtents: SIMD3<Float>(width / 2, (top - bottom) / 2, depth / 2)
        )
    }
}
