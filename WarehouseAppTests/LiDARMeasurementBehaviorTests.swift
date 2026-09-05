import XCTest
import simd
@testable import WarehouseApp

/// Regression tests for the deterministic measurement rewrite: hull-based
/// orientation (input order must not matter), explicit failure reasons,
/// the support-plane fallback flag, and the stabilizer oscillation fix.
final class LiDARMeasurementBehaviorTests: XCTestCase {
    private let configuration = LiDARFusionConfiguration.smallObject

    // MARK: Determinism

    func testShuffledInputOrderProducesTheSameMeasurement() throws {
        let cloud = boxShell(size: SIMD3<Float>(0.08, 0.06, 0.04), yaw: 0.4) + table()
        var generator = SeededGenerator(seed: 42)
        let shuffled = cloud.shuffled(using: &generator)

        let first = try measure(frames: Array(repeating: cloud, count: 7))
        let second = try measure(frames: Array(repeating: shuffled, count: 7))

        // Floating-point accumulation order differs per voxel, so allow ulp-scale
        // slack; anything visible would be orders of magnitude larger.
        XCTAssertEqual(first.dimensionsCM.length, second.dimensionsCM.length, accuracy: 0.01)
        XCTAssertEqual(first.dimensionsCM.width, second.dimensionsCM.width, accuracy: 0.01)
        XCTAssertEqual(first.dimensionsCM.height, second.dimensionsCM.height, accuracy: 0.01)

        let yawOf: (LiDARFusionMeasurement) -> Float = {
            let edge = $0.boundingBoxCornersWorld[1] - $0.boundingBoxCornersWorld[0]
            return atan2(edge.z, edge.x)
        }
        XCTAssertEqual(yawOf(first), yawOf(second), accuracy: 0.001)
    }

    func testRepeatedMeasurementOfSameEngineIsStable() throws {
        let engine = makeEngine()
        for _ in 0..<7 {
            engine.integrate(framePoints: boxShell(size: SIMD3<Float>(0.08, 0.06, 0.04), yaw: 0.3) + table())
        }
        let first = try XCTUnwrap(engine.measurement())
        let second = try XCTUnwrap(engine.measurement())
        XCTAssertEqual(first, second, "identical state must measure identically")
    }

    // MARK: Failure reasons

    func testFailureReasonBeforeSelectionLock() {
        let engine = LiDARVoxelFusionEngine(configuration: configuration)
        XCTAssertEqual(engine.evaluateMeasurement(), .failed(.selectionPending))
    }

    func testFailureReasonWithTooFewVoxels() {
        let engine = makeEngine()
        engine.integrate(framePoints: [SIMD3<Float>(0, 0.04, 0)])
        guard case .failed(.tooFewStableVoxels) = engine.evaluateMeasurement() else {
            return XCTFail("expected tooFewStableVoxels, got \(engine.evaluateMeasurement())")
        }
    }

    // MARK: Support-plane fallback

    func testMissingSupportPlaneIsFlagged() throws {
        // A 45° ramp spreads heights so thin that no histogram bin qualifies
        // as a support plane; the percentile fallback engages and is flagged.
        let measurement = try measure(frames: Array(repeating: ramp(), count: 7))
        XCTAssertTrue(measurement.usedSupportPlaneFallback)
    }

    func testDetectedSupportPlaneIsNotFlagged() throws {
        let measurement = try measure(
            frames: Array(repeating: ramp() + table(), count: 7)
        )
        XCTAssertFalse(measurement.usedSupportPlaneFallback)
    }

    // MARK: Stabilizer oscillation

    func testAlternatingAgreementStillAdoptsTheNewValue() {
        var stabilizer = LiDARMeasurementStabilizer(configuration: configuration)
        let old = ObjectDimensions(length: 6, width: 6, height: 8)
        let new = ObjectDimensions(length: 9, width: 6, height: 8)

        for _ in 0..<3 { _ = stabilizer.consider(old) }
        XCTAssertEqual(stabilizer.stable, old)

        // Noise alternates between the (stale) stable value and the new truth.
        // Before the fix, each agreeing `old` frame reset the candidate series,
        // so `new` could never accumulate enough consecutive support.
        var decisions: [LiDARMeasurementDecision] = []
        for _ in 0..<3 {
            decisions.append(stabilizer.consider(new))
            decisions.append(stabilizer.consider(old))
        }
        let adoptedNew = decisions.contains {
            if case .accepted(let dimensions) = $0 {
                return abs(dimensions.length - new.length) < 0.5
            }
            return false
        }
        XCTAssertTrue(adoptedNew, "alternating noise must not starve adoption of a changed value")
    }

    // MARK: Fixtures

    private func makeEngine() -> LiDARVoxelFusionEngine {
        let engine = LiDARVoxelFusionEngine(configuration: configuration)
        engine.lockSelection(
            volume: LiDARScanVolume(
                centre: SIMD3<Float>(0, 0.05, 0),
                halfExtents: SIMD3<Float>(0.07, 0.10, 0.07)
            ),
            seed: SIMD3<Float>(0.03, 0.04, 0)
        )
        return engine
    }

    private func measure(frames: [[SIMD3<Float>]]) throws -> LiDARFusionMeasurement {
        let engine = makeEngine()
        for frame in frames {
            engine.integrate(framePoints: frame)
        }
        return try XCTUnwrap(engine.measurement())
    }

    /// Five faces of a box (no bottom), sitting on y = 0, rotated by `yaw`.
    private func boxShell(size: SIMD3<Float>, yaw: Float) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        let step: Float = 0.003
        let half = size / 2
        let rotation = simd_float2x2(
            SIMD2<Float>(cos(yaw), sin(yaw)),
            SIMD2<Float>(-sin(yaw), cos(yaw))
        )
        func add(_ x: Float, _ y: Float, _ z: Float) {
            let rotated = rotation * SIMD2<Float>(x, z)
            points.append(SIMD3<Float>(rotated.x, y, rotated.y))
        }
        var x = -half.x
        while x <= half.x {
            var z = -half.z
            while z <= half.z {
                add(x, size.y, z) // top
                z += step
            }
            var y: Float = 0.004
            while y <= size.y {
                add(x, y, -half.z) // front
                add(x, y, half.z)  // back
                y += step
            }
            x += step
        }
        var y: Float = 0.004
        while y <= size.y {
            var z = -half.z
            while z <= half.z {
                add(-half.x, y, z) // left
                add(half.x, y, z)  // right
                z += step
            }
            y += step
        }
        return points
    }

    /// A flat table surface at y = 0.
    private func table(extent: Float = 0.06) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        var x = -extent
        while x <= extent {
            var z = -extent
            while z <= extent {
                points.append(SIMD3<Float>(x, 0, z))
                z += 0.004
            }
            x += 0.004
        }
        return points
    }

    /// A narrow 45° ramp — every height histogram bin stays under the
    /// support-plane sample threshold.
    private func ramp() -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        var x: Float = -0.06
        while x <= 0.06 {
            var z: Float = -0.015
            while z <= 0.015 {
                points.append(SIMD3<Float>(x, x + 0.061, z))
                z += 0.003
            }
            x += 0.003
        }
        return points
    }

    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }
}
