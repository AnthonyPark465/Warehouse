import XCTest
import simd
@testable import WarehouseApp

/// Wall-clock benchmarks for the LiDAR hot paths. XCTest's measure blocks run
/// each body 10 times and report the average, so regressions and wins are
/// visible directly in the test log.
final class LiDARPerformanceTests: XCTestCase {
    /// One synthetic depth frame at live sampling density (~12k points):
    /// half inside the region, half background to exercise the reject path.
    private func liveFrame() -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(12_000)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func random() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24)
        }
        for _ in 0..<12_000 {
            points.append(SIMD3<Float>(
                random() * 0.6 - 0.3,
                random() * 0.4 - 0.05,
                random() * 0.6 - 0.3
            ))
        }
        return points
    }

    private func lockedPrismEngine() -> LiDARVoxelFusionEngine {
        let engine = LiDARVoxelFusionEngine(configuration: .smallObject)
        // 12-vertex polygon: representative of a user-drawn boundary.
        let polygon = (0..<12).map { index -> SIMD2<Float> in
            let angle = Float(index) * 2 * .pi / 12
            return SIMD2<Float>(cos(angle), sin(angle)) * 0.15
        }
        engine.lockSelection(
            region: .polygonalPrism(LiDARPolygonalPrism(
                origin: .zero,
                axisU: SIMD3<Float>(1, 0, 0),
                axisV: SIMD3<Float>(0, 0, 1),
                normal: SIMD3<Float>(0, 1, 0),
                polygon: polygon,
                lowerOffset: -0.005,
                upperOffset: 0.25
            )),
            seed: SIMD3<Float>(0, 0.02, 0)
        )
        return engine
    }

    private func objectPoints() -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for xStep in 0...40 {
            for zStep in 0...40 {
                let x = Float(xStep) * 0.002 - 0.04
                let z = Float(zStep) * 0.002 - 0.04
                points.append(SIMD3<Float>(x, 0.08, z))
                points.append(SIMD3<Float>(x, 0.0005, z))
            }
            for yStep in 0...40 {
                let x = Float(xStep) * 0.002 - 0.04
                let y = Float(yStep) * 0.002
                points.append(SIMD3<Float>(x, y, -0.04))
                points.append(SIMD3<Float>(x, y, 0.04))
                points.append(SIMD3<Float>(-0.04, y, x))
                points.append(SIMD3<Float>(0.04, y, x))
            }
        }
        return points
    }

    func testIntegratePerformanceAtLiveDensity() {
        let frame = liveFrame()
        measure {
            let engine = lockedPrismEngine()
            for _ in 0..<10 {
                _ = engine.integrate(framePoints: frame)
            }
        }
    }

    func testMeasurementPerformanceOnFusedScan() {
        let engine = lockedPrismEngine()
        let object = objectPoints()
        for _ in 0..<8 {
            _ = engine.integrate(framePoints: object)
        }
        measure {
            for _ in 0..<10 {
                XCTAssertNotNil(engine.measurement())
            }
        }
    }

    func testCornerRecognitionPerformanceOnFullWindow() {
        var window = ObjectCornerLockWindow()
        let corner = SIMD3<Float>(0.5, 0.3, -1.0)
        for frame in 0..<14 {
            var points: [SIMD3<Float>] = []
            let jitter = Float(frame % 7 - 3) * 0.0002
            for index in 0...12 {
                let value = Float(index) * 0.01
                points.append(corner + SIMD3<Float>(value, jitter, jitter))
                points.append(corner + SIMD3<Float>(jitter, -jitter, value))
            }
            for x in 1...12 {
                for z in 1...12 {
                    points.append(
                        corner + SIMD3<Float>(Float(x) * 0.008, jitter, Float(z) * 0.008)
                    )
                }
            }
            window.integrate(
                reticleWorld: corner,
                patchWorldPoints: points,
                cameraWorld: corner + SIMD3<Float>(-0.25, 0.35, -0.4),
                timestamp: Double(frame) * 0.1,
                depthConfidence: 0.95
            )
        }
        measure {
            XCTAssertNotNil(
                window.recognisedCorner(reticleWorld: corner, at: 1.4)
            )
        }
    }
}
