import XCTest
import simd
@testable import WarehouseApp

/// Pure-geometry tests for the capture layer helpers extracted in the LiDAR
/// stabilization: portrait-guide → landscape-depth-map crop mapping, and
/// locked-volume placement around the aim point.
final class ScanCaptureGeometryTests: XCTestCase {
    // MARK: DepthCropping

    func testPortraitGuideFractionsSwapOntoLandscapeDepthAxes() {
        // 256×192 landscape depth map; a guide that is NARROW on screen
        // (width fraction) must be narrow along the depth map's HEIGHT.
        let crop = DepthCropping.cropRect(
            screenWidthFraction: 0.25,
            screenHeightFraction: 0.75,
            depthWidth: 256,
            depthHeight: 192
        )
        XCTAssertEqual(crop.maxX - crop.minX, Int(256 * 0.75 / 2) * 2)
        XCTAssertEqual(crop.maxY - crop.minY, Int(192 * 0.25 / 2) * 2)
    }

    func testCropRectIsCenteredAndClamped() {
        let crop = DepthCropping.cropRect(
            screenWidthFraction: 1.0,
            screenHeightFraction: 1.0,
            depthWidth: 256,
            depthHeight: 192
        )
        XCTAssertEqual(crop.minX, 0)
        XCTAssertEqual(crop.maxX, 256)
        XCTAssertEqual(crop.minY, 0)
        XCTAssertEqual(crop.maxY, 192)

        let centred = DepthCropping.cropRect(
            screenWidthFraction: 0.5,
            screenHeightFraction: 0.5,
            depthWidth: 256,
            depthHeight: 192
        )
        XCTAssertLessThanOrEqual(abs(centred.minX + centred.maxX - 256), 2)
        XCTAssertLessThanOrEqual(abs(centred.minY + centred.maxY - 192), 2)
    }

    // MARK: LockedVolumePlanning

    private let seed = SIMD3<Float>(0, 0.30, -0.5)
    private let right = SIMD3<Float>(1, 0, 0)
    private let forward = SIMD3<Float>(0, 0, -1) // camera looking down -z

    func testFrontFaceSitsJustInFrontOfTheSeed() {
        let volume = LockedVolumePlanning.volume(
            seed: seed, cameraRight: right, cameraForward: forward,
            floorY: nil, width: 0.14, height: 0.16, depth: 0.14
        )
        // Sceneward is -z here; the front face (toward the camera, +z side)
        // must sit 2 cm in front of the seed, the back 12 cm behind it.
        let front = volume.centre.z + volume.halfExtents.z
        let back = volume.centre.z - volume.halfExtents.z
        XCTAssertEqual(front, seed.z + 0.02, accuracy: 0.001)
        XCTAssertEqual(back, seed.z - 0.12, accuracy: 0.001)
    }

    func testDetectedFloorIsIncludedInTheVolume() {
        let floorY: Float = 0.0
        let volume = LockedVolumePlanning.volume(
            seed: seed, cameraRight: right, cameraForward: forward,
            floorY: floorY, width: 0.14, height: 0.16, depth: 0.14
        )
        let bottom = volume.centre.y - volume.halfExtents.y
        let top = volume.centre.y + volume.halfExtents.y
        XCTAssertLessThan(bottom, floorY, "support plane must be inside the region")
        XCTAssertEqual(top, seed.y + 0.08, accuracy: 0.001, "headroom above the aim point kept")
    }

    func testImplausiblyDeepFloorFallsBackToSymmetricHeight() {
        let volume = LockedVolumePlanning.volume(
            seed: seed, cameraRight: right, cameraForward: forward,
            floorY: seed.y - 2.0, width: 0.14, height: 0.16, depth: 0.14
        )
        XCTAssertEqual(volume.halfExtents.y, 0.08, accuracy: 0.001)
    }

    func testDegenerateCameraRightFallsBackToWorldX() {
        let volume = LockedVolumePlanning.volume(
            seed: seed,
            cameraRight: SIMD3<Float>(0, 1, 0), // camera rolled 90°: no horizontal right
            cameraForward: forward,
            floorY: nil, width: 0.14, height: 0.16, depth: 0.14
        )
        XCTAssertEqual(volume.axisX, SIMD3<Float>(1, 0, 0))
    }
}
