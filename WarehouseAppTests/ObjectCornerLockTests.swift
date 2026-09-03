import XCTest
import simd
@testable import WarehouseApp

final class ObjectCornerLockTests: XCTestCase {
    /// Arbitrary world origin so the window's world→local anchoring is exercised.
    private let corner = SIMD3<Float>(1.20, 0.45, -2.10)

    func testRecognisesCornerAtReticleAndLocksOntoIt() throws {
        // Arrange
        var window = ObjectCornerLockWindow()
        integrateCornerFrames(into: &window)

        // Act
        let lock = try XCTUnwrap(
            window.recognisedCorner(reticleWorld: corner, at: 1.4)
        )

        // Assert: the lock lands on the true corner, not the raw reticle.
        XCTAssertEqual(lock.worldPosition.x, corner.x, accuracy: 0.012)
        XCTAssertEqual(lock.worldPosition.z, corner.z, accuracy: 0.012)
        XCTAssertEqual(lock.worldPosition.y, corner.y, accuracy: 0.001)
        XCTAssertLessThanOrEqual(lock.uncertaintyMetres, 0.02)
    }

    func testCornerFarFromReticleIsNotLocked() {
        // Arrange
        var window = ObjectCornerLockWindow()
        integrateCornerFrames(into: &window)

        // Act: aim 10 cm away from the recognised corner (estimator still
        // accepts up to 12 cm, but the lock policy must not snap that far).
        let farReticle = corner + SIMD3<Float>(0.10, 0, 0)
        let lock = window.recognisedCorner(reticleWorld: farReticle, at: 1.4)

        // Assert
        XCTAssertNil(lock)
    }

    func testShortCaptureWindowDoesNotLock() {
        // Arrange: a single frame is far below the minimum capture duration.
        var window = ObjectCornerLockWindow()
        integrateFrame(into: &window, frame: 0)

        // Act / Assert
        XCTAssertNil(window.recognisedCorner(reticleWorld: corner, at: 0.05))
    }

    func testLargeReticleDriftRestartsTheWindow() {
        // Arrange
        var window = ObjectCornerLockWindow()
        integrateCornerFrames(into: &window)
        let samplesBefore = window.samples.count

        // Act: aim jumps 20 cm — a different corner is being targeted.
        integrateFrame(
            into: &window,
            frame: 8,
            reticle: corner + SIMD3<Float>(0.20, 0, 0)
        )

        // Assert: the window restarted around the new aim point.
        XCTAssertLessThan(window.samples.count, samplesBefore)
        XCTAssertEqual(
            window.originWorld,
            corner + SIMD3<Float>(0.20, 0, 0)
        )
        XCTAssertNil(
            window.recognisedCorner(
                reticleWorld: corner + SIMD3<Float>(0.20, 0, 0),
                at: 1.7
            )
        )
    }

    // MARK: - Fixtures (mirrors the proven tabletop corner evidence shape)

    private func integrateCornerFrames(into window: inout ObjectCornerLockWindow) {
        for frame in 0..<7 {
            integrateFrame(into: &window, frame: frame)
        }
    }

    private func integrateFrame(
        into window: inout ObjectCornerLockWindow,
        frame: Int,
        reticle: SIMD3<Float>? = nil
    ) {
        let origin = reticle ?? corner
        let jitter = Float(frame - 3) * 0.0002
        var points: [SIMD3<Float>] = []
        for index in 0...12 {
            let value = Float(index) * 0.01
            points.append(origin + SIMD3<Float>(value, jitter, jitter))
            points.append(origin + SIMD3<Float>(jitter, -jitter, value))
        }
        for x in 1...5 {
            for z in 1...5 {
                points.append(
                    origin + SIMD3<Float>(Float(x) * 0.018, jitter, Float(z) * 0.018)
                )
            }
        }
        window.integrate(
            reticleWorld: origin,
            patchWorldPoints: points,
            cameraWorld: origin + SIMD3<Float>(-0.25 + Float(frame) * 0.004, 0.35, -0.4),
            timestamp: Double(frame) * 0.2,
            depthConfidence: 0.95
        )
    }
}
