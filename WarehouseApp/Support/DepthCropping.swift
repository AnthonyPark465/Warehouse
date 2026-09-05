import Foundation

struct DepthCropRect: Equatable {
    let minX: Int
    let maxX: Int
    let minY: Int
    let maxY: Int
}

/// Maps the portrait on-screen guide rectangle onto the LiDAR depth map,
/// which is stored in sensor (landscape) orientation: the sensor's long axis
/// (depth-map width) runs along the screen's VERTICAL axis in this
/// portrait-only app. Applying the screen fractions to the matching depth
/// axes without this swap sampled a region rotated 90° from the drawn guide —
/// admitting background on one axis while clipping the product on the other.
enum DepthCropping {
    static func cropRect(
        screenWidthFraction: Float,
        screenHeightFraction: Float,
        depthWidth: Int,
        depthHeight: Int
    ) -> DepthCropRect {
        let halfWidth = Int(Float(depthWidth) * screenHeightFraction / 2)
        let halfHeight = Int(Float(depthHeight) * screenWidthFraction / 2)
        return DepthCropRect(
            minX: max(depthWidth / 2 - halfWidth, 0),
            maxX: min(depthWidth / 2 + halfWidth, depthWidth),
            minY: max(depthHeight / 2 - halfHeight, 0),
            maxY: min(depthHeight / 2 + halfHeight, depthHeight)
        )
    }
}
